# Spectator Mode Implementation - Document Index

This directory contains comprehensive documentation for implementing spectator mode in the Pidro game server.

## Documents

### 1. **SPECTATOR_MODE_ANALYSIS.md** (Main Document - 1125 lines)
   
   **Purpose:** Comprehensive technical analysis and implementation guide
   
   **Contains:**
   - Executive summary
   - Current architecture (RoomManager, GameChannel, Presence)
   - Game state sharing strategies
   - Detailed implementation roadmap (5 phases)
   - Complete code examples for all modified files
   - Testing strategy
   - API endpoint specifications
   - Event flow diagrams
   - Configuration considerations
   - Migration and backward compatibility notes
   - Future enhancements
   - Summary table of required changes
   
   **Audience:** Developers implementing spectator mode
   
   **When to Read:** First read this for complete understanding

---

### 2. **SPECTATOR_QUICK_REFERENCE.md** (Quick Guide - 400+ lines)
   
   **Purpose:** Concise checklist and reference for implementation
   
   **Contains:**
   - Files to modify (in priority order)
   - Time estimates per file
   - Implementation checklist
   - Error cases to handle
   - Key design decisions
   - Testing scenarios
   - API examples
   - Channel events summary
   - Open questions for refinement
   - Success criteria
   
   **Audience:** Developers during implementation
   
   **When to Use:** Keep open while coding as a reference

---

### 3. **ARCHITECTURE_SUMMARY.md** (Context - 350+ lines)
   
   **Purpose:** Overview of current Pidro architecture
   
   **Contains:**
   - High-level component overview
   - Core components explained:
     - RoomManager GenServer
     - GameChannel WebSocket
     - GameAdapter bridge
     - Presence tracking
     - Game state flow
   - Room lifecycle state machine
   - PubSub event flows
   - Current limitations
   - Key design patterns
   - Code path walkthroughs
   
   **Audience:** Anyone wanting to understand the architecture
   
   **When to Read:** Before starting implementation

---

## Implementation Path

### For Quick Start (MVP in 6-8 hours):
1. Read **SPECTATOR_QUICK_REFERENCE.md** - 15 minutes
2. Skim **ARCHITECTURE_SUMMARY.md** - 20 minutes
3. Follow the checklist in **SPECTATOR_QUICK_REFERENCE.md**
4. Reference specific code examples from **SPECTATOR_MODE_ANALYSIS.md** as needed

### For Deep Understanding:
1. Read **ARCHITECTURE_SUMMARY.md** thoroughly - 45 minutes
2. Read **SPECTATOR_MODE_ANALYSIS.md** sections 1-4 - 1 hour
3. Reference code examples from section 7 while implementing - 30 minutes per file
4. Use **SPECTATOR_QUICK_REFERENCE.md** as checklist

### For Detailed Implementation:
1. Read all three documents in order
2. Study the code examples in section 7 of main analysis
3. Use the testing strategy from section 8
4. Reference API specifications from section 9

---

## Key Files to Modify (Execution Order)

1. **room_manager.ex** (3 hours)
   - Add spectator_ids field
   - Add join_spectator_room/2
   - Add leave_spectator/2
   - Update broadcasts

2. **game_channel.ex** (2-3 hours)
   - Modify join/3
   - Add spectator role detection
   - Guard apply_game_action for spectators
   - Update presence tracking

3. **room_controller.ex** (1 hour)
   - Add join_as_spectator/2
   - Add leave_as_spectator/2
   - Update serialization

4. **router.ex** (15 minutes)
   - Add /watch and /unwatch routes

5. **lobby_channel.ex** (30 minutes)
   - Update room serialization

**Total: 6.5-8 hours**

---

## Quick Architecture Reference

```
Client → GameChannel ("game:XXXX") → GameAdapter → Pidro.Server
                ↓
        PubSub Subscription "game:XXXX"
                ↑
        broadcast_state_update
```

**Key Points:**
- Single RoomManager manages all rooms
- GameChannel handles both players and spectators (NEW)
- Presence tracks role (:player or :spectator)
- Game state broadcasted to all connected clients
- Spectators cannot perform actions (guarded in apply_game_action)

---

