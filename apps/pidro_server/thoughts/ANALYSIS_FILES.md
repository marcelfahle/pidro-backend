# Reconnection Analysis - File Locations & Contents

## Analysis Documents Generated

This analysis contains three comprehensive documents about reconnection handling in the Pidro server:

### 1. RECONNECTION_ANALYSIS.md
**Location:** `/Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/RECONNECTION_ANALYSIS.md`

**Contents:**
- Executive summary of current state (NO reconnection support)
- Detailed analysis of 8 core modules and systems
- Section 1: Current presence tracking (Phoenix.Presence)
- Section 2: GameChannel disconnect handling (CRITICAL GAPS)
- Section 3: RoomManager state tracking
- Section 4: GameAdapter state interface
- Section 5: GameSupervisor and GameRegistry
- Section 6: Channel authentication (UserSocket)
- Section 7: Existing timeout/cleanup logic
- Section 8: LobbyChannel disconnect handling
- Critical gaps summary with visual flow diagrams
- Implementation roadmap (5 phases)
- Architecture recommendations with code examples
- Test coverage gaps
- Conclusion and effort estimate (3-4 weeks)

**Best For:** Understanding the current state and gaps

---

### 2. RECONNECTION_IMPLEMENTATION_GUIDE.md
**Location:** `/Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/RECONNECTION_IMPLEMENTATION_GUIDE.md`

**Contents:**
- Quick reference table of all core modules
- 5 detailed implementation steps with complete code:
  - STEP 1: Add disconnect handler to GameChannel
  - STEP 2: Enhance RoomManager for disconnects
  - STEP 3: Update GameChannel to handle reconnects
  - STEP 4: Add reconnect support to UserSocket
  - STEP 5: Create database migration (optional)
- Testing strategy with code examples
- Client-side integration points (JavaScript)
- Phased rollout plan (4 weeks)
- Monitoring and debugging guidance
- Common pitfalls to avoid

**Best For:** Actually implementing the reconnection feature

---

### 3. ANALYSIS_FILES.md (This File)
**Location:** `/Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/ANALYSIS_FILES.md`

**Contents:**
- Index of all analysis files
- File locations and purposes

---

## Analyzed Source Files

### Critical Files (Reconnection Gaps)

| File | Lines | Key Findings |
|------|-------|--------------|
| `lib/pidro_server_web/channels/game_channel.ex` | 322 | **NO disconnect handler** - Player disconnects are silent |
| `lib/pidro_server/games/room_manager.ex` | 641 | No reconnection state, immediate player removal |
| `lib/pidro_server_web/channels/user_socket.ex` | 74 | JWT auth works but no session tracking |
| `lib/pidro_server_web/channels/lobby_channel.ex` | 116 | No disconnect handler (secondary) |

### Supporting Infrastructure (Generally Good)

| File | Lines | Status |
|------|-------|--------|
| `lib/pidro_server/games/game_supervisor.ex` | 195 | Working supervision system |
| `lib/pidro_server/games/game_adapter.ex` | 297 | Clean game interface |
| `lib/pidro_server_web/presence.ex` | 33 | Phoenix.Presence integration |
| `lib/pidro_server/games/game_registry.ex` | 100 | Simple but effective PID lookup |
| `lib/pidro_server/games/supervisor.ex` | 59 | Domain supervision tree |
| `lib/pidro_server/accounts/token.ex` | 90 | JWT token generation/verification |

### Tests

| File | Lines | Coverage |
|------|-------|----------|
| `test/pidro_server_web/channels/game_channel_test.exs` | 348 | Join, presence, actions (NO disconnect tests) |

---

## Key Discoveries

### Critical Issues (Must Fix)

1. **GameChannel has no `terminate/2` callback**
   - Location: `lib/pidro_server_web/channels/game_channel.ex`
   - Impact: Disconnects are completely silent
   - Fix: Add terminate/2 handler (10 lines of code)

2. **RoomManager doesn't track player connection state**
   - Location: `lib/pidro_server/games/room_manager.ex` Room struct
   - Impact: No reconnection window, instant player removal
   - Fix: Add player_sessions map, implement reconnect logic (150 lines)

3. **No reconnection grace period**
   - Location: Multiple files
   - Impact: Player permanently loses game on disconnect
   - Fix: Add 5-minute reconnect window (50 lines in RoomManager)

4. **Presence not integrated with RoomManager**
   - Impact: Can get out of sync
   - Fix: Listen to presence events, sync state

### Good Foundations

- Phoenix.Presence is properly integrated (just needs disconnect listening)
- GameAdapter provides clean interface for game actions
- Token-based authentication is solid (30-day expiry is good)
- Game supervision system is robust

---

## Implementation Checklist

### Phase 1: Disconnect Detection (1 week)
- [ ] Add `terminate/2` to GameChannel
- [ ] Add `terminate/2` to LobbyChannel
- [ ] Implement `player_disconnected/2` in RoomManager
- [ ] Broadcast disconnect notifications
- [ ] Write tests for disconnect detection

