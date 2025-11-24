---
date: 2025-11-23T18:39:19+0000
researcher: Claude
git_commit: bbb81965163f843bb2db08cf9338b6e756520b56
branch: main
repository: marcelfahle/pidro-backend
topic: "Pidro Presence Strategy Implementation Guide"
tags: [research, codebase, presence, channels, room-manager, real-time]
status: complete
last_updated: 2025-11-23
last_updated_by: Claude
---

# Research: Pidro Presence Strategy Implementation Guide

**Date**: 2025-11-23T18:39:19+0000
**Researcher**: Claude
**Git Commit**: bbb81965163f843bb2db08cf9338b6e756520b56
**Branch**: main
**Repository**: marcelfahle/pidro-backend

## Research Question

How should the Pidro Presence Strategy (specified in `specs/pidro_presence.md`) be implemented to match the existing codebase architecture, conventions, and best practices while making Dave Thomas proud with idiomatic Elixir?

## Summary

The Pidro backend already has a strong foundation for implementing Phoenix Presence with real-time player tracking. The codebase follows clean OTP principles with proper supervision trees, uses Phoenix.PubSub for event broadcasting, and has existing channel implementations that can be enhanced with presence tracking. The implementation should leverage the existing `RoomManager` GenServer, existing `GameChannel` and `LobbyChannel`, and the already-configured `PidroServerWeb.Presence` module.

**Key Implementation Strategy:**
- Enhance existing channels rather than replacing them
- Add presence tracking to existing socket assigns
- Extend `RoomManager` with disconnect/reconnect tracking fields
- Leverage existing PubSub topics and broadcast patterns
- Follow established GenServer patterns (handle_call, handle_info, Process.send_after)
- Maintain idiomatic Elixir with pattern matching and small focused functions

## Detailed Findings

### 1. Current Phoenix Application Structure

The application is well-structured with proper separation of concerns:

**Application Supervision Tree** (`lib/pidro_server/application.ex:8-31`):
```
PidroServer.Application (one_for_one)
├── PidroServerWeb.Telemetry
├── PidroServer.Repo
├── Phoenix.PubSub (name: PidroServer.PubSub)
├── PidroServerWeb.Presence ✓ Already configured
├── PidroServer.Games.Supervisor
│   ├── PidroServer.Games.GameRegistry
│   ├── PidroServer.Games.GameSupervisor
│   └── PidroServer.Games.RoomManager
├── [Dev tools in dev environment]
└── PidroServerWeb.Endpoint
```

**Key Observation**: `PidroServerWeb.Presence` already exists and is supervised at `lib/pidro_server_web/presence.ex:30-32`. This is ready to use without additional configuration.

### 2. Existing Channel Implementations

#### LobbyChannel (`lib/pidro_server_web/channels/lobby_channel.ex`)

**Current Implementation**:
- Joins on topic `"lobby"` (line 57)
- Subscribes to `"lobby:updates"` PubSub topic (line 59)
- Returns current room list via `RoomManager.list_rooms(:available)` (line 62)
- Uses `:after_join` pattern for deferred setup (line 65)

**What Already Works**:
- Socket authentication via `UserSocket.connect/3`
- PubSub subscription for room updates
- Room list broadcasting to all lobby subscribers

**What Needs Adding**:
- Phoenix.Presence tracking in `:after_join` handler
- `presence_diff` handling to broadcast online user counts
- Initial `presence_state` push to client

#### GameChannel (`lib/pidro_server_web/channels/game_channel.ex`)

**Current Implementation**:
- Pattern matches topic `"game:" <> room_code` (line 75)
- Validates room membership via `determine_user_role/2` (line 81)
- Supports both players and spectators (lines 84-117)
- Has reconnection detection but NOT yet using `RoomManager.handle_player_reconnect/2` (lines 86-109)
- Subscribes to game updates via `GameAdapter.subscribe/1` (line 132)
- Assigns socket state: `:room_code`, `:position`, `:role`, `:join_type` (lines 138-142)
- Has `terminate/2` callback that leaves room (lines 350-390)

**What Already Works**:
- Player/spectator role determination
- Socket assigns for position tracking
- Terminate callback for disconnect handling
- PubSub subscription for game events

**What Needs Enhancement**:
- Add Phoenix.Presence tracking in `:after_join`
- Integrate `RoomManager.handle_player_disconnect/2` in `terminate/2`
- Use `RoomManager.handle_player_reconnect/2` for grace period
- Handle `presence_diff` events
- Broadcast player status changes

### 3. RoomManager Current Implementation

