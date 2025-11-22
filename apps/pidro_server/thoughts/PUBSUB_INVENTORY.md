# PubSub Topics and Message Formats Inventory

## Overview
This document catalogs all Phoenix.PubSub topics and message formats used in the Pidro backend.

---

## PubSub Topics

### 1. `"lobby:updates"` - Lobby Updates (Server → Clients)
**Purpose:** Broadcast lobby room list updates  
**Subscribers:** `LobbyChannel`, `LobbyLive`, `StatsLive`  
**Publisher:** `RoomManager`

#### Messages:
```elixir
{:lobby_update, [%Room{}, ...]}
```

**Payload:** List of available rooms (status: `:waiting`, `:ready`, `:playing`)  
**Excludes:** Rooms with status `:finished` or `:closed`

**Broadcast Trigger:** After any room state change (create, join, leave, start, close)

**Room Fields:**
- `code` (string) - 4-char room code
- `host_id` (string) - Host user ID
- `player_ids` (list) - Current player IDs
- `spectator_ids` (list) - Current spectator IDs
- `status` (atom) - `:waiting`, `:ready`, `:playing`, `:finished`, `:closed`
- `max_players` (integer) - Max players allowed
- `created_at` (DateTime) - Room creation time
- `metadata` (map) - Additional room data

