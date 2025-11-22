# Reconnection Implementation Guide

## Quick Reference: File Locations & Current State

### Core Modules

| File | Purpose | Disconnect Handling | Status |
|------|---------|-------------------|--------|
| `lib/pidro_server_web/channels/game_channel.ex` | WebSocket for gameplay | ❌ None | CRITICAL |
| `lib/pidro_server_web/channels/lobby_channel.ex` | WebSocket for lobby | ❌ None | Secondary |
| `lib/pidro_server_web/channels/user_socket.ex` | Authentication layer | ✅ Works | Needs enhancement |
| `lib/pidro_server/games/room_manager.ex` | Room state & lifecycle | ⚠️ Partial | Needs enhancement |
| `lib/pidro_server/games/game_adapter.ex` | Game interface | ❌ None | Secondary |
| `lib/pidro_server_web/presence.ex` | Presence tracking | ✅ Works | Integrates with disconnect |

### Infrastructure

| File | Purpose | Status |
|------|---------|--------|
| `lib/pidro_server/games/game_supervisor.ex` | Game process supervision | ✅ Working |
| `lib/pidro_server/games/game_registry.ex` | Game PID lookup | ✅ Working |
| `lib/pidro_server/games/supervisor.ex` | Games domain supervisor | ✅ Working |
| `lib/pidro_server/accounts/token.ex` | JWT auth tokens | ✅ Working |

---

## Implementation Steps (Detailed)

### STEP 1: Add Disconnect Handler to GameChannel

**File:** `lib/pidro_server_web/channels/game_channel.ex`

**Add after line 322 (end of file):**

```elixir
@doc """
Handles channel termination when the WebSocket disconnects.

This callback is invoked when:
1. Client closes connection
2. Network disconnection occurs
3. Server forcibly closes channel
4. Timeout occurs

We use this to trigger reconnect grace period.
"""
@impl true
def terminate(reason, socket) do
  Logger.info("GameChannel terminating for user #{socket.assigns.user_id}: #{inspect(reason)}")
  
  room_code = socket.assigns[:room_code]
  user_id = socket.assigns.user_id
  
  # Only handle disconnects from active games
  case {room_code, socket.assigns[:position]} do
    {nil, _} ->
      :ok
    
    {code, position} when is_binary(code) and is_atom(position) ->
      # Notify RoomManager of disconnect
      case RoomManager.player_disconnected(code, user_id) do
        :ok ->
          # Broadcast to other players
          broadcast(socket, "player_disconnected", %{
            position: position,
            reconnect_timeout_seconds: 300  # 5 minutes
          })
          Logger.info("Player #{user_id} at #{position} disconnected from room #{code}")
        
        {:error, :room_not_found} ->
          Logger.warning("Room #{code} not found during disconnect")
      end
      
      :ok
    
    _ ->
      :ok
  end
end
```

**Why This is Critical:**
- Currently, channel termination is silent
- Other players don't know someone disconnected
- RoomManager never gets notified
- No reconnect grace period starts

---

### STEP 2: Enhance RoomManager for Disconnects

**File:** `lib/pidro_server/games/room_manager.ex`

**Add new fields to Room struct (after line 86):**

```elixir
# Add to defstruct:
# :player_sessions      # Map of user_id -> PlayerSession (NEW)
# :started_at           # DateTime game started (NEW)
# :last_activity        # DateTime of last action (NEW)
```

**Add PlayerSession module (after Room module, around line 87):**

```elixir
defmodule PlayerSession do
  @moduledoc """
  Tracks connection state of a player in a room.
  """

  @type status :: :connected | :disconnected | :reconnecting

  defstruct [
    :user_id,
    :position,
    :status,              # :connected, :disconnected, :reconnecting
    :connected_at,
    :disconnected_at,     # nil if connected
    :last_action_at,
    :reconnect_deadline   # DateTime when reconnect expires
  ]
end
```

**Add new functions (after `close_room/1`, around line 291):**