**Process Type**: GenServer (`lib/pidro_server/games/room_manager.ex:43`)

**Current State Structure** (lines 99-111):
```elixir
defmodule State do
  defstruct rooms: %{},              # room_code => Room
            player_rooms: %{},       # player_id => room_code
            spectator_rooms: %{}     # spectator_id => room_code
end
```

**Current Room Struct** (lines 52-96):
```elixir
defmodule Room do
  @type t :: %__MODULE__{
    code: String.t(),
    host_id: String.t(),
    player_ids: [String.t()],
    spectator_ids: [String.t()],
    status: status(),                # :waiting | :ready | :playing | :finished | :closed
    max_players: integer(),
    max_spectators: integer(),
    created_at: DateTime.t(),
    metadata: map(),
    disconnected_players: %{String.t() => DateTime.t()}  # ✓ Already exists!
  }
end
```

**Critical Discovery**: The `disconnected_players` field already exists in the Room struct (line 70)! This means the data structure for disconnect tracking is already in place.

**Current Public API** (lines 154-455):
- `create_room/2` - Creates room, adds host as first player
- `join_room/2` - Adds player, auto-starts game when 4 players
- `leave_room/1` - Removes player, special handling for host
- `list_rooms/1` - Filtered room lists (`:all`, `:waiting`, `:ready`, `:playing`, `:available`)
- `get_room/1` - Retrieve specific room
- `update_room_status/2` - Change room status
- `close_room/1` - Delete room
- `join_spectator_room/2` - Add spectator
- `leave_spectator/1` - Remove spectator
- `is_spectator?/2` - Check spectator status
- `handle_player_disconnect/2` - ⚠️ **Already exists!** (line 407)
- `handle_player_reconnect/2` - ⚠️ **Already exists!** (line 436)

**Major Discovery**: `RoomManager` already has `handle_player_disconnect/2` and `handle_player_reconnect/2` functions! Let's examine them:

**`handle_player_disconnect/2`** (lines 407-433):
- Marks player as disconnected with timestamp (line 815)
- Schedules cleanup with `Process.send_after/3` for 120 seconds (line 829)
- Sends `{:check_disconnect_timeout, room_code, user_id}` message
- Broadcasts room update immediately

**`handle_player_reconnect/2`** (lines 436-453):
- Removes player from `disconnected_players` map
- Validates grace period with `DateTime.diff/2`
- Grace period: 120 seconds (lines 848-851)
- Returns `{:error, :grace_period_expired}` if too late
- Broadcasts room update on success

**`handle_info({:check_disconnect_timeout, ...})`** (lines 887-938):
- Callback for scheduled timeout messages
- Validates room still exists
- Checks if player still disconnected
- Verifies grace period expired
- Removes player from room
- Broadcasts updates

**What's Already Complete**:
- ✅ Disconnect tracking with timestamps
- ✅ Grace period implementation (2 minutes)
- ✅ Scheduled cleanup with `Process.send_after/3`
- ✅ Reconnection within grace period
- ✅ Room broadcasting on state changes

**What Needs Adding**:
- ❌ `last_activity` timestamp field (spec line 432)
- ❌ Periodic cleanup of abandoned rooms (spec lines 579-602)
- ❌ Better integration with GameChannel's terminate/2

### 4. Existing Presence Module

**Location**: `lib/pidro_server_web/presence.ex`

**Current Configuration** (lines 30-32):
```elixir
use Phoenix.Presence,
  otp_app: :pidro_server,
  pubsub_server: PidroServer.PubSub
```

**Status**: ✅ Fully configured and supervised. Ready to use immediately with `Presence.track/3`, `Presence.list/1`, `Presence.untrack/1`.

### 5. Authentication and Socket Connection

**UserSocket** (`lib/pidro_server_web/channels/user_socket.ex`):

**Authentication Flow** (lines 45-65):
1. Extracts `"token"` parameter from connection
2. Verifies JWT with `Token.verify/1`
3. Assigns to socket (line 54-56):
   - `:user_id` - Authenticated user ID
   - `:session_id` - Unique 16-char session identifier
   - `:connected_at` - UTC timestamp

**Socket ID** (line 82):
```elixir
def id(socket), do: "user_socket:#{socket.assigns.user_id}"
```

**Channel Routes** (lines 27-28):
```elixir
channel "lobby", PidroServerWeb.LobbyChannel
channel "game:*", PidroServerWeb.GameChannel
```

**What Works**: Full JWT authentication, user_id available in all channels, unique session tracking.

### 6. PubSub Broadcasting Patterns