**Source:** [room_manager.ex:967](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/room_manager.ex#L967)

---

### 2. `"lobby"` - LiveView Lobby Topic
**Purpose:** Alternative lobby subscription for LiveViews  
**Subscribers:** `LobbyLive`, `StatsLive`  
**Publisher:** None directly (uses `"lobby:updates"` pattern)

**Note:** This appears to be a naming inconsistency. LiveViews subscribe to `"lobby"` but broadcasts go to `"lobby:updates"`.

---

### 3. `"game:#{room_code}"` - Game State Updates
**Purpose:** Broadcast game state changes for specific room  
**Subscribers:** `GameChannel`, `GameAdapter`, `GameMonitorLive`  
**Publisher:** `GameAdapter`

#### Messages:

**State Update:**
```elixir
{:state_update, %{
  phase: atom(),           # :bidding, :kitty_selection, :trump_selection, :playing, :game_over
  current_player: atom(),  # :north, :south, :east, :west
  dealer: atom(),
  trump_suit: atom() | nil,
  winning_bid: integer() | nil,
  scores: %{north_south: integer(), east_west: integer()},
  hands: %{},              # Player hands (position => cards)
  trick: [],               # Current trick cards
  bids: %{},               # Player bids
  # ... other game state fields
}}
```

**Game Over:**
```elixir
{:game_over, winner_atom, %{
  north_south: integer(),
  east_west: integer()
}}
```

**Source:**  
- State Update: [game_adapter.ex:262](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/game_adapter.ex#L262)
- Game Over: [game_adapter.ex:290](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/game_adapter.ex#L290)

---

### 4. `"room:#{room_code}"` - Room Updates
**Purpose:** Broadcast room metadata changes  
**Subscribers:** None currently  
**Publisher:** `RoomManager`

#### Messages:

**Room Update:**
```elixir
{:room_update, %Room{}}
```

**Room Closed:**
```elixir
{:room_closed}
```

**Source:** [room_manager.ex:981](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/room_manager.ex#L981)

**Note:** This topic is broadcast to but not currently subscribed by any component.

---

## Channel-Specific Events (WebSocket only)

These are sent via `broadcast/3` and `broadcast_from/3` within channels (not PubSub topics).

### GameChannel Events

| Event | Payload | Source Line | Direction |
|-------|---------|-------------|-----------|
| `"player_reconnected"` | `%{user_id: string, position: atom}` | [game_channel.ex:95](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L95) | Server → Clients (excluding sender) |
| `"player_ready"` | `%{position: atom}` | [game_channel.ex:238](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L238) | Server → All Clients |
| `"game_state"` | `%{state: map}` | [game_channel.ex:256](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L256) | Server → All Clients |
| `"game_over"` | `%{winner: atom, scores: map}` | [game_channel.ex:270](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L270) | Server → All Clients |
| `"player_disconnected"` | `%{user_id: string, position: atom, reason: string}` | [game_channel.ex:365](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L365) | Server → Clients (excluding sender) |
| `"spectator_left"` | `%{user_id: string, reason: string}` | [game_channel.ex:378](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex#L378) | Server → Clients (excluding sender) |

### LobbyChannel Events

| Event | Payload | Source | Direction |
|-------|---------|--------|-----------|
| `"lobby_update"` | `%{rooms: [serialized_rooms]}` | [lobby_channel.ex:81](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/channels/lobby_channel.ex#L81) | Server → All Clients |

---

## Issues and Conflicts

### 1. **Topic Naming Inconsistency**
- **Problem:** LiveViews subscribe to `"lobby"` but RoomManager broadcasts to `"lobby:updates"`
- **Impact:** LiveViews may not receive lobby updates
- **Location:** 
  - Subscribe: [lobby_live.ex:9](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server_web/live/lobby_live.ex#L9)
  - Broadcast: [room_manager.ex:969](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/room_manager.ex#L969)
- **Recommendation:** Standardize on `"lobby:updates"` everywhere

### 2. **Unused Topic**
- **Problem:** `"room:#{room_code}"` is broadcast but never subscribed
- **Impact:** Wasted resources, no consumers
- **Recommendation:** Either remove broadcasts or add subscribers for room-specific updates

### 3. **Dual Broadcast Mechanisms**
- **Problem:** Game state updates use both PubSub topics (`{:state_update, state}`) AND channel broadcasts (`"game_state"`)
- **Impact:** Potential message duplication, confusion
- **Recommendation:** Consolidate to single mechanism (prefer PubSub for cross-process communication)

---

## Dev UI PubSub Strategy

### Recommended Approach

**Option 1: Subscribe to Existing Topics (Recommended)**
```elixir
# In DevUI LiveView
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    # Subscribe to all active game rooms dynamically
  end
  
  {:ok, socket}
end

def handle_info({:lobby_update, rooms}, socket) do
  # Update dev UI with room list
  {:noreply, assign(socket, rooms: rooms)}
end

def handle_info({:state_update, state}, socket) do
  # Update dev UI with game state
  {:noreply, assign(socket, game_state: state)}
end
```

**Option 2: Create New Dev-Specific Topic**
```elixir
# New topic: "dev:monitor"
# Aggregate and format all events for dev UI
# Pros: Cleaner separation, custom formatting
# Cons: Additional broadcast overhead
```

### Recommended Topics for Dev UI

1. **Subscribe to:** `"lobby:updates"` for room list
2. **Subscribe to:** `"game:#{code}"` for each active game (dynamic)
3. **Optional new topic:** `"dev:events"` for aggregated system events (player joins, disconnects, errors)

### New Topics Needed

**`"dev:events"` - System Events for Dev UI**
```elixir
# Broadcast system-wide events for debugging
{:player_event, %{type: :join|:leave|:disconnect, user_id: string, room_code: string, timestamp: DateTime}}
{:error_event, %{component: string, error: string, context: map, timestamp: DateTime}}
{:metric_event, %{type: :player_count|:room_count|:game_duration, value: any, timestamp: DateTime}}
```

### Implementation Checklist

- [ ] Fix lobby topic naming inconsistency (`"lobby"` → `"lobby:updates"`)
- [ ] Remove unused `"room:#{room_code}"` broadcasts OR add subscribers
- [ ] Add `"dev:events"` topic for system-wide dev monitoring
- [ ] Update DevUI to subscribe to relevant topics
- [ ] Add PubSub message handlers in DevUI LiveView
- [ ] Consider rate limiting for dev UI updates (every 500ms max)
- [ ] Add topic unsubscribe on DevUI unmount

---

## Message Flow Diagram

```
RoomManager
  └─> "lobby:updates" → {:lobby_update, rooms}
        ├─> LobbyChannel (via "lobby:updates")
        ├─> LobbyLive (subscribes to "lobby" ❌ MISMATCH)
        └─> StatsLive (subscribes to "lobby" ❌ MISMATCH)

GameAdapter
  └─> "game:#{code}" → {:state_update, state} | {:game_over, winner, scores}
        ├─> GameChannel
        ├─> GameMonitorLive
        └─> GameAdapter (self-subscribe for sync)

GameChannel (WebSocket)
  └─> Channel-specific events (player_reconnected, game_state, etc.)
        └─> Connected WebSocket clients only
```
