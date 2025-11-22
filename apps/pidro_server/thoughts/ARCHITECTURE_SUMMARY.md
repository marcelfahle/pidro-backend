# Pidro Game Server Architecture Summary

## High-Level Overview

```
                    Client (Browser)
                          |
                    WebSocket Connection
                          |
    +---------------------+---------------------+
    |                                             |
    |                                             |
    v                                             v
GameChannel                                  LobbyChannel
(game:XXXX)                                  (lobby)
    |                                             |
    +------ PubSub Subscription --------+        |
    |       "game:XXXX"                 |        |
    |                                   |        |
    v                                   v        v
GameAdapter                        RoomManager  (Notifies of room changes)
    |                                   |
    +----- Registry Lookup -----+      |
    |                            |     |
    v                            v     v
Pidro.Server         GameSupervisor
(Game Logic)         (Game Process)
```

---

## Core Components Explained

### 1. RoomManager GenServer
**File:** `lib/pidro_server/games/room_manager.ex`

**Purpose:** Centralized state management for all game rooms

**Key Responsibilities:**
- Manage room lifecycle (create → waiting → ready → playing → finished → closed)
- Track player-to-room mappings
- Handle player joins/leaves
- Auto-start games when 4 players join
- Manage player disconnections and grace periods
- Broadcast room updates via PubSub

**State Structure:**
```elixir
%State{
  rooms: %{
    "XXXX" => %Room{...},  # Key: room code, Value: Room struct
    ...
  },
  player_rooms: %{
    "user123" => "XXXX",   # Key: player ID, Value: room code (reverse mapping)
    ...
  }
}
```

**Critical:** Single GenServer manages ALL rooms - no horizontal scaling currently

---

### 2. GameChannel WebSocket Handler
**File:** `lib/pidro_server_web/channels/game_channel.ex`

**Purpose:** WebSocket channel for real-time game communication

**Channel Topic:** `"game:XXXX"` where XXXX is room code

**Join Process:**
1. Authenticate user (token in socket)
2. Verify user is player in room
3. Check game process exists
4. Subscribe to `"game:XXXX"` PubSub topic
5. Return initial game state

**Player Actions:** Players can send bids, plays, trump declarations
- Actions → GameAdapter.apply_action/3
- GameAdapter updates game state via Pidro.Server
- State broadcasted to all connected clients on same channel

**Disconnect Handling:**
- `terminate/2` callback removes player from room
- Triggers RoomManager grace period for reconnection
- Broadcasts disconnect event to other players

---

### 3. GameAdapter Bridge
**File:** `lib/pidro_server/games/game_adapter.ex`

**Purpose:** Interface between web layer and game logic layer

**Key Functions:**
- `apply_action/3` - Apply move, broadcast state update
- `get_state/1` - Fetch current game state
- `get_legal_actions/2` - Get valid moves for position
- `subscribe/1` - Subscribe to game updates via PubSub
- `get_game/1` - Get game process PID

**Important:** Uses GameRegistry to lookup game process PID

---

### 4. Presence Tracking
**File:** `lib/pidro_server_web/presence.ex`

**Purpose:** Track who's online in game channels

**Implementation:** Phoenix.Presence (CRDT-based, distributed)

**Metadata per Player:**
```elixir
%{
  user_id => %{
    online_at: unix_timestamp,
    position: :north | :east | :south | :west
  }
}
```

**Broadcasts:**
- `"presence_state"` - Full map on join
- `"presence_diff"` - Incremental changes

---

### 5. Game State Flow

**State Structure:**
```elixir
%{
  phase: :bidding | :trump | :playing | :game_over,
  hand_number: 1,
  current_turn: :north,
  current_dealer: :west,
  players: %{
    :north => %{position: :north, team: :north_south, hand: [cards], tricks_won: 2},
    :east => %{...},
    :south => %{...},
    :west => %{...}
  },
  bids: [%{position: :north, amount: 8}, ...],
  tricks: [list of completed tricks],
  cumulative_scores: %{north_south: 50, east_west: 42},
  bid_amount: 8,
  bid_team: :north_south,
  winner: :north_south,
  scores: %{north_south: 152, east_west: 148}
}
```