```elixir
@doc """
Marks a player as disconnected and starts reconnect grace period.

Called when GameChannel terminates. Starts a 5-minute window
for the player to reconnect before being permanently removed.

## Parameters

- `room_code` - The room code
- `player_id` - User ID of disconnected player

## Returns

- `:ok` - Successfully marked disconnected
- `{:error, :room_not_found}` - Room doesn't exist
- `{:error, :player_not_in_room}` - Player isn't in room
"""
@spec player_disconnected(String.t(), String.t()) ::
        :ok | {:error, :room_not_found | :player_not_in_room}
def player_disconnected(room_code, player_id) do
  GenServer.call(__MODULE__, {:player_disconnected, String.upcase(room_code), player_id})
end

@doc """
Marks a player as reconnected.

Called when player rejoins the game channel after disconnecting.

## Parameters

- `room_code` - The room code  
- `player_id` - User ID of reconnecting player

## Returns

- `:ok` - Successfully reconnected
- `{:error, :room_not_found}` - Room doesn't exist
- `{:error, :reconnect_expired}` - Reconnect window expired
"""
@spec player_reconnected(String.t(), String.t()) ::
        :ok | {:error, :room_not_found | :reconnect_expired}
def player_reconnected(room_code, player_id) do
  GenServer.call(__MODULE__, {:player_reconnected, String.upcase(room_code), player_id})
end

@doc """
Checks if a player can still reconnect.

Returns nil if player isn't in room, false if reconnect expired,
true if still within reconnect window.
"""
@spec can_reconnect?(String.t(), String.t()) :: boolean() | nil
def can_reconnect?(room_code, player_id) do
  GenServer.call(__MODULE__, {:can_reconnect?, String.upcase(room_code), player_id})
end
```

**Add handle_call implementations (in GenServer callbacks section):**

```elixir
@impl true
def handle_call({:player_disconnected, room_code, player_id}, _from, %State{} = state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, {:error, :room_not_found}, state}
    
    %Room{} = room ->
      if Enum.member?(room.player_ids, player_id) do
        # Find position for this player
        position = find_player_position(room, player_id)
        
        # Create or update player session
        reconnect_deadline = DateTime.add(DateTime.utc_now(), 300, :second)  # 5 min
        
        player_sessions = Map.put(
          room.player_sessions || %{},
          player_id,
          %PlayerSession{
            user_id: player_id,
            position: position,
            status: :disconnected,
            connected_at: DateTime.utc_now(),  # Could track from when they joined
            disconnected_at: DateTime.utc_now(),
            reconnect_deadline: reconnect_deadline
          }
        )
        
        updated_room = %Room{room | player_sessions: player_sessions}
        
        new_state = %State{
          state
          | rooms: Map.put(state.rooms, room_code, updated_room)
        }
        
        # Schedule timeout cleanup
        cleanup_ref = schedule_reconnect_timeout(room_code, player_id, 300_000)  # 5 min in ms
        
        Logger.info("Player #{player_id} marked disconnected in room #{room_code}")
        
        {:reply, :ok, new_state}
      else
        {:reply, {:error, :player_not_in_room}, state}
      end
  end
end

@impl true
def handle_call({:player_reconnected, room_code, player_id}, _from, %State{} = state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, {:error, :room_not_found}, state}
    
    %Room{} = room ->
      case Map.get(room.player_sessions || %{}, player_id) do
        nil ->
          {:reply, {:error, :player_not_in_room}, state}
        
        session ->
          # Check if reconnect window is still open
          if DateTime.after?(session.reconnect_deadline, DateTime.utc_now()) do
            updated_session = %PlayerSession{session | status: :connected, disconnected_at: nil}
            
            player_sessions = Map.put(room.player_sessions || %{}, player_id, updated_session)
            updated_room = %Room{room | player_sessions: player_sessions}
            
            new_state = %State{
              state
              | rooms: Map.put(state.rooms, room_code, updated_room)
            }
            
            Logger.info("Player #{player_id} reconnected to room #{room_code}")
            broadcast_room(room_code, updated_room)
            
            {:reply, :ok, new_state}
          else
            # Window expired, remove permanently
            updated_player_ids = List.delete(room.player_ids, player_id)
            player_sessions = Map.delete(room.player_sessions || %{}, player_id)
            
            updated_room = %Room{
              room
              | player_ids: updated_player_ids,
                player_sessions: player_sessions
            }
            
            new_state = %State{
              state
              | rooms: Map.put(state.rooms, room_code, updated_room),
                player_rooms: Map.delete(state.player_rooms, player_id)
            }
            
            Logger.info("Player #{player_id} reconnect window expired for room #{room_code}")
            broadcast_room(room_code, updated_room)
            
            {:reply, {:error, :reconnect_expired}, new_state}
          end
      end
  end
end

@impl true
def handle_call({:can_reconnect?, room_code, player_id}, _from, %State{} = state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, nil, state}
    
    %Room{} = room ->
      case Map.get(room.player_sessions || %{}, player_id) do
        nil ->
          {:reply, nil, state}
        
        session ->
          can_reconnect = DateTime.after?(session.reconnect_deadline, DateTime.utc_now())
          {:reply, can_reconnect, state}
      end
  end
end
```

**Add helper function (at end of private section):**