**Current Topics Used**:
- `"lobby:updates"` - Room list changes (subscribed in LobbyChannel:59)
- `"game:#{room_code}"` - Game-specific updates (subscribed via GameAdapter:203-205)
- `"room:#{room_code}"` - Room-specific updates (broadcast from RoomManager:980-991)

**Broadcast Helpers in RoomManager** (lines 965-991):
```elixir
defp broadcast_lobby(state) do
  available_rooms = filter_rooms(Map.values(state.rooms), :available)
  Phoenix.PubSub.broadcast(PidroServer.PubSub, "lobby:updates", {:lobby_update, available_rooms})
end

defp broadcast_room(room_code, room) do
  event = if room, do: {:room_update, room}, else: {:room_closed}
  Phoenix.PubSub.broadcast(PidroServer.PubSub, "room:#{room_code}", event)
end
```

**Pattern Observed**: Private helper functions for broadcasting, tuple messages with atoms (e.g., `{:lobby_update, data}`), returns `:ok`.

### 7. Existing Testing Patterns

The codebase has comprehensive testing conventions:

**Channel Tests** (`test/pidro_server_web/channels/`):
- Uses `subscribe_and_join/3` from Phoenix.ChannelTest
- `assert_reply/4` for synchronous responses
- `assert_broadcast/3` for channel-wide broadcasts
- `assert_push/3` for client-specific pushes
- Helper macro `create_socket/1` for authenticated sockets

**GenServer Tests** (`test/pidro_server/games/room_manager_test.exs`):
- Uses `async: false` for singleton GenServer (RoomManager)
- `start_supervised!/1` for automatic cleanup
- Custom `reset_for_test/0` function (line 455 in RoomManager)
- Retry patterns with `Enum.reduce_while/3` for async operations

**Integration Tests** (`test/pidro_server/games/game_integration_test.exs`):
- Uses `@moduletag :integration`
- Uses `assert_receive/2` for PubSub messages
- `Process.sleep/1` with retry patterns for eventual consistency

## Implementation Guide

### Phase 1: Enhance RoomManager (Server-Side Foundation)

#### Step 1.1: Add `last_activity` Field to Room Struct

**File**: `lib/pidro_server/games/room_manager.ex`

**Change at lines 52-96** (Room struct definition):
```elixir
defmodule Room do
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
    last_activity: DateTime.t()  # ADD THIS
  }

  defstruct [
    :code,
    :host_id,
    :player_ids,
    :status,
    :max_players,
    :created_at,
    :metadata,
    :last_activity,  # ADD THIS
    spectator_ids: [],
    max_spectators: 10,
    disconnected_players: %{}
  ]
end
```

#### Step 1.2: Update `last_activity` in All Room Operations

**Pattern to follow**: Every room state change should update `last_activity`:

```elixir
updated_room = %{room |
  # ... other changes ...
  last_activity: DateTime.utc_now()
}
```

**Functions to update** (add `last_activity: DateTime.utc_now()` to room updates):
- `handle_call({:create_room, ...})` (line 476)
- `handle_call({:join_room, ...})` (line 525)
- `handle_call({:leave_room, ...})` (line 609)
- `handle_call({:player_disconnect, ...})` (line 815)
- `handle_call({:player_reconnect, ...})` (line 856)
- `handle_call({:update_room_status, ...})` (line 659)

#### Step 1.3: Add Periodic Cleanup Task

**Add to `init/1`** (after line 462):
```elixir
@impl true
def init(_arg) do
  # Schedule periodic cleanup of abandoned rooms
  Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))

  {:ok, %State{
    rooms: %{},
    player_rooms: %{},
    spectator_rooms: %{}
  }}
end
```

**Add new `handle_info/2` callback** (add after line 938):
```elixir
@impl true
def handle_info(:cleanup_abandoned_rooms, state) do
  now = DateTime.utc_now()
  grace_period_minutes = 5

  # Find abandoned rooms: status :waiting, no activity, no presence
  abandoned_rooms =
    state.rooms
    |> Enum.filter(fn {code, room} ->
      room.status == :waiting &&
      DateTime.diff(now, room.last_activity, :minute) > grace_period_minutes &&
      map_size(Presence.list("game:#{code}")) == 0
    end)
    |> Enum.map(fn {code, _room} -> code end)

  # Delete abandoned rooms
  updated_state =
    Enum.reduce(abandoned_rooms, state, fn code, acc_state ->
      case Map.get(acc_state.rooms, code) do
        nil -> acc_state
        room ->
          # Remove room
          updated_rooms = Map.delete(acc_state.rooms, code)

          # Clean up player mappings
          updated_player_rooms =
            Enum.reduce(room.player_ids, acc_state.player_rooms, fn player_id, acc ->
              Map.delete(acc, player_id)
            end)

          # Clean up spectator mappings
          updated_spectator_rooms =
            Enum.reduce(room.spectator_ids, acc_state.spectator_rooms, fn spectator_id, acc ->
              Map.delete(acc, spectator_id)
            end)

          # Broadcast room closed
          broadcast_room(code, nil)
          broadcast_lobby(%{acc_state | rooms: updated_rooms})

          Logger.info("Cleaned up abandoned room: #{code}")

          %{acc_state |
            rooms: updated_rooms,
            player_rooms: updated_player_rooms,
            spectator_rooms: updated_spectator_rooms
          }
      end
    end)

  # Schedule next cleanup
  Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))

  {:noreply, updated_state}
end
```

