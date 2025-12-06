---
date: 2025-12-06T14:25:29+0000
researcher: Assistant
git_commit: 0f96ff47bfea61b9ad81115b7d0f057853e3ba0c
branch: main
repository: marcelfahle/pidro-backend
topic: "Player Seat Selection When Joining Rooms (GitHub Issue #3)"
tags: [research, codebase, room-manager, game-channel, position-assignment, seat-selection]
status: complete
last_updated: 2025-12-06
last_updated_by: Assistant
github_issue: https://github.com/marcelfahle/pidro-backend/issues/3
---

# Research: Player Seat Selection When Joining Rooms (GitHub Issue #3)

**Date**: 2025-12-06T14:25:29+0000
**Researcher**: Assistant
**Git Commit**: 0f96ff47bfea61b9ad81115b7d0f057853e3ba0c
**Branch**: main
**Repository**: marcelfahle/pidro-backend
**GitHub Issue**: https://github.com/marcelfahle/pidro-backend/issues/3

## Research Question

How does the current seat/position assignment system work when players join a room? What is the complete flow from HTTP join request to WebSocket channel join, and where/how are positions calculated?

This research documents the existing implementation to support the feature request in GitHub issue #3, which proposes allowing players to choose their seat (North/South/East/West) when joining a room instead of automatic assignment based on join order.

## Summary

The current Pidro backend implements **automatic sequential position assignment** based on join order. When players join a room via the HTTP API endpoint `POST /api/v1/rooms/{code}/join`, they are appended to a `player_ids` list maintained in the `RoomManager` GenServer. Later, when joining the WebSocket `GameChannel`, their position (`:north`, `:east`, `:south`, or `:west`) is calculated purely from their index in this list:

- **1st player (index 0)** → `:north` (always the room creator/host)
- **2nd player (index 1)** → `:east`
- **3rd player (index 2)** → `:south`
- **4th player (index 3)** → `:west`

**No position data is stored persistently** - positions are recalculated on-demand from the `player_ids` list order. This makes position assignment deterministic and stable across reconnections, but immutable once a player joins.

## Detailed Findings

### Component 1: HTTP Join Endpoint - RoomController

**Location**: `lib/pidro_server_web/controllers/api/room_controller.ex:566-574`

The join endpoint accepts a room code and adds the authenticated user to the room:

```elixir
def join(conn, %{"code" => code}) do
  user = conn.assigns[:current_user]

  with {:ok, room} <- RoomManager.join_room(code, user.id) do
    conn
    |> put_view(RoomJSON)
    |> render(:show, %{room: room})
  end
end
```

**Current Request Format**:
```bash
POST /api/v1/rooms/{code}/join
Authorization: Bearer <token>
# No request body required
```

**Current Response** (`lib/pidro_server_web/controllers/api/room_json.ex:83-94`):
```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "host_id": "user123",
      "player_ids": ["user123", "user456"],
      "spectator_ids": [],
      "status": "waiting",
      "max_players": 4,
      "max_spectators": 10,
      "created_at": "2024-11-02T10:30:00Z"
    }
  }
}
```

**Key Observation**: The HTTP response includes the `player_ids` list but does **not** include position information. Position is only calculated and revealed when joining the WebSocket game channel.

---

### Component 2: RoomManager - Player List Management

**Location**: `lib/pidro_server/games/room_manager.ex`

#### Room Struct Definition (lines 52-97)

The `Room` struct stores players as an ordered list:

```elixir
defstruct [
  :code,
  :host_id,
  :player_ids,        # ← Ordered list of user IDs
  :status,
  :max_players,
  :created_at,
  :metadata,
  :last_activity,
  spectator_ids: [],
  max_spectators: 10,
  disconnected_players: %{}
]
```

**Critical Field**: `player_ids` is a list (not a map), maintaining insertion order.

#### Join Logic (lines 512-575)

When `join_room/2` is called:

1. **Validation** (lines 514-533):
   - Checks room exists
   - Prevents duplicate joins (`:already_in_room` or `:already_in_this_room`)
   - Checks room status is `:waiting` or `:ready`
   - Checks room is not full (max 4 players)

2. **Player Addition** (lines 536-540):
```elixir
updated_player_ids = room.player_ids ++ [player_id]
player_count = length(updated_player_ids)

# Auto-start game when 4th player joins
new_status = if player_count == @max_players, do: :ready, else: :waiting
```