```elixir
@doc false
defp find_player_position(%Room{} = room, player_id) do
  positions = [:north, :east, :south, :west]
  user_id_str = to_string(player_id)
  
  index = Enum.find_index(room.player_ids, fn id -> to_string(id) == user_id_str end) || 0
  Enum.at(positions, index, :north)
end

@doc false
defp schedule_reconnect_timeout(room_code, player_id, timeout_ms) do
  # Store cleanup refs in state if needed for cancellation
  # For now, just schedule the timeout
  Process.send_after(
    self(),
    {:reconnect_timeout, room_code, player_id},
    timeout_ms
  )
end
```

**Add handle_info for timeout:**

```elixir
@impl true
def handle_info({:reconnect_timeout, room_code, player_id}, %State{} = state) do
  # Permanently remove player if still disconnected
  Logger.info("Reconnect timeout for player #{player_id} in room #{room_code}")
  
  case Map.get(state.rooms, room_code) do
    nil ->
      {:noreply, state}
    
    %Room{} = room ->
      case Map.get(room.player_sessions || %{}, player_id) do
        nil ->
          {:noreply, state}
        
        session ->
          if session.status == :disconnected do
            # Permanently remove
            updated_player_ids = List.delete(room.player_ids, player_id)
            player_sessions = Map.delete(room.player_sessions, player_id)
            
            updated_room = %Room{
              room
              | player_ids: updated_player_ids,
                player_sessions: player_sessions,
                status: :waiting  # Reset game if in progress
            }
            
            new_state = %State{
              state
              | rooms: Map.put(state.rooms, room_code, updated_room),
                player_rooms: Map.delete(state.player_rooms, player_id)
            }
            
            broadcast_room(room_code, updated_room)
            {:noreply, new_state}
          else
            # Already reconnected, ignore
            {:noreply, state}
          end
      end
  end
end
```

---

### STEP 3: Update GameChannel to Handle Reconnects

**File:** `lib/pidro_server_web/channels/game_channel.ex`

**Modify join/3 to check for reconnect (lines 71-108):**

```elixir
@impl true
def join("game:" <> room_code, _params, socket) do
  user_id = socket.assigns.user_id

  with {:ok, room} <- RoomManager.get_room(room_code),
       true <- user_in_room?(user_id, room),
       {:ok, _pid} <- GameAdapter.get_game(room_code),
       :ok <- GameAdapter.subscribe(room_code) do
    
    # Check if this is a reconnect
    was_disconnected = RoomManager.can_reconnect?(room_code, user_id)
    
    if was_disconnected == true do
      # Reconnect existing player
      Logger.info("Player #{user_id} reconnecting to room #{room_code}")
      :ok = RoomManager.player_reconnected(room_code, user_id)
      
      # Broadcast reconnection to other players
      position = get_player_position(room, user_id)
      broadcast(socket, "player_reconnected", %{position: position})
    end
    
    # Determine player position
    position = get_player_position(room, user_id)

    # Get initial game state
    {:ok, state} = GameAdapter.get_state(room_code)

    socket =
      socket
      |> assign(:room_code, room_code)
      |> assign(:position, position)

    send(self(), :after_join)

    {:ok, %{state: state, position: position}, socket}
  else
    # ... rest of error handling
  end
end
```

**Add new handle_in for rejoining:**

```elixir
def handle_in("rejoin", _params, socket) do
  room_code = socket.assigns.room_code
  user_id = socket.assigns.user_id
  
  case RoomManager.can_reconnect?(room_code, user_id) do
    true ->
      {:reply, {:ok, %{status: "reconnect_available"}}, socket}
    
    false ->
      {:reply, {:error, %{reason: "Reconnect window expired"}}, socket}
    
    nil ->
      {:reply, {:error, %{reason: "Player not in room"}}, socket}
  end
end
```

---

### STEP 4: Add Reconnect Support to UserSocket

**File:** `lib/pidro_server_web/channels/user_socket.ex`

**Add session tracking:**

```elixir
@impl true
def id(socket) do
  # Include connection timestamp for unique session IDs
  user_id = socket.assigns.user_id
  connection_id = socket.assigns[:connection_id] || generate_connection_id()
  "user_socket:#{user_id}:#{connection_id}"
end

@doc false
defp generate_connection_id do
  :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
```

---

### STEP 5: Create Migration for Session Tracking (Optional)

If you want to persist disconnect/reconnect events:

```elixir
# priv/repo/migrations/[timestamp]_create_player_sessions.exs

defmodule PidroServer.Repo.Migrations.CreatePlayerSessions do
  use Ecto.Migration

  def change do
    create table(:player_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :room_code, :string, null: false
      add :position, :string, null: false
      add :connected_at, :utc_datetime_usec, null: false
      add :disconnected_at, :utc_datetime_usec
      add :reconnected_at, :utc_datetime_usec
      add :status, :string, null: false, default: "connected"
      
      timestamps(type: :utc_datetime_usec)
    end

    create index(:player_sessions, [:user_id, :room_code])
    create index(:player_sessions, [:room_code])
    create index(:player_sessions, [:status])
  end
end
```