**Rationale**: This follows the existing `handle_info({:check_disconnect_timeout, ...})` pattern at line 887. Uses the same cleanup approach with `Enum.reduce/3` to maintain immutable state.

### Phase 2: Enhance LobbyChannel with Presence

**File**: `lib/pidro_server_web/channels/lobby_channel.ex`

#### Step 2.1: Update `:after_join` Handler

**Replace existing implementation** (lines 85-95):
```elixir
@impl true
def handle_info(:after_join, socket) do
  user_id = socket.assigns.user_id

  # Track user in lobby presence
  {:ok, _} = Presence.track(socket, user_id, %{
    online_at: DateTime.utc_now() |> DateTime.to_unix(),
    status: :browsing,
    last_game_code: nil,  # Could fetch from AsyncStorage later
    connection_id: socket.id
  })

  # Push initial presence state to client
  push(socket, "presence_state", Presence.list(socket))

  {:noreply, socket}
end
```

#### Step 2.2: Add `presence_diff` Handler

**Add new handler** (after `:after_join` handler):
```elixir
@impl true
def handle_info(%{event: "presence_diff", payload: diff}, socket) do
  # Calculate online user count
  online_count = Presence.list(socket) |> map_size()

  # Broadcast lobby stats to all clients
  broadcast(socket, "lobby_stats", %{
    online_users: online_count,
    joins: map_size(diff.joins),
    leaves: map_size(diff.leaves)
  })

  {:noreply, socket}
end
```

**Rationale**: Uses existing patterns from the codebase. The presence_diff event is automatically sent by Phoenix.Presence when users join/leave.

### Phase 3: Enhance GameChannel with Presence

**File**: `lib/pidro_server_web/channels/game_channel.ex`

#### Step 3.1: Integrate RoomManager Disconnect in `terminate/2`

**Update existing `terminate/2`** (lines 350-390). Find the player disconnection section (lines 358-371) and change:

**FROM**:
```elixir
# Player disconnected
Logger.info("Player #{user_id} disconnected from game #{room_code}")

# Remove from room
:ok = RoomManager.leave_room(user_id)

# Broadcast disconnection
broadcast(socket, "player_disconnected", %{
  user_id: user_id,
  position: socket.assigns[:position],
  reason: format_reason(reason)
})
```

**TO**:
```elixir
# Player disconnected
Logger.info("Player #{user_id} disconnected from game #{room_code}, starting grace period")

# Mark as disconnected (starts 2-minute grace period)
:ok = RoomManager.handle_player_disconnect(room_code, user_id)

# Broadcast disconnection (not a permanent leave!)
broadcast(socket, "player_disconnected", %{
  user_id: user_id,
  position: socket.assigns[:position],
  reason: format_reason(reason),
  grace_period: true
})
```

**Rationale**: This leverages the existing `handle_player_disconnect/2` function that already implements the grace period logic (line 407).

#### Step 3.2: Enhance Join for Reconnection

**Update the reconnection check** (lines 86-109). The current implementation broadcasts reconnection but doesn't call `RoomManager.handle_player_reconnect/2`.

**FROM** (lines 86-109):
```elixir
if Map.has_key?(room.disconnected_players || %{}, user_id) do
  # Attempt reconnection
  case RoomManager.handle_player_reconnect(room_code, user_id) do
    {:ok, updated_room} ->
      # Broadcast reconnection to other players
      broadcast_from(socket, "player_reconnected", %{
        user_id: user_id,
        position: position
      })
      proceed_with_join(room_code, user_id, socket, :reconnect, :player)

    {:error, :grace_period_expired} ->
      Logger.warning("Grace period expired for #{user_id}")
      {:error, %{reason: "Grace period expired, please rejoin the room"}}

    {:error, reason} ->
      Logger.error("Reconnection failed: #{inspect(reason)}")
      {:error, %{reason: "Reconnection failed"}}
  end
```

