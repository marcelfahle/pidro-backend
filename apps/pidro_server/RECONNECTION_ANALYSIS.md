# Pidro Server Reconnection Handling Analysis

## Executive Summary

The Pidro server currently has **NO NATIVE RECONNECTION SUPPORT**. Player disconnections are treated as permanent, triggering immediate cleanup and room/game state changes. This analysis identifies critical gaps and provides a detailed roadmap for implementing reconnection capabilities.

---

## 1. CURRENT PRESENCE TRACKING

### File: `lib/pidro_server_web/presence.ex`

**Current Implementation:**
- Uses Phoenix.Presence (CRDT-based, distributed presence tracking)
- Minimal wrapper around Phoenix.Presence with no custom logic
- Configured to use PidroServer.PubSub for pub/sub broadcasting
- Claims "Automatic cleanup when users disconnect" but doesn't implement custom cleanup logic

**Current Behavior:**
```elixir
use Phoenix.Presence,
  otp_app: :pidro_server,
  pubsub_server: PidroServer.PubSub
```

**Gaps Identified:**
- No callbacks defined for presence leave events
- No tracking of last_seen timestamps
- No persistent storage of presence data
- No idle/stale presence cleanup mechanism
- Phoenix.Presence handles automatic cleanup but only when connection fully terminates

---

## 2. GAMECHANNEL DISCONNECT HANDLING

### File: `lib/pidro_server_web/channels/game_channel.ex`

**Current Implementation:**
- **NO DISCONNECT HANDLER IMPLEMENTED**
- No `handle_call/3` callback for disconnect
- Channel processes are tied 1:1 to WebSocket connections

**Key Methods:**
- `join/3` (lines 71-108): Authenticates, tracks presence, subscribes to game updates
- `handle_info(:after_join)` (lines 195-206): Tracks presence after join
- `handle_info({:game_over})` (lines 171-187): Schedules room closure after 5 minutes
- `handle_info({:close_room})` (lines 189-193): Closes room

**Critical Discovery: Room Closure Logic**
```elixir
# When game ends, room is closed after 5 minutes (line 184)
Process.send_after(self(), {:close_room, room_code}, :timer.minutes(5))

# Then room is explicitly closed (line 191)
RoomManager.close_room(room_code)
```

**Gaps Identified:**
- ❌ No `terminate/2` callback defined
- ❌ No cleanup on WebSocket disconnect
- ❌ No distinction between temporary network issues and intentional leave
- ❌ No "player left" broadcast to other players
- ❌ No timeout mechanism for detecting disconnected players
- ❌ RoomManager is NOT notified of disconnects

**What Happens Now When Player Disconnects:**
1. WebSocket connection terminates
2. Phoenix.Presence automatically removes the user from presence
3. RoomManager still has the player in player_ids
4. Other players continue as if the player is still there
5. Game continues with disconnected player unable to act
6. Only when game ends (5 min later) does room close

---

## 3. ROOMMANAGER STATE TRACKING

### File: `lib/pidro_server/games/room_manager.ex`

**Room Structure:**
```elixir
defmodule Room do
  defstruct [
    :code,              # Unique 4-char room code
    :host_id,           # Creator's user ID
    :player_ids,        # List of participating players
    :status,            # :waiting, :ready, :playing, :finished, :closed
    :max_players,       # Always 4
    :created_at,        # DateTime
    :metadata           # Map (room name, etc.)
  ]
end
```

**Current Disconnect Handling:**
```elixir
# In leave_room/1 (lines 419-485):
# - If host leaves: close entire room
# - If regular player leaves: remove from player_ids, status -> :waiting
# - If room becomes empty: delete room
```

**Critical Issues:**

1. **No Disconnect vs Leave Distinction**
   - Both disconnects and explicit leaves trigger the same logic
   - No temporary state for reconnect attempts
   - Player immediately removed from player_ids

2. **No Player Reconnect Tracking**
   - No timestamp for when player disconnected
   - No "expected to return" flag
   - No reconnect attempt window

3. **No Presence Correlation**
   - RoomManager doesn't listen to Presence events
   - Presence removal and room cleanup are independent
   - Can get out of sync

