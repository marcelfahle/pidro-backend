# Pidro Game Server: Spectator Mode Implementation Analysis

## Executive Summary

This document provides a detailed analysis of the Pidro game server architecture and specific recommendations for implementing spectator mode. The current system is built on Phoenix channels for real-time communication, a RoomManager GenServer for game lifecycle management, and Pidro.Server for game logic.

---

## 1. Current Room/Game/Channel Architecture

### 1.1 Room Management (RoomManager)

**Location:** `lib/pidro_server/games/room_manager.ex`

**Responsibility:** Centralized GenServer managing the complete game room lifecycle.

**Key Characteristics:**
- Single GenServer instance manages all rooms globally
- Uses internal state to track `rooms` (by code) and `player_rooms` (reverse mapping: user_id → room_code)
- Implements 4-player game model with hard constraints
- Auto-starts games when 4 players join (status transitions to `:ready`, then game supervisor creates game process)

**Room Struct Fields:**
```elixir
defstruct [
  :code,                           # 4-char alphanumeric room code
  :host_id,                        # User ID of room creator
  :player_ids,                     # List of 4 player user IDs
  :status,                         # :waiting | :ready | :playing | :finished | :closed
  :max_players,                    # Always 4
  :created_at,                     # DateTime created
  :metadata,                       # Custom map (room name, etc)
  disconnected_players: %{}        # Map of {user_id => disconnect_timestamp}
]
```

**Room Lifecycle:**
1. **Creation** (`:waiting`): Host creates room, becomes first player
2. **Waiting** (`:waiting`): Players 2-3 join, room accepts players
3. **Ready** (`:ready`): 4th player joins, room becomes ready
4. **Playing** (`:playing`): Game supervisor starts game process, status updated
5. **Finished** (`:finished`): Game ends (handled by GameChannel)
6. **Closed** (`:closed`): Room cleanup after 5 minutes post-game

**Broadcasting:**
- `lobby:updates` topic: Notifies all clients of available rooms (`:waiting`, `:ready`, `:playing`)
- `room:<room_code>` topic: Room-specific updates (player join/leave, reconnection)

### 1.2 Player Join Flow

```
1. User calls RoomController.join(room_code, user_id) [HTTP REST]
   ↓
2. RoomManager.join_room/2 validates:
   - Room exists
   - Room not full (< 4 players)
   - User not already in room
   - Room status in [:waiting, :ready]
   ↓
3. If valid, adds user_id to room.player_ids
   ↓
4. If room now has 4 players:
   - Status → :ready
   - Broadcast room update on "room:<code>" topic
   - Call GameSupervisor.start_game(room_code) to create game process
   - Status → :playing (once game starts)
   ↓
5. Broadcast lobby update on "lobby:updates" topic
```

### 1.3 Game Channel (Real-Time Updates)

**Location:** `lib/pidro_server_web/channels/game_channel.ex`

**Responsibility:** WebSocket channel for in-game real-time communication.

**Channel Name:** `"game:XXXX"` where XXXX is room code

**Join Authorization:**
```elixir
def join("game:" <> room_code, _params, socket) do
  # Verify:
  # 1. User authenticated (socket.assigns.user_id exists)
  # 2. Room exists (RoomManager.get_room/1)
  # 3. User is player in room (user_in_room?/2)
  # 4. Game process exists (GameAdapter.get_game/1)
  # 5. Handle reconnections if user was disconnected
end
```

**Subscriptions:**
- PubSub subscription to `"game:<room_code>"` for game updates
- Presence tracking via Phoenix.Presence

**Incoming Events (Client → Server):**
- `"bid"`: Player bids or passes
- `"declare_trump"`: Declares trump suit
- `"play_card"`: Plays card from hand
- `"ready"`: Signals ready status

**Outgoing Events (Server → Client):**
- `"game_state"`: Full game state update (broadcasted on state change)
- `"player_joined"`: New player joined
- `"player_left"`: Player left
- `"player_disconnected"`: Player network disconnect (grace period started)
- `"player_reconnected"`: Player reconnected within grace period
- `"turn_changed"`: Current player changed
- `"game_over"`: Game ended with winner and scores
- `"presence_state"`: Presence info (online players)
- `"presence_diff"`: Presence changes
- `"player_ready"`: Player signaled ready