**Broadcasting:**
- When action applied, GameAdapter gets new state from Pidro.Server
- Broadcasts `{:state_update, state}` on PubSub "game:XXXX"
- All connected GameChannel clients receive and forward to WebSocket

**Important:** No filtering or view-specific state - all clients see full state

---

## Room Lifecycle State Machine

```
┌─────────────────────────────────────────────────────────┐
│ `:waiting`                                              │
│ - Host created room, waiting for players                │
│ - Players 2-3 can join                                  │
│ - Room visible in lobby                                 │
└─────┬─────────────────────────────────────────────────┘
      │ (4th player joins)
      v
┌─────────────────────────────────────────────────────────┐
│ `:ready`                                                │
│ - All 4 players joined                                  │
│ - Game supervisor starting game process                 │
│ - Room no longer accepting players                      │
└─────┬─────────────────────────────────────────────────┘
      │ (game process started)
      v
┌─────────────────────────────────────────────────────────┐
│ `:playing`                                              │
│ - Game actively running                                 │
│ - Players can bid, play cards, etc                      │
│ - Game state being updated                              │
└─────┬─────────────────────────────────────────────────┘
      │ (game ends, someone reaches winning score)
      v
┌─────────────────────────────────────────────────────────┐
│ `:finished`                                             │
│ - Game completed                                        │
│ - Winners determined                                    │
│ - Stats saved to database                               │
│ - Room will auto-close in 5 minutes                     │
└─────┬─────────────────────────────────────────────────┘
      │ (timer expires)
      v
┌─────────────────────────────────────────────────────────┐
│ `:closed`                                               │
│ - Room removed from system                              │
│ - Game process terminated                               │
│ - No longer visible to clients                          │
└─────────────────────────────────────────────────────────┘

Special Case: Host Leaves Anytime → `:closed` (immediate)
```

---

## PubSub Event Flows

### Flow 1: Player Joins Room (REST API)

```
Client                     RoomController         RoomManager          PubSub
  |                               |                    |                  |
  ├─ POST /rooms/XXXX/join ──────>│                    |                  |
  |                               ├─ join_room ──────>│                  |
  |                               |                    ├─ Add to room    |
  |                               |                    ├─ broadcast_room─>│
  |                               |                    ├─ broadcast_lobby>│
  |                               |<─ {:ok, room} ────|                  |
  |<─ 200 OK ────────────────────│                    |                  |
```

### Flow 2: Player Action During Game

```
Client              GameChannel          GameAdapter       Pidro.Server       PubSub
  |                     |                    |                  |               |
  ├─ push "bid" ───────>│                    |                  |               |
  |                     ├─ apply_action ────>│                  |               |
  |                     |                    ├─ apply_action───>│               |
  |                     |                    |                  ├─ new state   |
  |                     |                    |<─ {:ok, state}──│               |
  |                     |                    ├─ broadcast ─────────────────────>│
  |                     |                    |      {:state_update, state}      |
  |                     |<─ {:state_update, state} ────────────────────────────|
  |<─ push "game_state" │                    |                  |               |
  |    {state}          │                    |                  |               |
```

### Flow 3: Player Disconnects & Reconnects

```
Client                GameChannel       RoomManager          Timer
  |                        |                |                 |
  ├─ Disconnect ──────────>│                |                 |
  |                        ├─ leave_room──>│                 |
  |                        |                ├─ Mark disconnected
  |                        |                ├─ Start 2-min timer
  |                        |                |────────────────>│
  |                        |                |                 |
  │ (within 2 minutes)     |                |                 |
  │                        |                |                 |
  ├─ Reconnect/join ──────>│                |                 |
  |                        ├─ check disconnected
  |                        ├─ player_reconnect──>│            |
  |                        |                ├─ Remove from disc.
  |                        |                |<─ {:ok, room}  |
  |<─ 200 OK + state ─────|                |                 |
  |                        |                |<─ Timer cancel ─|
  |                        |                |
  │ (after 2 minutes w/o reconnect)        |
  │                        |                |
  │                        |                │<─ Timer expires
  │                        |                ├─ Remove player
  │                        |                ├─ Close room if empty
```