**Key Line 536**: `room.player_ids ++ [player_id]` - The append operation (`++`) determines player order, which later determines position.

3. **State Update** (lines 550-555):
```elixir
new_state = %State{
  state
  | rooms: Map.put(state.rooms, room_code, updated_room),
    player_rooms: Map.put(state.player_rooms, player_id, room_code)
}
```

The `player_rooms` map prevents a player from joining multiple rooms simultaneously.

4. **Game Start** (lines 566-570):
   - If status becomes `:ready` (4th player joined), calls `start_game_for_room/2`
   - Game process is started via `GameSupervisor.start_game/1`

---

### Component 3: GameChannel - Position Calculation

**Location**: `lib/pidro_server_web/channels/game_channel.ex`

#### Join Flow (lines 75-169)

When a player joins the WebSocket channel `"game:#{room_code}"`:

1. **Role Determination** (lines 81, 442-455):
```elixir
role = determine_user_role(room, user_id)

defp determine_user_role(room, user_id) do
  user_id_str = to_string(user_id)
  
  cond do
    Enum.any?(room.player_ids, fn id -> to_string(id) == user_id_str end) ->
      :player
    
    Enum.any?(room.spectator_ids, fn id -> to_string(id) == user_id_str end) ->
      :spectator
    
    true ->
      :unauthorized
  end
end
```

Checks if user_id exists in `room.player_ids` (player) or `room.spectator_ids` (spectator).

2. **Position Calculation** (line 132):
```elixir
position = if role == :player, do: get_player_position(room, user_id), else: nil
```

Only players receive positions; spectators get `nil`.

3. **Socket Assignment** (lines 135-140):
```elixir
socket
  |> assign(:room_code, room_code)
  |> assign(:position, position)  # ← Stored in socket state
  |> assign(:role, role)
  |> assign(:join_type, join_type)
```

The position is stored in the socket's assigns and used for all subsequent game actions.

4. **Join Reply** (lines 145-154):
```elixir
reply_data = %{
  state: state,
  role: role,
  reconnected: join_type == :reconnect
}

# Add position only for players
reply_data = if position, do: Map.put(reply_data, :position, position), else: reply_data

{:ok, reply_data, socket}
```

The client receives their position in the join response.

#### Core Algorithm: get_player_position/2 (lines 457-468)

This is the **heart of position assignment**:

```elixir
@spec get_player_position(RoomManager.Room.t(), String.t()) :: atom()
defp get_player_position(room, user_id) do
  # Positions are assigned in order: north, east, south, west
  positions = [:north, :east, :south, :west]
  user_id_str = to_string(user_id)
  
  # Find the index of the user in the player list
  index =
    Enum.find_index(room.player_ids, fn id -> to_string(id) == user_id_str end) || 0
  
  Enum.at(positions, index, :north)
end
```

**Algorithm Steps**:
1. Define hardcoded position order: `[:north, :east, :south, :west]`
2. Convert user_id to string for comparison
3. Find user's index in `room.player_ids` using `Enum.find_index/2`
4. Default to index 0 if not found (using `|| 0`)
5. Map index to position using `Enum.at/3`, defaulting to `:north`

**Position Mapping**:
- Index 0 → `:north` (first player/host)
- Index 1 → `:east` (second player)
- Index 2 → `:south` (third player)
- Index 3 → `:west` (fourth player)

---

### Component 4: Position Usage in Game Actions

**Location**: `lib/pidro_server_web/channels/game_channel.ex:408-418`

When players send game actions (bid, play card, etc.):

```elixir
defp apply_game_action(socket, action) do
  room_code = socket.assigns.room_code
  position = socket.assigns.position  # ← Retrieved from socket
  
  case GameAdapter.apply_action(room_code, position, action) do
    {:ok, _new_state} ->
      {:reply, :ok, socket}
    
    {:error, reason} ->
      {:reply, {:error, %{reason: format_error(reason)}}, socket}
  end
end
```

The position is read from `socket.assigns.position` and passed to the game engine via `GameAdapter.apply_action/3`.

---

### Component 5: Reconnection and Position Persistence