**This code already exists and follows the right pattern!** But we should ensure the reconnection broadcast includes a timestamp:

**TO** (enhanced version):
```elixir
if Map.has_key?(room.disconnected_players || %{}, user_id) do
  # Attempt reconnection within grace period
  case RoomManager.handle_player_reconnect(room_code, user_id) do
    {:ok, updated_room} ->
      Logger.info("Player #{user_id} reconnected to #{room_code} within grace period")

      # Broadcast reconnection to other players
      broadcast_from(socket, "player_reconnected", %{
        user_id: user_id,
        position: position,
        reconnected_at: DateTime.utc_now()  # ADD THIS
      })

      proceed_with_join(room_code, user_id, socket, :reconnect, :player)

    {:error, :grace_period_expired} ->
      Logger.warning("Grace period expired for #{user_id} in room #{room_code}")
      {:error, %{reason: "Grace period expired (2 minutes), please rejoin the room"}}

    {:error, reason} ->
      Logger.error("Reconnection failed for #{user_id}: #{inspect(reason)}")
      {:error, %{reason: "Reconnection failed: #{reason}"}}
  end
```

#### Step 3.3: Add Presence Tracking in `:after_join`

**Update existing `:after_join` handler** (lines 284-305). This section already exists but needs presence tracking:

**FROM** (lines 284-305):
```elixir
@impl true
def handle_info(:after_join, socket) do
  room_code = socket.assigns.room_code
  user_id = socket.assigns.user_id
  position = socket.assigns.position

  # Build presence data
  presence_data = %{
    online_at: DateTime.utc_now() |> DateTime.to_unix(),
    role: socket.assigns.role,
    # Add position only if player
    position: if(socket.assigns.role == :player, do: position, else: nil)
  }

  # Track presence
  {:ok, _} = Presence.track(socket, user_id, presence_data)

  # Push presence state
  push(socket, "presence_state", Presence.list(socket))

  {:noreply, socket}
end
```

**This already exists and looks good!** The current implementation at lines 284-305 just needs to ensure it's tracking properly.

#### Step 3.4: Add `presence_diff` Handler

**Add new handler** (after existing handlers around line 327):
```elixir
@impl true
def handle_info(%{event: "presence_diff", payload: diff}, socket) do
  # Handle joins
  for {user_id, %{metas: [meta | _]}} <- diff.joins do
    broadcast(socket, "player_joined", %{
      user_id: user_id,
      position: meta[:position],  # May be nil for spectators
      role: meta.role,
      online_at: meta.online_at
    })
  end

  # Handle leaves
  for {user_id, _meta} <- diff.leaves do
    broadcast(socket, "player_left", %{
      user_id: user_id,
      left_at: DateTime.utc_now() |> DateTime.to_unix()
    })
  end

  # Update room status based on current presence
  update_room_status_from_presence(socket.assigns.room_code)

  {:noreply, socket}
end

# Private helper
defp update_room_status_from_presence(room_code) do
  presences = Presence.list("game:#{room_code}")
  player_count =
    presences
    |> Enum.count(fn {_user_id, %{metas: [meta | _]}} ->
      meta.role == :player
    end)

  status = cond do
    player_count == 0 -> :abandoned
    player_count < 4 -> :waiting
    player_count == 4 -> :ready
    true -> :waiting
  end

  RoomManager.update_room_status(room_code, status)
end
```

**Rationale**: This follows the pattern from the spec (lines 317-339) but adapted to the existing codebase patterns. Uses private helper function pattern consistent with the rest of GameChannel.

#### Step 3.5: Add Helper for Broadcasting Player Presence

**Add private helper** (after existing private functions):
```elixir
defp broadcast_player_presence(socket) do
  room_code = socket.assigns.room_code
  presences = Presence.list("game:#{room_code}")

  players =
    presences
    |> Enum.filter(fn {_user_id, %{metas: [meta | _]}} ->
      meta.role == :player
    end)
    |> Enum.map(fn {user_id, %{metas: [meta | _]}} ->
      %{
        user_id: user_id,
        position: meta[:position],
        online: true,
        online_at: meta.online_at
      }
    end)

  broadcast(socket, "players_updated", %{
    players: players,
    count: length(players)
  })
end
```

### Phase 4: Add Tests

#### Test 4.1: LobbyChannel Presence Test

**File**: `test/pidro_server_web/channels/lobby_channel_test.exs`

