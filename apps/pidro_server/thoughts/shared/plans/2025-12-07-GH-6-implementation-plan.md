---
date: 2025-12-07
author: Claude Code
git_commit: 366c53748540ab4afa2232c4868a764d12b0266d
branch: main
repository: pidro_backend
topic: "GitHub Issue #6: Dev Admin Multi-Player Session Control - Implementation Plan"
status: pending_approval
tags: [plan, dev-admin, testing, seat-management, github-issue-6]
related_research: thoughts/shared/research/2025-12-07-GH-6-dev-admin-multi-player-control.md
related_spec: specs/pidro_server_specification.md
---

# Implementation Plan: GitHub Issue #6 - Dev Admin Multi-Player Session Control

**Date**: 2025-12-07  
**Issue**: GitHub #6  
**Related Research**: `thoughts/shared/research/2025-12-07-GH-6-dev-admin-multi-player-control.md`

## Analysis: Research vs Specification

### ✅ Alignment Points

The research document correctly identifies:

1. **Room.positions as single source of truth** - ✅ Matches spec (L53-105)
   - Spec states: "positions: %{north: nil, east: nil, south: nil, west: nil}"
   - Research correctly identifies this as the map to manipulate

2. **Position-based game actions** - ✅ Matches spec (L389-393)
   - Spec: `GameAdapter.apply_action(room_code, position, action)`
   - Research correctly identifies no authentication needed at game engine level

3. **Existing infrastructure** - ✅ All mentioned components exist
   - Auth.list_recent_users/1 - Available for dropdowns
   - GameDetailLive - Correct target for UI
   - RoomManager - Correct place for backend logic

4. **Simple implementation scope** - ✅ Matches MVP philosophy
   - Spec principle: "Simple made easy" (L3)
   - Research correctly identifies ~50-100 LOC change

### ⚠️ Discrepancies and Problems

#### 1. **RESOLVED: Specification Doesn't Cover Dev-Only Features**

**Problem**: The specification document focuses entirely on production API and doesn't document the dev admin panel capabilities or requirements.

**Resolution**: Dev panel was added recently and is outside spec scope. This is a dev-only tool for testing, not a production feature. Will document separately later if needed.

#### 2. **RESOLVED: Validation Gap: Game Status Checks**

**Clarification from User**:
- Position changes are allowed in ANY status (`:waiting`, `:ready`, `:playing`, `:finished`)
- Players can leave and rejoin during gameplay
- Host ID can change (auto-assigned when host leaves)
- Host ID is not critical for this feature

**Implementation**: NO validation on room status - allow position changes at any time.

#### 3. **ACTION REQUIRED: Broadcast Coordination**

**Problem**: Research mentions "broadcast_room(updated_room, state)" but doesn't verify this exists or matches spec patterns.

**Spec Reference**: 
- L240-256 (Lobby Channel broadcasts)
- L582-660 (Game Channel broadcasts)

**Investigation Needed**: Verify which PubSub topics to broadcast to when dev changes positions:
- `room:<room_code>` - ✓ Mentioned in spec (L240)
- `lobby:updates` - ✓ Mentioned in spec (L240)
- `game:<room_code>` - ❓ Should dev changes notify game channel subscribers?

**Action**: Thoroughly investigate existing broadcast patterns in RoomManager and ensure dev position changes trigger all appropriate broadcasts.

#### 4. **RESOLVED: The "2/4 Players" Bug**

**Clarification from User**: This is an existing symptom of the broken dev panel after seat selection changes. The bug will be resolved by implementing the proper seat selection UI. No separate investigation needed.

**Root Cause**: Dev panel not updated for new seat-specific join flow (vs old sequential join).

#### 5. **RESOLVED: Authorization**

**Clarification from User**: Dev panel is only used in dev environment, not exposed to production. It's a temporary testing tool.

**Implementation**: No special authorization needed - dev panel already isolated to dev environment.

#### 6. **RESOLVED: Spectator Handling**

**Clarification from User**: Ignore spectators completely for this ticket. No juggling between spectator and player positions needed.

---

## Implementation Plan

### Prerequisites ✅

- ✅ Authorization: Dev-only environment, no special auth needed
- ✅ Validation: No room status restrictions - allow changes anytime
- ✅ Spectators: Out of scope for this ticket
- ⚠️ **INVESTIGATE**: Broadcast behavior patterns

### Phase 0: Broadcast Investigation (CRITICAL)

**Goal**: Thoroughly understand and document existing broadcast patterns in RoomManager