### Phase 2: Reconnection Support (1 week)
- [ ] Add PlayerSession struct to RoomManager
- [ ] Implement `player_reconnected/2` in RoomManager
- [ ] Add reconnect grace period (5 minutes)
- [ ] Implement reconnect timeout cleanup
- [ ] Update GameChannel `join/3` for reconnects

### Phase 3: Game State (1 week)
- [ ] Add player availability to game state
- [ ] Implement player rejoin logic
- [ ] Handle mid-game reconnections
- [ ] Add AI play for disconnected players (if needed)

### Phase 4: Polish & Testing (1 week)
- [ ] Client-side auto-reconnect
- [ ] UI feedback for connection status
- [ ] Performance testing
- [ ] Production deployment

---

## File Change Summary

### Files to Create
- [ ] Optional: Migration for player_sessions table

### Files to Modify
1. `lib/pidro_server_web/channels/game_channel.ex`
   - Add: terminate/2 callback
   - Add: rejoin handler
   - Modify: join/3 for reconnect detection
   - Lines to add: ~30

2. `lib/pidro_server/games/room_manager.ex`
   - Add: PlayerSession struct
   - Add: player_disconnected/2 function
   - Add: player_reconnected/2 function
   - Add: can_reconnect?/2 function
   - Add: handle_call implementations (3 new patterns)
   - Add: handle_info for timeout
   - Modify: Room struct (add player_sessions field)
   - Lines to add: ~200

3. `lib/pidro_server_web/channels/user_socket.ex`
   - Modify: id/1 for session tracking
   - Lines to add: ~5

### Files to Leave Unchanged (Use As-Is)
- GameAdapter - Just provides interface, works fine
- GameSupervisor - Supervision logic is good
- GameRegistry - Lookup works perfectly
- Presence - Phoenix.Presence handles it well
- Token - JWT auth is fine

---

## Code Patterns Used

### Erlang OTP Patterns
- GenServer for state management (RoomManager)
- DynamicSupervisor for game processes
- Registry for process lookup
- Supervision trees and restart strategies

### Phoenix Patterns
- Channel callbacks (join/3, terminate/2, handle_info/2)
- Phoenix.Presence for distributed tracking
- PubSub for message broadcasting
- Socket assigns for state storage

### Elixir Patterns
- Pattern matching in function heads
- with/1 for error handling
- Structs for typed data
- Atoms for state representation

---

## Timing Estimate

### Implementation
- Phase 1 (Disconnect Detection): 8-12 hours
- Phase 2 (Reconnection): 8-12 hours
- Phase 3 (Game State): 8-12 hours
- Phase 4 (Polish & Testing): 8-16 hours
- **Total Backend: 32-52 hours (4-6.5 days)**

### Client Integration
- JavaScript auto-reconnect: 4-6 hours
- UI updates: 4-6 hours
- Testing: 4-6 hours
- **Total Frontend: 12-18 hours (1.5-2.5 days)**

### Total Project: 3-4 weeks of development

---

## Testing Strategy Overview

### Unit Tests
- [ ] RoomManager disconnect/reconnect flows
- [ ] PlayerSession state transitions
- [ ] Timeout cleanup logic

### Integration Tests
- [ ] GameChannel disconnect and cleanup
- [ ] Multi-player disconnect scenarios
- [ ] Reconnect within and after grace period

### End-to-End Tests
- [ ] Full game with simulated disconnects
- [ ] Network reconnection recovery
- [ ] AI play for disconnected players

---

## Related Documentation

### In This Project
- API documentation (existing)
- GameChannel test file shows current test patterns
- RoomManager implementation shows GenServer patterns

### Phoenix References
- https://hexdocs.pm/phoenix/Phoenix.Channel.html
- https://hexdocs.pm/phoenix/Phoenix.Presence.html
- https://hexdocs.pm/phoenix/Phoenix.Socket.html

### Elixir References
- https://hexdocs.pm/elixir/GenServer.html
- https://hexdocs.pm/elixir/Supervisor.html
- https://hexdocs.pm/elixir/DynamicSupervisor.html

---

## Contact & Questions

For questions about this analysis:
1. Check RECONNECTION_ANALYSIS.md for architecture details
2. Check RECONNECTION_IMPLEMENTATION_GUIDE.md for code patterns
3. Review the actual source files listed above
4. Test locally with the provided code examples

---

## Glossary

- **Presence**: Real-time tracking of connected players (Phoenix.Presence)
- **Disconnect**: Loss of WebSocket connection
- **Reconnect**: Re-establishing connection within grace period
- **Grace Period**: Time window to reconnect before permanent removal (5 minutes)
- **PlayerSession**: State tracking for individual player connection
- **GenServer**: Elixir process for managing state
- **PubSub**: Publish-subscribe pattern for message broadcasting
- **Channel**: Phoenix WebSocket connection handler
- **Room**: Game room with 4 players and game state
- **RoomManager**: GenServer managing all rooms and players