**Add to existing describe blocks**:
```elixir
describe "presence tracking" do
  test "tracks user presence when joining lobby", %{socket: socket} do
    {:ok, _reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    # Should receive presence_state after join
    assert_push "presence_state", presence_state, 1000

    # Should include this user in presence
    user_id = socket.assigns.user_id
    assert Map.has_key?(presence_state, to_string(user_id))
  end

  test "broadcasts lobby stats on presence changes", %{user: user1} do
    # First user joins
    {:ok, socket1} = create_socket(user1)
    {:ok, _, socket1} = subscribe_and_join(socket1, LobbyChannel, "lobby", %{})

    # Create and join second user
    {:ok, user2} = Accounts.Auth.register_user(%{
      username: "user2",
      email: "user2@test.com",
      password: "password123"
    })

    {:ok, socket2} = create_socket(user2)
    {:ok, _, _socket2} = subscribe_and_join(socket2, LobbyChannel, "lobby", %{})

    # Both users should receive lobby_stats broadcast
    assert_broadcast "lobby_stats", %{online_users: 2}, 1000
  end
end
```

#### Test 4.2: GameChannel Reconnection Test

**File**: `test/pidro_server_web/channels/game_channel_test.exs`

**Add to existing describe blocks**:
```elixir
describe "reconnection with grace period" do
  test "player can reconnect within grace period", %{
    user1: user,
    room_code: room_code,
    sockets: sockets
  } do
    socket = sockets[user.id]

    # Join game
    {:ok, _reply, socket} = subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

    # Disconnect by leaving the channel
    Process.unlink(socket.channel_pid)
    close(socket)

    # Mark as disconnected
    :ok = RoomManager.handle_player_disconnect(room_code, user.id)

    # Verify player is in disconnected list
    {:ok, room} = RoomManager.get_room(room_code)
    assert Map.has_key?(room.disconnected_players, user.id)

    # Reconnect within grace period
    {:ok, new_socket} = create_socket(user)
    {:ok, reply, _new_socket} = subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

    # Should indicate reconnection
    assert reply.reconnected == true

    # Should broadcast player_reconnected
    assert_broadcast "player_reconnected", %{user_id: user_id}, 1000
    assert user_id == user.id

    # Player should be removed from disconnected list
    {:ok, updated_room} = RoomManager.get_room(room_code)
    refute Map.has_key?(updated_room.disconnected_players, user.id)
  end

  @tag timeout: 130_000
  test "player is removed after grace period expires", %{
    user1: user,
    room_code: room_code
  } do
    # Mark player as disconnected
    :ok = RoomManager.handle_player_disconnect(room_code, user.id)

    # Wait for grace period to expire (120 seconds + buffer)
    Process.sleep(121_000)

    # Use retry pattern for async GenServer processing
    result =
      Enum.reduce_while(1..10, nil, fn _, _acc ->
        {:ok, room} = RoomManager.get_room(room_code)

        if user.id in room.player_ids do
          Process.sleep(100)
          {:cont, nil}
        else
          {:halt, {:ok, room}}
        end
      end)

    # Player should be removed from room
    assert {:ok, final_room} = result
    refute user.id in final_room.player_ids
  end
end
```

#### Test 4.3: RoomManager Cleanup Test

**File**: `test/pidro_server/games/room_manager_test.exs`

**Add new describe block**:
```elixir
describe "periodic cleanup of abandoned rooms" do
  test "removes rooms with no activity and no presence" do
    # Create a room
    {:ok, room} = RoomManager.create_room("player1", %{name: "Abandoned"})
    room_code = room.code

    # Manually set last_activity to old timestamp
    # (In real implementation, you'd need a test helper for this)
    # For now, we can trigger cleanup manually

    # Verify room exists
    assert {:ok, _room} = RoomManager.get_room(room_code)

    # Simulate time passing and cleanup
    # In practice, wait for cleanup cycle or trigger it
    send(RoomManager, :cleanup_abandoned_rooms)

    # Give it time to process
    Process.sleep(100)

    # Note: This test needs the room to actually be old
    # A better approach is to add a test-only function to set last_activity
  end
end
```

**Note**: For proper testing of time-based cleanup, consider adding a test helper function to RoomManager:

```elixir
# Only compile in test environment
if Mix.env() == :test do
  @spec set_last_activity_for_test(String.t(), DateTime.t()) :: :ok
  def set_last_activity_for_test(room_code, datetime) do
    GenServer.call(__MODULE__, {:set_last_activity_for_test, room_code, datetime})
  end

  @impl true
  def handle_call({:set_last_activity_for_test, room_code, datetime}, _from, state) do
    case Map.get(state.rooms, room_code) do
      nil -> {:reply, {:error, :not_found}, state}
      room ->
        updated_room = %{room | last_activity: datetime}
        updated_state = put_in(state.rooms[room_code], updated_room)
        {:reply, :ok, updated_state}
    end
  end
end
```

