# Pidro Server Reconnection Analysis - Quick Start

## TL;DR

**Current Status:** The Pidro server has **ZERO reconnection support**. When a player disconnects, their game is permanently lost.

**Root Cause:** GameChannel has no `terminate/2` callback to handle disconnections.

**Fix Complexity:** Medium (3-4 weeks for full feature)

**Minimum Fix:** Add 10 lines of code to GameChannel, then add 150+ lines to RoomManager.

---

## Three Analysis Documents

1. **RECONNECTION_ANALYSIS.md** - Understand the problem
2. **RECONNECTION_IMPLEMENTATION_GUIDE.md** - Implement the solution
3. **ANALYSIS_FILES.md** - File index and reference

All located in this directory.

---

## The Problem in 60 Seconds

```
Player disconnects from WebSocket
         ↓
Nothing happens (no terminate callback)
         ↓
RoomManager still has player in list
         ↓
Game continues with ghost player
         ↓
Player can't rejoin (not in room database)
         ↓
After 5 min: Room closes
         ↓
Game over, data lost
```

---

## The Solution in 60 Seconds

1. **Add terminate/2 to GameChannel**
   - Notifies RoomManager when player disconnects
   - Broadcasts "player_disconnected" event

2. **Add reconnect grace period to RoomManager**
   - 5-minute window to reconnect
   - Track player in disconnected state
   - Start cleanup timeout

3. **Update GameChannel join to handle reconnects**
   - Check if player was disconnected
   - Re-subscribe to game updates
   - Broadcast "player_reconnected"

4. **Add client-side auto-reconnect**
   - Listen for "player_disconnected" event
   - Auto-reconnect with exponential backoff
   - Show countdown to reconnect expiration

---

## Critical Files

| File | Issue | Impact |
|------|-------|--------|
| `lib/pidro_server_web/channels/game_channel.ex` | No terminate/2 | Disconnects silent |
| `lib/pidro_server/games/room_manager.ex` | No reconnect state | Instant removal |
| `lib/pidro_server_web/channels/user_socket.ex` | No session tracking | Can't diff sessions |
| `lib/pidro_server_web/presence.ex` | Not integrated | State goes out of sync |

---

## Implementation Order

### Week 1: Disconnect Detection
1. Add terminate/2 to GameChannel
2. Add player_disconnected/2 to RoomManager
3. Broadcast disconnect notifications

### Week 2: Reconnection
1. Add PlayerSession struct
2. Implement reconnect grace period (5 min)
3. Implement reconnect timeout cleanup

### Week 3: Game Integration
1. Update join/3 for reconnects
2. Handle mid-game rejoin
3. Resume game state

### Week 4: Polish & Testing
1. Client auto-reconnect
2. UI feedback
3. Performance testing

---

## Key Code Changes

### GameChannel (10 lines)
```elixir
def terminate(reason, socket) do
  room_code = socket.assigns[:room_code]
  user_id = socket.assigns.user_id
  
  if room_code do
    RoomManager.player_disconnected(room_code, user_id)
    broadcast(socket, "player_disconnected", %{position: socket.assigns.position})
  end
  :ok
end
```

### RoomManager (150+ lines)
```elixir
# Add PlayerSession struct
# Add player_disconnected/2 function
# Add player_reconnected/2 function  
# Add can_reconnect?/2 function
# Add handle_call for reconnect logic
# Add handle_info for timeout cleanup
```

---

## Testing Checklist

### Unit Tests
- [ ] Player disconnect marked in RoomManager
- [ ] Reconnect grace period active
- [ ] Reconnect timeout cleanup works
- [ ] PlayerSession state transitions

### Integration Tests
- [ ] GameChannel broadcasts disconnect
- [ ] Players see disconnect notification
- [ ] Reconnect succeeds within grace period
- [ ] Reconnect fails after grace period

### E2E Tests
- [ ] Full game with network disconnect
- [ ] Auto-reconnect and resume
- [ ] Game state preserved across disconnect

---

## Monitoring

Key metrics to track:
- Disconnect frequency
- Reconnect success rate
- Average disconnect duration
- Reconnect attempt count

---

## Next Steps

1. Read RECONNECTION_ANALYSIS.md (15 min)
2. Review RECONNECTION_IMPLEMENTATION_GUIDE.md (30 min)
3. Create a feature branch
4. Implement Step 1 from guide
5. Write tests
6. Review and deploy

---

## Questions?

Check the docs:
1. What's the current architecture? → RECONNECTION_ANALYSIS.md, Section 1-6
2. How do I implement this? → RECONNECTION_IMPLEMENTATION_GUIDE.md, Step 1-5
3. Where are the source files? → ANALYSIS_FILES.md
4. What are the gaps? → RECONNECTION_ANALYSIS.md, "Critical Gaps Summary"

---

## Timeline

- **Reading:** 1-2 hours
- **Implementation:** 3-4 weeks
- **Testing:** 1-2 weeks
- **Deployment:** 1-2 days

**Total: 4-6 weeks to full feature** including testing and client integration.