### 1.4 Game State Broadcasting

**Adapter:** `lib/pidro_server/games/game_adapter.ex`

**Flow:**
```
1. Client sends action via GameChannel.handle_in(event, params, socket)
   ↓
2. apply_game_action/1:
   - Calls GameAdapter.apply_action(room_code, position, action)
   ↓
3. GameAdapter.apply_action/3:
   - Looks up game PID via GameRegistry
   - Calls Pidro.Server.apply_action(pid, position, action)
   - If successful, calls broadcast_state_update/2
   ↓
4. broadcast_state_update/2:
   - Gets current state from Pidro.Server
   - Broadcasts {:state_update, state} on "game:<room_code>" PubSub topic
   - If game phase is :game_over, also broadcasts {:game_over, winner, scores}
   ↓
5. All subscribed GameChannel processes receive message
   - handle_info({:state_update, new_state}, socket)
   - Broadcasts to connected WebSocket clients: "game_state" event
```

**Key Point:** All connected clients to the channel receive the same full state broadcast. There is no filtering of state per position currently.

### 1.5 Presence Tracking

**Location:** `lib/pidro_server_web/presence.ex` (thin wrapper)

**Implementation:** Phoenix.Presence (CRDT-based distributed presence)

**Usage in GameChannel:**
```elixir
# On join
Presence.track(socket, user_id, %{
  online_at: DateTime.utc_now() |> DateTime.to_unix(),
  position: socket.assigns.position
})

# On client side
Presence.list(socket) → map of {user_id => presence_data}
```

**Broadcasts:**
- `"presence_state"`: Full presence map on join
- `"presence_diff"`: Incremental presence changes

---

## 2. Key Files to Modify for Spectator Mode

### 2.1 Core Files (Must Modify)

#### A. `lib/pidro_server/games/room_manager.ex`
**Changes Needed:**
- Add `spectator_ids: [String.t()]` field to Room struct
- Add `max_spectators: integer()` field (e.g., 10) to Room struct
- Add `join_spectator_room/2` function to add spectators without counting toward player limit
- Add `leave_spectator/2` function to remove spectators from room
- Modify `join_room/2` to reject spectators (only players join via this path)
- Update room broadcasts to include spectator count
- Handle spectator disconnect/reconnect similarly to players (optional, could be simpler)

**Functions to Add:**
```elixir
@spec join_spectator_room(String.t(), String.t()) ::
        {:ok, Room.t()} | {:error, :room_not_found | :max_spectators_reached | ...}
def join_spectator_room(room_code, spectator_id) do
  # Validate room exists
  # Check max spectators not reached
  # Check spectator not already in room
  # Add to spectator_ids
  # Broadcast room update
end

@spec leave_spectator(String.t(), String.t()) :: :ok | {:error, ...}
def leave_spectator(room_code, spectator_id) do
  # Remove from spectator_ids
  # Broadcast room update
end

@spec is_spectator?(String.t(), String.t()) :: boolean()
def is_spectator?(room_code, spectator_id) do
  # Check if user is spectator in this room
end
```

#### B. `lib/pidro_server_web/channels/game_channel.ex`
**Changes Needed:**
- Modify `join/3` to accept both players and spectators
- Add role assignment logic (`:player` or `:spectator`)
- Differentiate authorization: players must be in player_ids, spectators can join if room not full
- Create separate join path for spectators vs players
- In `apply_game_action/1`, add guard to reject non-player actions for spectators
- Add spectator-specific event handling (read-only access to game state)
- Track spectator presence separately if needed