**Tasks**:
1. Read `RoomManager` completely to find all `broadcast_*` functions
2. Document which PubSub topics are used:
   - `room:<room_code>` topic - who subscribes? what events?
   - `lobby:updates` topic - who subscribes? what events?
   - `game:<room_code>` topic - is this used by RoomManager or only GameChannel?
3. Identify the correct broadcast function(s) to call after position changes
4. Verify broadcast happens AFTER state update (to avoid race conditions)
5. Check if existing `join_room`, `leave_room` functions broadcast - use same pattern

**Estimated Time**: 30 minutes

### Phase 1: Backend - RoomManager Enhancement

**File**: `lib/pidro_server/games/room_manager.ex`

**Changes**:

1. Add `dev_set_position/3` function (public API)
2. Add `handle_call({:dev_set_position, ...}, ...)` (GenServer handler)
3. Validation (minimal):
   - Room exists
   - Position is valid (`:north`, `:east`, `:south`, `:west`)
   - User ID can be nil (to clear seat) or any string
4. Update positions map
5. Recalculate room status via `maybe_set_ready/1` (if it exists)
6. Broadcast using patterns identified in Phase 0

**Estimated Lines**: ~25 lines

**Example**:
```elixir
@doc """
Dev-only function to directly set a position without join validation.
Used by dev UI to populate test scenarios with specific players.

Allows position changes at any time (waiting, ready, playing, finished).
Set user_id to nil to clear a seat.
"""
def dev_set_position(room_code, position, user_id) 
    when position in [:north, :east, :south, :west] do
  GenServer.call(__MODULE__, {:dev_set_position, room_code, position, user_id})
end

def handle_call({:dev_set_position, room_code, position, user_id}, _from, state) do
  with {:ok, room} <- fetch_room(state, room_code) do
    updated_positions = Map.put(room.positions, position, user_id)
    updated_room = %{room | positions: updated_positions}
                   |> maybe_set_ready()
                   |> touch_last_activity()
    
    new_state = %{state | rooms: Map.put(state.rooms, room_code, updated_room)}
    
    # Use broadcast patterns from Phase 0 investigation
    broadcast_room(updated_room, state)  # or appropriate broadcast function
    
    {:reply, {:ok, updated_room}, new_state}
  else
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end
```

### Phase 2: Backend - User Lookup API

**File**: `lib/pidro_server/accounts/auth.ex`

**Verification**: Confirm `list_recent_users/1` exists and works as documented in research.

**If Missing**: Add function to list users for dropdown population.

**Estimated Lines**: ~5 lines (if needed)

### Phase 3: Frontend - GameDetailLive Enhancement (Primary Implementation)

**File**: `lib/pidro_server_web/live/dev/game_detail_live.ex`

**Changes**:

**Backend (LiveView)**:
1. Load users in `mount/3`: `users = Auth.list_recent_users(20)`
2. Add to socket assigns: `assign(:users, users)`
3. Add `handle_event("assign_seat", %{"position" => pos, "user_id" => user_id}, socket)`:
   - Parse position string to atom
   - Parse user_id (handle "empty" or nil for clearing seat)
   - Call `RoomManager.dev_set_position/3`
   - Handle success/error responses
4. Update room in socket on success (may happen via PubSub broadcast)

**Frontend (HEEx Template)**:
1. Add seat management UI section (compass layout recommended)
2. Create 4 dropdowns (north, east, south, west)
3. Populate each dropdown with:
   - "Empty Seat" option (value: nil or "")
   - All users from `@users` (display username, value: user_id)
4. Set selected value to current `@room.positions[position]`
5. Wire up `phx-change="assign_seat"` event

**Estimated Lines**: ~30 lines Elixir + ~60 lines HEEx template

**Note**: This is the recommended primary implementation for testing flexibility.

### Phase 4: Testing

**File**: `test/pidro_server/games/room_manager_test.exs`

**Add Tests**:
1. `dev_set_position/3` sets position correctly
2. `dev_set_position/3` with nil user_id clears seat
3. `dev_set_position/3` auto-updates status to `:ready` when 4 players assigned (if applicable)
4. `dev_set_position/3` broadcasts to correct topics (verify via PubSub subscription)
5. `dev_set_position/3` allows changes during `:playing` status (no restrictions)
6. `dev_set_position/3` returns error for invalid position
7. `dev_set_position/3` returns error for non-existent room

**Estimated Lines**: ~70 lines

### Phase 5: Manual Testing & Verification