**Location**: `lib/pidro_server_web/channels/game_channel.ex:86-99`

When a player reconnects:

```elixir
if Map.has_key?(room.disconnected_players || %{}, user_id) do
  # Attempt reconnection
  case RoomManager.handle_player_reconnect(room_code, user_id) do
    {:ok, updated_room} ->
      Logger.info("Player #{user_id} reconnected to room #{room_code}")
      
      # Broadcast reconnection to other players
      position = get_player_position(updated_room, user_id)
      
      # Schedule broadcast after join is complete
      send(self(), {:broadcast_reconnection, user_id, position})
      
      # Continue with normal join flow
      proceed_with_join(room_code, user_id, socket, :reconnect, :player)
```

**Key Observation**: Position is **recalculated** from the updated room's `player_ids` list. Since the player remains in the list during reconnection grace period, they retain the same index and thus the same position.

**Disconnection Grace Period** (`lib/pidro_server/games/room_manager.ex`):
- When a player disconnects, they're added to `disconnected_players` map with timestamp
- Grace period is 120 seconds (configurable)
- Player stays in `player_ids` during grace period
- After grace period expires, player is removed from `player_ids` entirely

---

### Component 6: Team Assignment Based on Position

Positions directly determine team membership for scoring:

**Teams**:
- **North-South team**: Players at `:north` and `:south` positions
- **East-West team**: Players at `:east` and `:west` positions

**Example from Stats** (`lib/pidro_server/stats/stats.ex:172-182`):

```elixir
defp get_player_position(game, user_id) do
  player_ids = game.player_ids || []
  index = Enum.find_index(player_ids, &(&1 == user_id))
  
  case index do
    0 -> :north
    1 -> :east
    2 -> :south
    3 -> :west
    _ -> nil
  end
end
```

Used in win calculation:

```elixir
case {winner, player_position} do
  {:north_south, pos} when pos in [:north, :south] -> true
  {:east_west, pos} when pos in [:east, :west] -> true
  _ -> false
end
```

---

## Code References

### Core Position Assignment
- `lib/pidro_server_web/channels/game_channel.ex:457-468` - `get_player_position/2` function
- `lib/pidro_server_web/channels/game_channel.ex:132` - Position calculation on join
- `lib/pidro_server/games/room_manager.ex:536` - Player appended to `player_ids` list

### Join Flow
- `lib/pidro_server_web/controllers/api/room_controller.ex:566-574` - HTTP join endpoint
- `lib/pidro_server/games/room_manager.ex:512-575` - RoomManager join logic
- `lib/pidro_server_web/channels/game_channel.ex:75-169` - GameChannel join

### Position Storage
- `lib/pidro_server/games/room_manager.ex:88` - `player_ids` field in Room struct
- `lib/pidro_server_web/channels/game_channel.ex:138` - Position in socket assigns

### Position Usage
- `lib/pidro_server_web/channels/game_channel.ex:410-412` - Position in game actions
- `lib/pidro_server_web/channels/game_channel.ex:303` - Position in Presence tracking
- `lib/pidro_server_web/channels/game_channel.ex:380` - Position in disconnect events
- `lib/pidro_server/stats/stats.ex:172-182` - Position in win calculation

### Tests
- `test/pidro_server_web/channels/game_channel_test.exs:102-129` - Position assignment tests
- `test/pidro_server_web/channels/game_channel_test.exs:423-437` - Reconnection position tests
- `test/pidro_server/games/room_manager_test.exs:44-92` - Room join tests

---

## Architecture Documentation

### Current Design Patterns

#### 1. Position as Derived Value
Positions are **never stored persistently**. They are pure functions of the `player_ids` list order:

```
Position = f(player_ids, user_id) = positions[index_of(user_id, player_ids)]
```

**Benefits**:
- No synchronization issues between storage locations
- Deterministic across server restarts
- Simple to reason about

**Limitations**:
- Position cannot be changed after joining
- No way to swap positions
- No pre-selection before joining

#### 2. Sequential Join Order
Players must join in sequence (1st, 2nd, 3rd, 4th), and their join order is permanent.

**Flow**:
```
HTTP Join → RoomManager → Append to player_ids
    ↓
WebSocket Join → GameChannel → Calculate position from index
    ↓
Game Actions → Use socket.assigns.position
```