**Logic Changes:**
```elixir
def join("game:" <> room_code, _params, socket) do
  user_id = socket.assigns.user_id
  
  with {:ok, room} <- RoomManager.get_room(room_code),
       role <- determine_user_role(user_id, room)  # :player, :spectator, or :error
  do
    case role do
      :player -> 
        # Existing player join flow
        proceed_with_join(room_code, user_id, socket, :player, :new)
      
      :spectator ->
        # New spectator join flow
        proceed_spectator_join(room_code, user_id, socket)
      
      :error ->
        {:error, %{reason: "Access denied"}}
    end
  end
end

defp determine_user_role(user_id, room) do
  cond do
    user_id in room.player_ids -> :player
    user_id in room.spectator_ids -> :spectator
    room.status in [:playing, :finished] -> :spectator  # Allow joining as spectator
    true -> :error  # Can't join waiting room as spectator
  end
end
```

#### C. `lib/pidro_server_web/controllers/api/room_controller.ex`
**Changes Needed:**
- Add `join_as_spectator/2` action (or modify join to accept role parameter)
- Update `show/2` to include spectator count in response
- Add `state/2` endpoint filtering for spectators (could show all game state, or filtered)

**New Endpoint:**
```elixir
@spec join_as_spectator(Plug.Conn.t(), map()) :: Plug.Conn.t()
def join_as_spectator(conn, %{"code" => code}) do
  user = conn.assigns[:current_user]
  
  with {:ok, room} <- RoomManager.join_spectator_room(code, user.id) do
    conn
    |> put_view(RoomJSON)
    |> render(:show, %{room: room})
  end
end
```

#### D. `lib/pidro_server_web/router.ex`
**Changes Needed:**
- Add new route for spectator join endpoint

**New Routes:**
```elixir
scope "/api/v1", PidroServerWeb.API do
  pipe_through :api_authenticated
  
  # Existing
  post "/rooms/:code/join", RoomController, :join
  delete "/rooms/:code/leave", RoomController, :leave
  
  # New
  post "/rooms/:code/watch", RoomController, :join_as_spectator
  delete "/rooms/:code/unwatch", RoomController, :leave_as_spectator
end
```

### 2.2 Supporting Files (Modify as Needed)

#### A. `lib/pidro_server_web/channels/lobby_channel.ex`
**Changes Needed:**
- Update room serialization to include spectator count
- Allow clients to see which rooms have active spectators

#### B. `lib/pidro_server/games/game_adapter.ex`
**Status:** Likely no changes needed
- Game state is already broadcasted to all connected clients
- Filtering can happen at channel level

---

## 3. Game State Sharing & Filtering for Spectators

### 3.1 Current State Architecture

**Game State Structure:** (from Pidro.Server)
```
%{
  phase: :bidding | :trump | :playing | :game_over,
  hand_number: integer,
  current_turn: :north | :east | :south | :west,
  current_dealer: atom(),
  players: %{
    :north => %{position: :north, team: :north_south, hand: [...], tricks_won: 0},
    :east => %{...},
    :south => %{...},
    :west => %{...}
  },
  bids: [%{position: atom, amount: integer | "pass"}, ...],
  tricks: [...],
  cumulative_scores: %{north_south: int, east_west: int},
  bid_amount: integer,
  bid_team: atom,
  winner: atom,
  scores: %{...}
}
```

### 3.2 Spectator State Filtering Strategies

#### Option A: Full State (Recommended for MVP)
**Approach:** Send complete game state to spectators
**Pros:**
- Minimal code changes
- Spectators see everything (hidden information too)
- Matches TV broadcast experience
**Cons:**
- Could be seen as unfair if they're advising players
- Requires explicit client-side hiding of info

**Implementation:** No changes needed at server, just control what client displays

#### Option B: Filtered State (More Complex)
**Approach:** Server-side filtering of hands and hidden info
**Pros:**
- More fair for competitive play
- Cleaner API contract
**Cons:**
- Requires filtering function in GameChannel
- Spectators can't see all information (might not want to watch)

**Implementation:**
```elixir
defp filter_state_for_spectator(state) do
  # Remove player hands
  # Keep: phase, current_turn, tricks, bids, scores, etc.
  state
  |> Map.update!(:players, fn players ->
    Map.new(players, fn {pos, player} ->
      {pos, Map.put(player, :hand, [])}  # Hide hand
    end)
  end)
end
```

#### Option C: Hybrid (Best for Scale)
**Approach:** Separate "public" and "private" state channels
**Pros:**
- Clean separation of concerns
- Easy to implement in future
**Cons:**
- More complex now