## Design Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Spectators join room | Via RoomManager | Consistent with players |
| Spectators limit | Configurable (default 10) | Don't overwhelm room |
| Single or separate channel | Single ("game:XXXX") | Simpler implementation |
| State filtering | None (full state) | MVP simplicity |
| Presence tracking | Add :role field | Minimal changes |
| Allowed room statuses | :playing, :finished | Prevents lobby interference |
| Spectator count in room | Yes | Useful for UI |
| Maximum spectators limit | Yes, per config | Prevent abuse |

---

## Testing Checklist

### Unit Tests
- [ ] Spectator can join active game
- [ ] Spectator cannot exceed max limit
- [ ] Spectator cannot join as player in same room
- [ ] Spectator can leave room
- [ ] Spectator cannot perform game actions

### Integration Tests
- [ ] Multiple spectators in one game
- [ ] Spectator joins then leaves
- [ ] Game state updates reach spectator
- [ ] Presence shows spectators with role

### Manual Tests
- [ ] Join game as spectator via REST API
- [ ] Receive game state updates via WebSocket
- [ ] Attempt to bid as spectator (should fail)
- [ ] Disconnect and reconnect as spectator
- [ ] Multiple spectators present in game

---

## API Summary

### New Endpoints

```
POST /api/v1/rooms/:code/watch
  - Join game as spectator
  - Returns room with spectator_ids and spectator_count

DELETE /api/v1/rooms/:code/unwatch
  - Leave game as spectator
  - Returns 204 No Content
```

### Modified Endpoints

```
GET /api/v1/rooms
GET /api/v1/rooms/:code
  - Now includes: spectator_ids, spectator_count, max_spectators
```

---

## Common Issues & Solutions

### Issue: Spectators taking up player slots
**Solution:** Keep separate lists (spectator_ids vs player_ids)

### Issue: Spectators seeing hidden information
**Solution:** For MVP, it's expected. Add filtering in Phase 4 if needed.

### Issue: Too many spectators overwhelming room
**Solution:** Implement max_spectators limit (default 10, configurable)

### Issue: Spectators allowed in waiting rooms
**Solution:** Restrict to :playing and :finished statuses only

### Issue: Spectators trying to perform actions
**Solution:** Guard apply_game_action/1 on socket.assigns.role

---

## Performance Considerations

### Broadcast Load
- Adding spectators increases broadcast recipients
- ~10 spectators per game is manageable
- Monitor PubSub message frequency if scaling

### Memory Usage
- spectator_ids added to Room struct (list of IDs)
- Minimal overhead: ~100 bytes per spectator per room

### Scalability
- Current RoomManager handles 10-100 games
- Spectators don't change this limitation
- Future: Consider database backing for rooms

---

## Configuration

### Optional: Add to config

```elixir
config :pidro_server, :game_rooms,
  max_spectators_per_room: 10,
  allow_spectators_in_waiting: false
```

### Environment Variables
- Not required for MVP
- Can be added later for runtime configuration

---

## Future Enhancements (Phase 3+)

1. **Spectator Disconnect Grace Period**
   - Similar to player reconnection (30 seconds)
   - Lower priority than players

2. **Filtered State for Spectators**
   - Hide player hands
   - Show only public information
   - More work but fairer for competition

3. **Host Controls**
   - Mute spectators
   - Kick spectators
   - Make spectator list private

4. **Spectator Chat**
   - Separate chat channel
   - Isolated from players
   - Might interfere with game

5. **Analytics**
   - Track spectator watch time
   - Popular games
   - Engagement metrics

---

## Glossary

**RoomManager:** GenServer managing all game rooms, players, and spectators

**GameChannel:** WebSocket channel (topic: "game:XXXX") for real-time communication

**Spectator:** User who watches game but cannot perform actions

**Player:** User who participates in game with assigned position

**PubSub:** Publish-Subscribe system for broadcasting updates

**Presence:** Phoenix.Presence for tracking online users

**Game State:** Complete game information (phase, players, hands, bids, etc.)

---

## Contact & Questions

If questions arise during implementation:
1. Check SPECTATOR_MODE_ANALYSIS.md section 7 for code examples
2. Review ARCHITECTURE_SUMMARY.md for flow diagrams
3. Consult SPECTATOR_QUICK_REFERENCE.md for checklist

---

## Version History

- **v1.0** - Initial analysis and design (2024-11-02)