#### 3. Validation Points

**Room Join Validation** (RoomManager):
- Room exists
- Not already in a room
- Room status is `:waiting` or `:ready`
- Room not full (< 4 players)

**Channel Join Validation** (GameChannel):
- Room exists
- User is in `player_ids` or `spectator_ids`
- Game process is running

#### 4. State Management Layers

1. **Persistent State** (RoomManager GenServer):
   - `rooms` map: `%{room_code => Room}`
   - `player_rooms` map: `%{player_id => room_code}`
   - Room struct contains `player_ids` list

2. **Ephemeral State** (GameChannel socket):
   - `socket.assigns.position` - exists only during WebSocket session
   - Lost on disconnect, recalculated on reconnect

3. **No Database Storage**:
   - Rooms exist only in memory
   - Position calculated on-demand
   - Stats saved to database only after game completion

---

## Position Assignment Test Coverage

### Test File: `test/pidro_server_web/channels/game_channel_test.exs`

#### Verified Behaviors:

1. **Position Uniqueness** (lines 110-128):
```elixir
test "returns different positions for different players" do
  positions = Enum.map(users, fn user ->
    {:ok, reply, _socket} = 
      subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})
    reply.position
  end)
  
  # All positions should be unique
  assert length(Enum.uniq(positions)) == 4
  # Should be the standard 4 positions
  assert Enum.sort(positions) == [:east, :north, :south, :west]
end
```

2. **Position in Join Reply** (lines 105-107):
```elixir
{:ok, reply, _socket} = subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

assert %{state: state, position: position} = reply
assert position in [:north, :east, :south, :west]
```

3. **Position Persistence on Reconnect** (lines 423-437):
```elixir
test "reconnection returns correct state with reconnected flag" do
  # Initial join
  {:ok, initial_reply, joined_socket} = 
    subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})
  
  initial_position = initial_reply.position
  assert initial_reply.reconnected == false
  
  # Disconnect and reconnect
  leave(joined_socket)
  
  {:ok, reconnect_reply, _reconnected_socket} = 
    subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})
  
  # Should have same position
  assert reconnect_reply.reconnected == true
  assert reconnect_reply.position == initial_position
end
```

### Test File: `test/pidro_server/games/room_manager_test.exs`

#### Verified Behaviors:

1. **Sequential Join** (lines 56-67):
```elixir
test "allows player to join existing room" do
  {:ok, joined_room} = RoomManager.join_room(room.code, "player2")
  
  assert length(joined_room.player_ids) == 2
  assert "player2" in joined_room.player_ids
  assert joined_room.status == :waiting
end
```

2. **Auto-Start on 4th Player** (lines 79-92):
```elixir
test "changes status to ready when 4th player joins" do
  # Join players 2, 3, 4
  RoomManager.join_room(room.code, "player2")
  RoomManager.join_room(room.code, "player3")
  {:ok, full_room} = RoomManager.join_room(room.code, "player4")
  
  assert length(full_room.player_ids) == 4
  assert full_room.status == :ready
end
```

---

## Data Flow Diagram