**Implementation:** Not needed for MVP

### 3.3 Recommended Approach
**Use Option A (Full State) for MVP:**
1. Send complete game state to both players and spectators
2. Client-side filtering if needed (don't display hidden cards)
3. Document that spectators see all information
4. Can refactor to Option B later if competitive fairness becomes issue

---

## 4. Presence Tracking for Spectators

### 4.1 Current Presence Implementation
- Tracked via `Presence.track(socket, user_id, metadata)`
- Presence metadata includes: `online_at`, `position` (player position)
- Broadcasts `presence_diff` events to all channel members

### 4.2 Spectator Presence Enhancement

**Option 1: Same Presence System (Recommended)**
```elixir
# For spectators
Presence.track(socket, user_id, %{
  online_at: DateTime.utc_now() |> DateTime.to_unix(),
  role: :spectator  # Add role field
})
```

**Advantages:**
- Uses existing system
- Clients can distinguish by `role` field
- No infrastructure changes

**Option 2: Separate Presence Tracking**
```elixir
# Track spectators in a different key structure
Presence.track(socket, "spectator:#{user_id}", %{...})
```

**Disadvantages:**
- More complex
- Harder to list all viewers

### 4.3 Implementation
**In GameChannel.handle_info(:after_join, socket):**
```elixir
def handle_info(:after_join, socket) do
  user_id = socket.assigns.user_id
  role = socket.assigns.role  # :player or :spectator
  
  {:ok, _} =
    Presence.track(socket, user_id, %{
      online_at: DateTime.utc_now() |> DateTime.to_unix(),
      position: socket.assigns[:position],  # nil for spectators
      role: role
    })
  
  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end
```

---

## 5. Room Struct Enhancements

### 5.1 New Fields to Add

```elixir
defmodule RoomManager.Room do
  defstruct [
    :code,
    :host_id,
    :player_ids,
    :status,
    :max_players,
    :created_at,
    :metadata,
    disconnected_players: %{},
    
    # NEW FIELDS FOR SPECTATORS
    spectator_ids: [],           # List of spectator user IDs
    max_spectators: 10,          # Max spectators allowed (configurable)
    spectator_disconnects: %{}   # Optional: Map of {user_id => DateTime}
  ]
  
  @type status :: :waiting | :ready | :playing | :finished | :closed
  @type t :: %__MODULE__{
          code: String.t(),
          host_id: String.t(),
          player_ids: [String.t()],
          spectator_ids: [String.t()],
          status: status(),
          max_players: integer(),
          max_spectators: integer(),
          created_at: DateTime.t(),
          metadata: map(),
          disconnected_players: %{String.t() => DateTime.t()},
          spectator_disconnects: %{String.t() => DateTime.t()}
        }
end
```

### 5.2 Migration Path
1. Add optional fields with defaults
2. Existing rooms continue to work
3. New rooms created with spectator fields

---

## 6. Implementation Roadmap

### Phase 1: Core Spectator Join (Minimal MVP)
**Files to Modify:**
1. `room_manager.ex`:
   - Add `spectator_ids`, `max_spectators` to Room struct
   - Add `join_spectator_room/2` and `leave_spectator/2`
   - Update broadcasts to include spectator info

2. `game_channel.ex`:
   - Modify `join/3` to support spectators
   - Add role field to socket assigns
   - Guard `apply_game_action` for non-spectators

3. `room_controller.ex`:
   - Add `join_as_spectator/2` action
   - Update `show/2` to include spectator count

4. `router.ex`:
   - Add `/rooms/:code/watch` and `/rooms/:code/unwatch` routes

5. `lobby_channel.ex`:
   - Update room serialization

**Time Estimate:** 4-6 hours

### Phase 2: Spectator Presence & List
**Files to Modify:**
1. `game_channel.ex`:
   - Add role to presence metadata
   - Update presence tracking logic

**Time Estimate:** 2 hours

### Phase 3: Spectator Disconnect/Reconnect (Optional)
**Files to Modify:**
1. `room_manager.ex`:
   - Add spectator grace period handling (similar to players but simpler)

**Time Estimate:** 3-4 hours

### Phase 4: Filtered State (Optional)
**Files to Modify:**
1. `game_channel.ex`:
   - Add filtering function for spectators

**Time Estimate:** 2-3 hours

### Phase 5: Admin/Host Controls (Optional)
**New Files:**
- `spectator_manager.ex` for advanced controls

**Time Estimate:** 4+ hours

---

## 7. Specific Code Examples

### 7.1 RoomManager Changes

**Add to Room.ex struct:**
```elixir
spectator_ids: [],           # Default empty list
max_spectators: 10           # Default limit
```

**Add new function:**
```elixir
@doc """
Allows a user to join a room as a spectator.

A spectator can watch the game but cannot make game actions.
Spectators do not count toward the 4-player limit.

## Parameters
- `room_code` - The unique room code
- `spectator_id` - User ID of the spectating user

## Returns
- `{:ok, room}` - Successfully joined as spectator
- `{:error, :room_not_found}` - Room doesn't exist
- `{:error, :max_spectators_reached}` - Too many spectators
- `{:error, :already_in_room}` - User is already a player in this room
"""
@spec join_spectator_room(String.t(), String.t()) ::
        {:ok, Room.t()} | 
        {:error, :room_not_found | :max_spectators_reached | :already_in_room | :already_spectating}
def join_spectator_room(room_code, spectator_id) do
  GenServer.call(__MODULE__, {:join_spectator_room, String.upcase(room_code), spectator_id})
end

# In handle_call:
def handle_call({:join_spectator_room, room_code, spectator_id}, _from, %State{} = state) do
  cond do
    not Map.has_key?(state.rooms, room_code) ->
      {:reply, {:error, :room_not_found}, state}
    
    Map.has_key?(state.player_rooms, spectator_id) ->
      # Already a player in some room
      {:reply, {:error, :already_in_room}, state}
    
    true ->
      %Room{} = room = state.rooms[room_code]
      
      cond do
        spectator_id in room.spectator_ids ->
          {:reply, {:error, :already_spectating}, state}
        
        length(room.spectator_ids) >= room.max_spectators ->
          {:reply, {:error, :max_spectators_reached}, state}
        
        true ->
          updated_room = %Room{
            room
            | spectator_ids: room.spectator_ids ++ [spectator_id]
          }
          
          new_state = %State{
            state
            | rooms: Map.put(state.rooms, room_code, updated_room)
          }
          
          Logger.info("Spectator #{spectator_id} joined room #{room_code}")
          broadcast_room(room_code, updated_room)
          broadcast_lobby(new_state)
          
          {:reply, {:ok, updated_room}, new_state}
      end
  end
end
```

### 7.2 GameChannel Changes

**Modify join/3:**
```elixir
@impl true
def join("game:" <> room_code, _params, socket) do
  user_id = socket.assigns.user_id
  
  with {:ok, room} <- RoomManager.get_room(room_code) do
    role = determine_user_role(user_id, room)
    
    case role do
      :player ->
        # Existing player flow
        proceed_with_player_join(room_code, user_id, socket)
      
      :spectator ->
        # New spectator flow
        proceed_with_spectator_join(room_code, user_id, socket)
      
      :not_allowed ->
        {:error, %{reason: "Cannot join this room"}}
    end
  else
    _ -> {:error, %{reason: "room not found"}}
  end
end

defp determine_user_role(user_id, room) do
  cond do
    user_id in room.player_ids -> :player
    user_id in room.spectator_ids -> :spectator
    room.status in [:playing, :finished] -> :spectator  # Can join as spectator
    room.status == :waiting and length(room.player_ids) < 4 -> :spectator  # Or prevent this
    true -> :not_allowed
  end
end

defp proceed_with_spectator_join(room_code, user_id, socket) do
  with {:ok, room} <- RoomManager.get_room(room_code),
       {:ok, _pid} <- GameAdapter.get_game(room_code),
       :ok <- GameAdapter.subscribe(room_code) do
    {:ok, state} = GameAdapter.get_state(room_code)
    
    socket = 
      socket
      |> assign(:room_code, room_code)
      |> assign(:role, :spectator)  # Mark as spectator
      |> assign(:position, nil)      # Spectators have no position
    
    send(self(), :after_join)
    
    reply_data = %{
      state: state,
      role: :spectator
    }
    
    {:ok, reply_data, socket}
  else
    error -> {:error, %{reason: "Failed to join as spectator"}}
  end
end

# Prevent spectators from making game actions
defp apply_game_action(socket, _action) when socket.assigns.role == :spectator do
  {:reply, {:error, %{reason: "Spectators cannot perform actions"}}, socket}
end

defp apply_game_action(socket, action) do
  # Existing player flow
  room_code = socket.assigns.room_code
  position = socket.assigns.position
  
  case GameAdapter.apply_action(room_code, position, action) do
    {:ok, _new_state} ->
      {:reply, :ok, socket}
    {:error, reason} ->
      {:reply, {:error, %{reason: format_error(reason)}}, socket}
  end
end

# Update presence tracking
def handle_info(:after_join, socket) do
  user_id = socket.assigns.user_id
  role = socket.assigns.role
  
  presence_data = %{
    online_at: DateTime.utc_now() |> DateTime.to_unix(),
    role: role
  }
  
  presence_data = 
    if role == :player do
      Map.put(presence_data, :position, socket.assigns.position)
    else
      presence_data
    end
  
  {:ok, _} = Presence.track(socket, user_id, presence_data)
  
  push(socket, "presence_state", Presence.list(socket))
  {:noreply, socket}
end
```

### 7.3 RoomController Changes

**Add spectator join:**
```elixir
@doc """
Join a room as a spectator.

Allows a user to watch an active game without being a player.
"""
@spec join_as_spectator(Plug.Conn.t(), map()) :: Plug.Conn.t()
def join_as_spectator(conn, %{"code" => code}) do
  user = conn.assigns[:current_user]
  
  with {:ok, room} <- RoomManager.join_spectator_room(code, user.id) do
    conn
    |> put_view(RoomJSON)
    |> render(:show, %{room: room})
  end
end

@doc """
Leave a room as a spectator.
"""
@spec leave_as_spectator(Plug.Conn.t(), map()) :: Plug.Conn.t()
def leave_as_spectator(conn, %{"code" => code}) do
  user = conn.assigns[:current_user]
  
  with :ok <- RoomManager.leave_spectator(code, user.id) do
    conn
    |> put_status(:no_content)
    |> send_resp(:no_content, "")
  end
end
```

### 7.4 Router Changes

**Add routes:**
```elixir
scope "/api/v1", PidroServerWeb.API do
  pipe_through :api_authenticated
  
  # Existing room routes
  post "/rooms", RoomController, :create
  post "/rooms/:code/join", RoomController, :join
  delete "/rooms/:code/leave", RoomController, :leave
  
  # New spectator routes
  post "/rooms/:code/watch", RoomController, :join_as_spectator
  delete "/rooms/:code/unwatch", RoomController, :leave_as_spectator
end
```

---

## 8. Testing Strategy

### 8.1 Unit Tests

**RoomManager Tests:**
```elixir
test "allows spectator to join active game" do
  {:ok, room} = RoomManager.create_room("user1", %{})
  {:ok, _} = RoomManager.join_room(room.code, "user2")
  
  {:ok, updated_room} = RoomManager.join_spectator_room(room.code, "spectator1")
  
  assert "spectator1" in updated_room.spectator_ids
end

test "prevents exceeding max spectators" do
  {:ok, room} = RoomManager.create_room("user1", %{})
  
  # Join max_spectators spectators
  for i <- 1..10 do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "spectator#{i}")
  end
  
  # 11th should fail
  assert {:error, :max_spectators_reached} = 
    RoomManager.join_spectator_room(room.code, "spectator11")
end

test "prevents player from joining as spectator if already playing" do
  {:ok, room} = RoomManager.create_room("user1", %{})
  {:ok, _} = RoomManager.join_room(room.code, "user2")
  
  assert {:error, :already_in_room} = 
    RoomManager.join_spectator_room(room.code, "user2")
end
```

**GameChannel Tests:**
```elixir
test "spectator can join active game" do
  # Setup game with 4 players
  # Connect as spectator
  # Verify join succeeds
end

test "spectator cannot perform game actions" do
  # Join as spectator
  # Attempt to bid
  # Verify error returned
end

test "spectator sees game state updates" do
  # Join as spectator
  # Have player make move
  # Verify spectator receives state update
end
```

### 8.2 Integration Tests

```elixir
test "spectator can watch multiple games" do
  # Create 2 games
  # Join both as different spectator users
  # Verify presence in both rooms
  # Verify state updates in both
end

test "spectator disconnect and reconnect" do
  # Join as spectator
  # Simulate disconnect
  # Reconnect
  # Verify state is current
end
```

### 8.3 Client-Side Tests (JavaScript)
```javascript
test("spectator role prevents action events", () => {
  // Join as spectator
  // Attempt to push game actions
  // Verify error handling
})
```

---

## 9. API Endpoint Changes

### 9.1 New Endpoints

**POST /api/v1/rooms/:code/watch**
```
Join a room as a spectator.

Request:
  POST /api/v1/rooms/A3F9/watch
  Authorization: Bearer <token>

Response (200 OK):
  {
    "data": {
      "room": {
        "code": "A3F9",
        "host_id": "user1",
        "player_ids": ["user1", "user2", "user3", "user4"],
        "spectator_ids": ["spectator1"],
        "spectator_count": 1,
        "status": "playing",
        "max_players": 4,
        "max_spectators": 10,
        "created_at": "2024-11-02T10:30:00Z"
      }
    }
  }

Error Cases:
  - 404: Room not found
  - 422: Max spectators reached, user already a player in another room
  - 401: Unauthorized
```

**DELETE /api/v1/rooms/:code/unwatch**
```
Leave a room as a spectator.

Request:
  DELETE /api/v1/rooms/A3F9/unwatch
  Authorization: Bearer <token>

Response (204 No Content):
  (empty body)

Error Cases:
  - 404: Room not found, user not spectating
  - 401: Unauthorized
```

### 9.2 Modified Endpoints

**GET /api/v1/rooms/:code**
```
Response now includes spectator info:

{
  "data": {
    "room": {
      "code": "A3F9",
      "host_id": "user1",
      "player_ids": ["user1", "user2", "user3", "user4"],
      "spectator_ids": ["spectator1", "spectator2"],  # NEW
      "spectator_count": 2,  # NEW
      "status": "playing",
      "max_players": 4,
      "max_spectators": 10,  # NEW
      "created_at": "2024-11-02T10:30:00Z"
    }
  }
}
```

**GET /api/v1/rooms**
```
Rooms list now includes spectator count:

{
  "data": {
    "rooms": [
      {
        "code": "A3F9",
        "host_id": "user1",
        "player_count": 4,
        "spectator_count": 2,  # NEW
        "status": "playing",
        "max_players": 4,
        "created_at": "2024-11-02T10:30:00Z"
      }
    ]
  }
}
```

---

## 10. Event Flow Diagram

### Spectator Join Flow
```
Client                  GameChannel              RoomManager            GameAdapter
  │                          │                        │                      │
  ├──POST /watch────────────>│                        │                      │
  │                          │                        │                      │
  │                          ├──join_spectator_room──>│                      │
  │                          │                        │                      │
  │                          │                  <──OK──┤                      │
  │                          │                        │                      │
  │                          ├──subscribe────────────────────────────────────>│
  │                          │                        │                      │
  │                          │                  <──:ok─────────────────────────┤
  │                          │                        │                      │
  │                          ├──get_state────────────────────────────────────>│
  │                          │                        │                      │
  │                          │                  <──state──────────────────────┤
  │                          │                        │                      │
  │    <──200 OK/socket──────┤                        │                      │
  │       (with state)       │                        │                      │
  │                          │                        │                      │
```

### Game Action by Player (Spectator Listening)
```
Player Client      GameChannel       GameAdapter    Pidro.Server    Spectator Client
     │                 │                  │              │               │
     ├──push "bid"────>│                  │              │               │
     │                 │                  │              │               │
     │                 ├─apply_action────>│              │               │
     │                 │                  │              │               │
     │                 │                  ├─apply───────>│               │
     │                 │                  │              │               │
     │                 │                  │         <─OK─┤               │
     │                 │                  │              │               │
     │                 ├─broadcast_state_update         │               │
     │                 │   (PubSub "game:A3F9")        │               │
     │                 │                  │              │               │
     │                 ├────────────────────────────────────────────────>│
     │                 │ (game_state event)              │               │
     │ <──push reply─────                 │              │               │
     │                 │                  │              │               │

```

---

## 11. Configuration Considerations

### 11.1 Environment Variables/Config

```elixir
# config/runtime.exs or per-environment config

config :pidro_server, :game_rooms,
  max_spectators_per_room: 10,
  spectator_grace_period_seconds: 30  # Optional disconnect period
```

### 11.2 Scalability Notes

**For Moderate Scale (10-100 concurrent games):**
- Current RoomManager GenServer approach is fine
- Spectators don't require player-level precision tracking
- Can keep disconnected_players map simple

**For Large Scale (1000+ concurrent games):**
- Consider moving to database-backed room storage
- Use PostgreSQL's LISTEN/NOTIFY for broadcasts instead of PubSub
- Implement sharded RoomManager (multiple GenServers)
- Use presence clustering if distributed

---

## 12. Migration & Backward Compatibility

### 12.1 Room Struct Migration

**Before:**
```elixir
%Room{
  code: "A3F9",
  host_id: "user1",
  player_ids: [...],
  status: :playing,
  max_players: 4,
  created_at: DateTime,
  metadata: %{},
  disconnected_players: %{}
}
```

**After:**
```elixir
%Room{
  code: "A3F9",
  host_id: "user1",
  player_ids: [...],
  spectator_ids: [],           # NEW
  status: :playing,
  max_players: 4,
  max_spectators: 10,          # NEW (configurable)
  created_at: DateTime,
  metadata: %{},
  disconnected_players: %{},
  spectator_disconnects: %{}   # NEW (optional)
}
```

### 12.2 API Response Compatibility

**Clients expecting old response format:**
- Still works (new fields just ignored)
- Update clients to handle new fields

**New fields are additive, no breaking changes** if done correctly

---

## 13. Future Enhancements

### 13.1 Spectator Controls
- Mute/unmute spectators
- Kick spectators
- Spectator chat/comments
- Spectator list visibility

### 13.2 Advanced Features
- Spectator analytics (watch time, common viewers)
- Spectator-only chat (separate from players)
- Replay/recording for spectators
- Filtered state views (hide hands for tournament play)

### 13.3 Performance
- Pagination of spectator list
- Lazy loading of spectators
- Delta compression for state updates

---

## 14. Summary Table: Changes Required

| File | Module | Type | Effort | Complexity |
|------|--------|------|--------|-----------|
| room_manager.ex | RoomManager | Add functions | 3h | Medium |
| game_channel.ex | GameChannel | Modify join/action flow | 3h | Medium |
| room_controller.ex | RoomController | Add endpoints | 1h | Low |
| router.ex | Router | Add routes | 0.5h | Low |
| lobby_channel.ex | LobbyChannel | Update serialization | 0.5h | Low |
| Tests | Various | Add tests | 3-4h | Medium |
| **TOTAL** | | | **11-12h** | **Medium** |

---

## Conclusion

Implementing spectator mode in the Pidro server is **straightforward and low-risk** because:

1. **Minimal architectural changes**: RoomManager and GameChannel can accommodate spectators without major refactoring
2. **Existing broadcasting works**: GameAdapter already broadcasts full state to all channel members
3. **Clear separation of concerns**: Spectators are read-only, require no validation
4. **Backward compatible**: New fields can be optional defaults
5. **Scalable approach**: Works for 10 or 1000+ concurrent games

The recommended approach is **MVP-first**: Implement Phase 1 (basic spectator join/watch), then add enhancements based on user feedback and requirements.