**Steps**:
1. Start dev server
2. Navigate to GameDetailLive for a test room
3. Verify 4 dropdowns appear with current seat assignments
4. Change seat assignments via dropdowns
5. Verify player count updates in UI (should fix "2/4 players" issue)
6. Verify changes persist and broadcast to other connected clients
7. Test clearing a seat (set to "Empty")
8. Test during active game (`:playing` status)

---

## File Checklist

### Files to Investigate (Phase 0)

- [ ] `lib/pidro_server/games/room_manager.ex` - Document all broadcast patterns
- [ ] Identify all PubSub topics and their subscribers

### Files to Modify

- [ ] `lib/pidro_server/games/room_manager.ex` - Add dev_set_position/3 function
- [ ] `lib/pidro_server_web/live/dev/game_detail_live.ex` - Add seat management UI
- [ ] `test/pidro_server/games/room_manager_test.exs` - Add comprehensive tests

### Files to Verify

- [ ] `lib/pidro_server/accounts/auth.ex` - Confirm list_recent_users/1 exists
- [ ] `lib/pidro_server/games/room/positions.ex` - Verify count/1 derivation logic

---

## Success Criteria

### Functional Requirements

- [ ] Dev admin can select a user from dropdown for each position (north, east, south, west)
- [ ] Selecting a user immediately updates `room.positions` map
- [ ] Player count updates automatically (derived from positions)
- [ ] Can set seat to "Empty" (nil) to clear it
- [ ] Changes work at any game status (waiting, ready, playing, finished)
- [ ] Changes broadcast to all appropriate subscribers
- [ ] UI displays current seat assignments correctly

### Non-Functional Requirements

- [ ] All tests pass (`mix test`)
- [ ] No dialyzer warnings (`mix dialyzer`)
- [ ] Code follows existing patterns (thin LiveView, logic in GenServer)
- [ ] Broadcasts follow existing RoomManager patterns

### Bug Resolution

- [ ] "2/4 Players" display issue resolved by proper seat management UI
- [ ] Player count correctly reflects positions map

---

## Decisions Made (User Clarifications)

1. ✅ **Authorization**: Dev-only environment, no special authorization needed
2. ✅ **Validation**: Allow position changes at ANY game status (no restrictions)
3. ✅ **Host Changes**: Host can leave/change, not a focus for this ticket
4. ✅ **Spectators**: Out of scope - no spectator juggling
5. ✅ **Bug Investigation**: No separate investigation needed - will be fixed by implementation
6. ✅ **Implementation Scope**: GameDetailLive with dynamic seat management (primary)

---

## Estimated Effort

### Phase Breakdown

- **Phase 0 - Broadcast Investigation**: 30 minutes
- **Phase 1 - Backend (RoomManager)**: 1 hour
- **Phase 2 - User Lookup Verification**: 15 minutes
- **Phase 3 - Frontend (GameDetailLive)**: 2-3 hours
- **Phase 4 - Testing**: 1-1.5 hours
- **Phase 5 - Manual Testing**: 30 minutes

**Total Estimated**: 5.5-7 hours

### Complexity Assessment

- **Low**: Backend implementation (simple GenServer call)
- **Medium**: Frontend UI (4 dropdowns with proper state management)
- **Low**: Testing (straightforward unit tests)
- **Critical**: Broadcast investigation (must be thorough)

---

## Implementation Notes

### Key Principles

1. **Dev-only feature**: This is a testing tool, not production functionality
2. **No REST API exposure**: Only accessible via LiveView dev panel
3. **Minimal validation**: Trust dev admin to use correctly
4. **Follow existing patterns**: Match join_room/leave_room broadcast behavior
5. **Simple made easy**: ~100 LOC total change estimate remains accurate

### Critical Path

The **broadcast investigation (Phase 0)** is critical - everything else depends on getting this right. We must ensure:
- Changes propagate to all connected clients
- Player count updates correctly in UI
- No race conditions between state update and broadcast
- Both lobby list and room detail views update

### Risk Areas

1. **Broadcast timing**: If broadcast happens before state update, clients see stale data
2. **PubSub topics**: Wrong topic = clients don't receive updates
3. **LiveView state sync**: GameDetailLive must update when room changes
4. **Nil handling**: Frontend must properly handle nil values for empty seats

---

## Next Steps

Ready to proceed with implementation? The plan is updated with all your clarifications:

- ✅ No room status validation needed
- ✅ No authorization beyond dev environment
- ✅ No spectator handling
- ✅ Focus on GameDetailLive for dynamic seat management
- ⚠️ **Critical first step**: Thoroughly investigate broadcast patterns