---

## Testing Strategy

### Add to game_channel_test.exs:

```elixir
describe "disconnect and reconnect" do
  test "broadcasts player_disconnected when player loses connection", %{
    user1: user,
    room_code: room_code,
    sockets: sockets
  } do
    socket = sockets[user.id]
    {:ok, _reply, socket} = subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})
    
    # Simulate disconnect by closing socket
    GenServer.stop(socket.channel_pid)
    
    # Wait for terminate to process
    Process.sleep(100)
    
    # Other players should see disconnect broadcast
    # (this would need to be tested from another player's perspective)
  end

  test "allows reconnect within grace period", %{
    user1: user,
    room_code: room_code,
    sockets: sockets
  } do
    # First connection
    {:ok, _reply, socket1} = subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})
    
    # Disconnect
    GenServer.stop(socket1.channel_pid)
    Process.sleep(100)
    
    # Reconnect within 5 minutes
    {:ok, socket2} = create_socket(user)
    {:ok, _reply, _socket2} = subscribe_and_join(socket2, GameChannel, "game:#{room_code}", %{})
    
    # Should succeed
    assert true
  end

  test "prevents reconnect after grace period", %{
    user1: user,
    room_code: room_code
  } do
    # This requires mocking time or waiting 5 minutes
    # Recommend testing with shorter timeout in test environment
  end
end
```

---

## Client-Side Integration Points

The client needs to:

1. **Listen for disconnection events:**
```javascript
channel.on("player_disconnected", ({position, reconnect_timeout_seconds}) => {
  showDisconnectWarning(position, reconnect_timeout_seconds);
});

channel.on("player_reconnected", ({position}) => {
  hideDisconnectWarning(position);
});
```

2. **Auto-reconnect with exponential backoff:**
```javascript
function reconnectToGame(roomCode) {
  let attempt = 0;
  const maxAttempts = 10;
  
  function tryReconnect() {
    attempt++;
    const delay = Math.min(1000 * Math.pow(2, attempt), 30000);
    
    setTimeout(() => {
      channel.push("rejoin", {})
        .receive("ok", () => rejoinChannel(roomCode))
        .receive("error", () => {
          if (attempt < maxAttempts) tryReconnect();
        });
    }, delay);
  }
  
  tryReconnect();
}
```

3. **Show countdown to reconnect expiration:**
```javascript
function updateReconnectCountdown(deadline) {
  const interval = setInterval(() => {
    const remaining = Math.max(0, deadline - Date.now());
    updateUI(`Reconnect in ${Math.ceil(remaining / 1000)}s`);
    if (remaining <= 0) clearInterval(interval);
  }, 1000);
}
```

---

## Phased Rollout

### Phase 1 (Week 1): Detection
- Add terminate/2 to GameChannel
- Add player_disconnected/player_reconnected to RoomManager
- Broadcast disconnect notifications
- Test with local network disconnect

### Phase 2 (Week 2): Grace Period
- Implement reconnect window (5 minutes)
- Add PlayerSession tracking
- Implement timeout cleanup
- Test timeout scenarios

### Phase 3 (Week 3): Game State
- Add player availability to game state
- Implement mid-game rejoin
- Pause/resume game flow
- Test with active games

### Phase 4 (Week 4): Polish & Testing
- Client-side auto-reconnect
- UI feedback improvements
- Performance testing
- Production deployment

---

## Monitoring & Debugging

Add logs to track disconnects:

```elixir
Logger.info("Disconnect event", %{
  user_id: user_id,
  room_code: room_code,
  position: position,
  reason: reason,
  timestamp: DateTime.utc_now()
})

Logger.info("Reconnect event", %{
  user_id: user_id,
  room_code: room_code,
  position: position,
  disconnect_duration_seconds: disconnect_seconds,
  timestamp: DateTime.utc_now()
})
```

For monitoring:
- Track disconnect/reconnect counts
- Measure reconnect success rates
- Alert on unusual patterns
- Monitor grace period timeouts

---

## Common Pitfalls to Avoid

1. ❌ Broadcasting to socket after disconnect (socket is dead)
   - ✅ Broadcast to channel, not socket

2. ❌ Allowing rejoin without position validation
   - ✅ Verify position matches player_ids order

3. ❌ Letting old game actions execute after disconnect
   - ✅ Clear action queue on disconnect

4. ❌ Not handling partial network failures
   - ✅ Implement heartbeat for early detection

5. ❌ Infinite reconnect loops
   - ✅ Implement exponential backoff with max attempts