## Architecture Documentation

### Data Flow: Player Join with Presence

```
Client connects to WebSocket
    ↓
UserSocket.connect/3 verifies JWT token
    ↓
Socket assigns: user_id, session_id, connected_at
    ↓
Client joins "lobby" channel
    ↓
LobbyChannel.join/3
    ↓
Subscribe to "lobby:updates" PubSub
    ↓
Return current room list
    ↓
Send :after_join message to self
    ↓
LobbyChannel.handle_info(:after_join)
    ↓
Presence.track(socket, user_id, metadata)
    ↓
Push "presence_state" to client
    ↓
Presence.list() returns all online users
```

### Data Flow: Player Disconnect with Grace Period

```
Client connection drops
    ↓
GameChannel.terminate/2 called
    ↓
RoomManager.handle_player_disconnect(room_code, user_id)
    ↓
Add to room.disconnected_players with timestamp
    ↓
Process.send_after(self(), {:check_disconnect_timeout, ...}, 120_000)
    ↓
Broadcast "player_disconnected" with grace_period: true
    ↓
[2 minutes pass]
    ↓
RoomManager.handle_info({:check_disconnect_timeout, ...})
    ↓
Check if player still disconnected
    ↓
Check if grace period expired (DateTime.diff >= 120)
    ↓
If expired:
    Remove from room.player_ids
    Remove from room.disconnected_players
    Update player_rooms map
    Broadcast "room_update"
    Broadcast "lobby_update"
```

### Data Flow: Player Reconnection

```
Client reconnects and joins "game:#{room_code}"
    ↓
GameChannel.join/3
    ↓
RoomManager.get_room(room_code)
    ↓
Check if user_id in room.disconnected_players
    ↓
If yes:
    RoomManager.handle_player_reconnect(room_code, user_id)
    ↓
    Validate grace period not expired
    ↓
    Remove from room.disconnected_players
    ↓
    Broadcast "player_reconnected" to other players
    ↓
    Proceed with normal join
    ↓
    Presence.track(socket, user_id, metadata)
    ↓
    Return {state, reconnected: true}
```

## Code References

### Key Files for Implementation

- `lib/pidro_server/games/room_manager.ex:407-453` - Disconnect/reconnect functions already exist
- `lib/pidro_server_web/channels/lobby_channel.ex:57-95` - Needs presence tracking
- `lib/pidro_server_web/channels/game_channel.ex:75-390` - Needs enhanced reconnection and presence
- `lib/pidro_server_web/presence.ex:30-32` - Already configured
- `lib/pidro_server_web/channels/user_socket.ex:45-65` - Authentication working
- `lib/pidro_server/games/room_manager.ex:52-96` - Room struct (add last_activity)
- `lib/pidro_server/games/room_manager.ex:462-464` - init/1 (add cleanup task)

### Testing Files

- `test/pidro_server_web/channels/lobby_channel_test.exs` - Add presence tests
- `test/pidro_server_web/channels/game_channel_test.exs` - Add reconnection tests
- `test/pidro_server/games/room_manager_test.exs` - Add cleanup tests
- `test/support/channel_case.ex:52-79` - Socket creation helper already exists

## Idiomatic Elixir Patterns Observed

### 1. Small, Focused Functions

The codebase consistently uses private helper functions for complex operations:
- `broadcast_lobby/1` at `room_manager.ex:965`
- `broadcast_room/2` at `room_manager.ex:980`
- `format_error/1` at `game_channel.ex:458`
- `determine_user_role/2` at `game_channel.ex:428`

**Implementation Guideline**: Continue this pattern. Break complex logic into named private functions.

### 2. Pattern Matching

Heavy use of pattern matching in function heads:
- Multiple `handle_call/3` clauses for different messages
- Multiple `handle_info/2` clauses for different events
- Pattern matching in case statements

**Implementation Guideline**: Use pattern matching in function definitions rather than if/else trees.

### 3. Immutable State Updates

All state updates use pattern matching and struct updates:
```elixir
updated_room = %{room |
  disconnected_players: Map.put(room.disconnected_players, user_id, DateTime.utc_now()),
  last_activity: DateTime.utc_now()
}
```

**Implementation Guideline**: Never mutate state. Always create new structs with updates.