### Complete Flow: From HTTP Join to Game Action

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. HTTP Join Request                                            │
│    POST /api/v1/rooms/A1B2/join                                 │
│    Authorization: Bearer <token>                                │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. RoomController.join/2                                        │
│    - Extracts user from conn.assigns[:current_user]             │
│    - Calls RoomManager.join_room(code, user.id)                 │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. RoomManager.join_room/2 (GenServer call)                     │
│    - Validates: room exists, not in another room, not full      │
│    - Appends to player_ids: room.player_ids ++ [user.id]        │
│    - Updates State.rooms and State.player_rooms maps            │
│    - Auto-starts game if 4th player joined (status → :ready)    │
│    - Returns: {:ok, updated_room}                               │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. HTTP Response                                                │
│    {                                                            │
│      "data": {                                                  │
│        "room": {                                                │
│          "player_ids": ["user1", "user2"],  ← Order matters!   │
│          "status": "waiting",                                   │
│          ...                                                    │
│        }                                                        │
│      }                                                          │
│    }                                                            │
└─────────────────────────────────────────────────────────────────┘

                     │ Client connects WebSocket
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. GameChannel.join("game:A1B2", %{}, socket)                   │
│    - Fetches room from RoomManager                              │
│    - Calls determine_user_role(room, user_id)                   │
│      → Checks if user_id in room.player_ids → returns :player   │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Position Calculation (get_player_position/2)                 │
│    positions = [:north, :east, :south, :west]                   │
│    index = Enum.find_index(room.player_ids, user_id)            │
│    position = Enum.at(positions, index)                         │
│                                                                 │
│    Example: player_ids = ["user1", "user2"]                     │
│             "user2" → index 1 → :east                           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. Socket Assignment                                            │
│    socket                                                       │
│      |> assign(:room_code, "A1B2")                              │
│      |> assign(:position, :east)  ← Stored in socket state      │
│      |> assign(:role, :player)                                  │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 8. Join Reply to Client                                         │
│    {                                                            │
│      "state": { ... game state ... },                           │
│      "position": "east",  ← First time position is revealed     │
│      "role": "player"                                           │
│    }                                                            │
└─────────────────────────────────────────────────────────────────┘

                     │ Client sends game action
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│ 9. Game Action (e.g., "play_card")                              │
│    handle_in("play_card", %{"card" => card}, socket)            │
│      → apply_game_action(socket, {:play_card, card})            │
│      → position = socket.assigns.position  ← Retrieved          │
│      → GameAdapter.apply_action(room_code, position, action)    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Summary of Current Position Assignment System

### Characteristics

| Aspect | Current Behavior |
|--------|------------------|
| **Assignment Method** | Automatic based on join order |
| **Position Sequence** | 1st → `:north`, 2nd → `:east`, 3rd → `:south`, 4th → `:west` |
| **Storage** | Not stored - calculated from `player_ids` list index |
| **Mutability** | Immutable - cannot change position after joining |
| **Persistence** | Position persists across reconnections (via list order) |
| **Team Assignment** | North/South vs East/West based on position |
| **API Exposure** | Position revealed only in WebSocket join reply |
| **Validation** | No validation - deterministically assigned |

### Key Design Decisions

1. **No Position Parameter**: The HTTP join endpoint accepts no position/seat parameter
2. **Pure Function**: Position = `f(player_ids, user_id)` - purely derived value
3. **No Pre-Selection**: Players cannot see or choose positions before joining
4. **Team Determined by Position**: Position directly maps to team (N/S or E/W)
5. **First Player is North**: Room creator always gets `:north` position

### Constraints

1. **Sequential Join Required**: Players must join 1-by-1 in sequence
2. **No Position Swapping**: Once assigned, positions cannot be changed
3. **No Seat Selection**: Players cannot choose their preferred position
4. **No Team Selection**: Players cannot choose their team (determined by position)
5. **Friends Coordination Requires Timing**: Friends wanting same team must coordinate join order

### Files Modified by Position Changes

Based on the current implementation, implementing seat selection would need to modify:

1. **API Layer**:
   - `lib/pidro_server_web/controllers/api/room_controller.ex` - Accept position parameter
   - `lib/pidro_server_web/schemas/room_schemas.ex` - Add position to join request schema

2. **Business Logic**:
   - `lib/pidro_server/games/room_manager.ex` - Store position choices, validate availability
   - Room struct would need to track position assignments

3. **Channel Layer**:
   - `lib/pidro_server_web/channels/game_channel.ex` - Read stored position instead of calculating

4. **Tests**:
   - `test/pidro_server_web/controllers/api/room_controller_test.exs` - Test position selection
   - `test/pidro_server/games/room_manager_test.exs` - Test position availability
   - `test/pidro_server_web/channels/game_channel_test.exs` - Update position tests

---

## Related Research

- `thoughts/shared/research/2025-12-06-GH-3-player-seat-selection.md` (this document)

## GitHub Issue Reference

**Issue**: [#3 - Feature: Allow players to join a specific seat when joining a room](https://github.com/marcelfahle/pidro-backend/issues/3)

**Proposed Changes** (from issue):
1. Add optional `position` or `team` parameter to join endpoint
2. Validate position availability before assignment
3. Return `SEAT_TAKEN` error if position is occupied
4. Maintain backward compatibility with current sequential assignment
5. Return assigned seat in join response

**Current Gap**: The existing system has no concept of position storage or seat availability checking - all positions are purely derived from list order.