4. **Status Transitions**
   - Playing -> Waiting (if non-host player leaves)
   - No intermediate "player_disconnected" state
   - Other players see instant player removal

**Gaps Identified:**
- ❌ No callback for GameChannel disconnects
- ❌ No player_status tracking (connected/disconnected/reconnecting)
- ❌ No last_seen timestamp per player
- ❌ No reconnect grace period
- ❌ No presence event subscription

---

## 4. GAMEADAPTER STATE INTERFACE

### File: `lib/pidro_server/games/game_adapter.ex`

**Current Implementation:**
- Simple pass-through to Pidro.Server game processes
- No connection state tracking
- No player availability checking

**Methods:**
- `apply_action/3`: Applies game moves, broadcasts state updates
- `get_state/1`: Returns current game state
- `subscribe/1`: PubSub subscription to game updates
- `get_game/1`: Looks up game process PID

**Issues:**
- ❌ No way to pause/resume game when player disconnects
- ❌ No way to check if position is still connected
- ❌ No player availability state in returned game state
- ❌ Assumes all positions are always active

---

## 5. GAMESUPERVISOR & GAMEREGISTRY

### File: `lib/pidro_server/games/game_supervisor.ex` and `game_registry.ex`

**Current Implementation:**
- DynamicSupervisor with `:one_for_one` strategy
- `:temporary` restart policy (games don't auto-restart if crashed)
- Simple PID lookup by room code

**Issues:**
- ❌ No monitoring of connected players
- ❌ If game crashes, all players lose connection
- ❌ No state persistence for crash recovery
- ❌ Game process termination not broadcast to channels

---

## 6. CHANNEL AUTHENTICATION (UserSocket)

### File: `lib/pidro_server_web/channels/user_socket.ex`

**Current Implementation:**
```elixir
def connect(%{"token" => token}, socket, _connect_info) do
  case PidroServer.Accounts.Token.verify(token) do
    {:ok, user_id} ->
      socket = assign(socket, :user_id, user_id)
      {:ok, socket}
    {:error, _reason} ->
      :error
  end
end
```

**Token Details:**
- JWT-based with 30-day expiry
- Verified via `Phoenix.Token.verify/4`
- Stored in socket.assigns.user_id

**Current Behavior:**
- ❌ No session state tracking
- ❌ No reconnect token generation
- ❌ Same token required for every connection
- ❌ No way to differentiate connection sessions
- ✅ 30-day expiry is good for extended play sessions

**For Reconnection, Need:**
- Session tokens (shorter expiry)
- Reconnect tokens (issued on disconnect)
- Connection ID tracking
- Session state validation

---

## 7. EXISTING TIMEOUT/CLEANUP LOGIC

### Room Closure (Already Implemented)
```elixir
# GameChannel, line 184
Process.send_after(self(), {:close_room, room_code}, :timer.minutes(5))
```
- Closes room 5 minutes after game ends
- Only happens AFTER game over

### Game Start Trigger
```elixir
# RoomManager, line 407-411
if new_status == :ready do
  start_game_for_room(updated_room, new_state)
end
```
- Auto-starts game when 4th player joins
- No idle room timeout while waiting

### No Other Cleanup
- ❌ No player idle timeout while playing
- ❌ No waiting room timeout (could accumulate)
- ❌ No stale game process cleanup
- ❌ No connection heartbeat

---

## 8. LOBBYCHANNEL DISCONNECT HANDLING

### File: `lib/pidro_server_web/channels/lobby_channel.ex`

**Current Implementation:**
- Subscribes to lobby:updates PubSub topic
- Tracks presence on join
- Broadcasts lobby_update events

**Issues:**
- ❌ No disconnect handler
- ❌ Presence removal doesn't update lobby
- ❌ No offline player indication
- Simpler than GameChannel but same problems

---

## CRITICAL GAPS SUMMARY

### Disconnection Flow (Current)
```
Player disconnects from WebSocket
         ↓
Phoenix.Presence removes user automatically
         ↓
[GAP] RoomManager never notified
         ↓
[GAP] GameChannel terminated but no handler
         ↓
[GAP] No "player left" message to others
         ↓
Game continues with ghost player
         ↓
After 5 min (game_over only): Room closes
```

### What's Missing

| Component | Current State | Needed |
|-----------|---------------|--------|
| **Disconnect Detection** | ❌ No callback | Channel `terminate/2` |
| **Connection State** | ❌ Binary (connected/gone) | Ternary (connected/disconnected/reconnecting) |
| **Presence Tracking** | ✅ Works | ✅ Works (needs integration) |
| **Reconnect Window** | ❌ None | 2-5 minute grace period |
| **Session Tracking** | ❌ None | Session ID + token system |
| **Player Availability** | ❌ Not tracked | Per-position availability in game state |
| **Pause on Disconnect** | ❌ No mechanism | AI plays disconnected hands |
| **Heartbeat** | ❌ None | Optional for early detection |
| **Cleanup Timeout** | ⚠️ Only after game | Need for idle waiting rooms |
| **Error Broadcast** | ❌ Silent | Notify players of disconnects |
| **Persistent State** | ❌ Memory only | For crash recovery |

---

## IMPLEMENTATION ROADMAP

### Phase 1: Disconnect Detection (Critical)
1. Add `terminate/2` to GameChannel
2. Add `terminate/2` to LobbyChannel
3. Notify RoomManager of disconnects
4. Broadcast "player_disconnected" to game channel

### Phase 2: Reconnection State Machine
1. Add player_status tracking to Room struct
2. Implement reconnect grace period (2-5 min)
3. Track last_seen timestamp
4. Generate session IDs and reconnect tokens

### Phase 3: Game State Management
1. Add player availability to game state
2. Implement AI play for disconnected players during playing phase
3. Auto-rejoin for reconnecting players
4. Handle mid-game rejoins

### Phase 4: Cleanup & Timeouts
1. Waiting room idle timeout (15-30 min)
2. Abandoned room cleanup
3. Stale connection cleanup
4. Database persistence for game recovery

### Phase 5: Client Integration
1. Automatic reconnect with exponential backoff
2. UI indication of connection status
3. Countdown before rejoin possibility expires
4. Offline queue for actions

---

## ARCHITECTURE RECOMMENDATIONS

### 1. Player Session State
```elixir
defmodule PlayerSession do
  defstruct [
    :user_id,
    :room_code,
    :position,
    :status,           # :connected, :disconnected, :reconnecting
    :connected_at,
    :disconnected_at,  # nil while connected
    :last_action_at,
    :reconnect_deadline
  ]
end
```

### 2. Enhanced Room Model
```elixir
# Add to Room struct:
player_sessions: %{user_id => PlayerSession}
started_at: DateTime          # Game start time
last_activity: DateTime       # For timeout
```

### 3. GameChannel Callbacks
```elixir
def terminate(reason, socket) do
  # Notify RoomManager
  # Broadcast player_disconnected
  # Start reconnect grace period
end

def handle_info({:reconnect_timeout, player_id}, socket) do
  # Remove player permanently
  # Resume game
end
```

### 4. PubSub Events
```
game:<room_code>:
  - {:state_update, state}
  - {:game_over, winner, scores}
  - {:player_disconnected, position}      # NEW
  - {:player_reconnected, position}       # NEW
  - {:reconnect_timeout, position}        # NEW
```

---

## TEST COVERAGE GAPS

Current tests in `game_channel_test.exs`:
- ✅ Join authentication
- ✅ Bid/trump/card actions
- ✅ Presence tracking
- ❌ Disconnect handling
- ❌ Reconnection flow
- ❌ Timeout scenarios
- ❌ Game state with missing players
- ❌ AI play for disconnected players

---

## CONCLUSION

The Pidro server has a solid **presence tracking infrastructure** but lacks:

1. **No disconnect notification system** - Game channels have no cleanup on connection loss
2. **No reconnect support** - Players permanently lose their game on disconnect
3. **No player availability tracking** - Game doesn't know who's actually connected
4. **No timeout mechanisms** - Rooms can linger indefinitely in waiting state
5. **No session management** - Can't differentiate connection sessions

The architecture is well-suited for adding reconnection support. The main work is:
1. Adding disconnect handlers to channels
2. Implementing player session state tracking
3. Creating reconnect grace period logic
4. Handling game continuation with AI for disconnected players

**Estimated implementation effort:** 3-4 weeks for complete reconnection support including testing.