### 4. With Statements for Happy Path

Used throughout for validation chains:
```elixir
with {:ok, room} <- RoomManager.get_room(room_code),
     {:ok, pid} <- GameAdapter.get_game(room_code),
     true <- user_authorized?(user_id, room, :player) do
  # happy path
else
  # error handling
end
```

**Implementation Guideline**: Use `with` for sequential validations.

### 5. Process.send_after for Scheduled Work

Existing pattern at `room_manager.ex:829`:
```elixir
Process.send_after(self(), {:check_disconnect_timeout, room_code, user_id}, 120_000)
```

**Implementation Guideline**: Use Process.send_after for timeouts, handle in handle_info/2.

### 6. Tagged Tuple Returns

Consistent use of `{:ok, result}` and `{:error, reason}`:
```elixir
{:ok, room} = RoomManager.create_room(user_id, metadata)
{:error, :room_not_found} = RoomManager.get_room("INVALID")
```

**Implementation Guideline**: Always use tagged tuples for function returns that can fail.

## Comparison with Spec

### What Matches the Spec Exactly

✅ **Phoenix.Presence**: Already configured and supervised
✅ **2-minute grace period**: Already implemented (120 seconds)
✅ **disconnected_players tracking**: Already in Room struct
✅ **Process.send_after pattern**: Already used for grace period
✅ **PubSub broadcasting**: Already used throughout
✅ **Socket authentication**: JWT-based, working
✅ **Channel separation**: LobbyChannel and GameChannel exist

### What Needs Adjustment from Spec

❌ **Spec suggests**: Completely new implementations
✅ **Reality**: Enhance existing implementations

❌ **Spec suggests**: Create new functions
✅ **Reality**: Functions already exist, just need integration

❌ **Spec suggests**: Complex broadcast setup
✅ **Reality**: Broadcasting already works, just add presence

### Implementation Effort Estimate

**Spec estimate**: 17-25 hours total

**Actual estimate based on codebase**:
- **Phase 1** (RoomManager enhancements): 2-3 hours
  - Add last_activity field: 30 min
  - Update operations: 1 hour
  - Add cleanup task: 1-1.5 hours
- **Phase 2** (LobbyChannel presence): 1-2 hours
  - Very simple additions to existing channel
- **Phase 3** (GameChannel presence): 3-4 hours
  - Most complex, requires careful integration
  - Reconnection logic mostly exists
- **Phase 4** (Testing): 3-4 hours
  - Follow existing patterns
  - Most test infrastructure exists

**Total: 9-13 hours** (vs spec's 17-25 hours)

**Why Less Time**:
- RoomManager disconnect/reconnect already implemented
- Presence module already configured
- Channel structure already exists
- PubSub broadcasting already working
- Test infrastructure already comprehensive
- Authentication already handled

## Dave Thomas Would Be Proud Because

1. **Leverage OTP primitives**: Uses Phoenix.Presence (CRDT-based), GenServer, supervisors properly
2. **Let it crash**: Processes supervised, automatic cleanup on termination
3. **Immutable state**: All updates via pattern matching, no mutations
4. **Small focused functions**: Private helpers for complex logic
5. **Pattern matching**: Function heads, case statements, with statements
6. **Supervised processes**: Proper supervision tree, fault isolation
7. **No clever hacks**: Straightforward idiomatic Elixir throughout

## Next Steps

1. **Start with Phase 1**: Enhance RoomManager with last_activity and cleanup
2. **Then Phase 2**: Add presence to LobbyChannel (simplest)
3. **Then Phase 3**: Integrate presence in GameChannel with existing disconnect logic
4. **Finally Phase 4**: Add comprehensive tests following existing patterns

Each phase can be implemented and tested independently, allowing for incremental rollout.

## Questions to Consider

1. **Mobile Client**: Do we need to persist `last_game_code` for reconnection routing? The spec suggests AsyncStorage, but server-side tracking might be simpler.

2. **Spectator Disconnection**: Currently spectators don't get grace period. Should they? Probably not - spec doesn't mention it.

3. **Room Closure Timing**: Spec suggests 5-minute wait for abandoned rooms. Is this the right value for Pidro? Could make configurable.

4. **Presence Metadata**: What additional metadata would be useful? Current position, ready status, etc.?

5. **Testing Strategy**: Should we add property-based tests for edge cases like simultaneous disconnects/reconnects?

---

**End of Research Document**

This implementation guide provides a concrete path forward that respects the existing codebase architecture while achieving the goals of the presence specification. The key insight is that much of the hard work is already done - we just need to connect the pieces with Phoenix.Presence.