---

## Current Architecture Limitations

1. **Single GenServer for All Rooms**
   - Does not scale to 1000+ concurrent games
   - Solution: Shard RoomManager or use database

2. **No State Filtering per Player**
   - All clients see full game state
   - Solution: Implement view-specific state filtering

3. **No Player-Spectator Distinction**
   - Cannot have observers/spectators
   - Solution: Add spectator mode (THIS ANALYSIS)

4. **Limited Authorization**
   - Only checks "are you a player in this room"
   - No role-based access control

5. **All Rooms in Memory**
   - No persistence (except stats database)
   - Lost on server restart

---

## Key Design Patterns

### 1. GenServer for State Management
- RoomManager uses GenServer for concurrent access
- All room operations go through GenServer.call
- Ensures consistency but potential bottleneck

### 2. PubSub for Broadcasting
- Loose coupling between components
- Clients subscribe to topics, receive broadcasts
- Can have many subscribers to one topic

### 3. Phoenix Channels for WebSocket
- Bidirectional real-time communication
- Automatic reconnection handling
- Message queueing built-in

### 4. Registry for Process Lookup
- GameRegistry maps room_code → game process PID
- Fast lookup without distributed queries

### 5. Presence for Tracking
- Automatic cleanup on disconnect
- CRDT-based for consistency
- Minimal network overhead

---

## Summary Table: Architecture Components

| Component | Type | Scope | Responsibility |
|-----------|------|-------|-----------------|
| RoomManager | GenServer | Global | Room lifecycle, player tracking |
| GameChannel | Phoenix Channel | Per-game | WebSocket, player actions |
| GameAdapter | Module | Per-game | Bridge to game logic |
| Pidro.Server | External | Per-game | Game rules & state logic |
| Presence | Phoenix.Presence | Per-channel | Who's online tracking |
| GameRegistry | Registry | Global | Process PID mapping |
| GameSupervisor | DynamicSupervisor | Global | Game process lifecycle |

---

## Appendix: Code Paths

### Creating a Room
```
POST /api/v1/rooms
  → RoomController.create/2
    → RoomManager.create_room/2
      → Broadcasts on "lobby:updates"
```

### Joining a Room
```
POST /api/v1/rooms/:code/join
  → RoomController.join/2
    → RoomManager.join_room/2
      → If 4 players reached:
        → GameSupervisor.start_game/1
          → Creates Pidro.Server process
          → Registers in GameRegistry
      → Broadcasts on "room:CODE" and "lobby:updates"
```

### Connecting to Game Channel
```
WebSocket: game:XXXX
  → GameChannel.join/3
    → Verify user is player
    → GameAdapter.subscribe/1
      → Subscribe to "game:XXXX" PubSub
    → GameAdapter.get_state/1
      → Fetch initial state
    → Presence.track/3
      → Track presence
```

### Making a Game Action
```
push "bid" from client
  → GameChannel.handle_in("bid", ...)
    → GameAdapter.apply_action/3
      → Pidro.Server.apply_action/2
      → broadcast_state_update/2
        → Broadcasts {:state_update, state} on "game:XXXX"
    → All subscribed clients receive update
      → GameChannel.handle_info({:state_update, ...})
        → broadcast/3 to WebSocket clients
```

---

## Conclusion

The Pidro server architecture is:
- **Well-organized** with clear separation of concerns
- **Scalable for MVP** (up to 10-100 concurrent games)
- **Real-time ready** with Phoenix channels and PubSub
- **Ready for enhancement** with spectator mode (as per analysis)

The addition of spectator mode is **architecturally sound** and requires minimal changes to this foundation.

