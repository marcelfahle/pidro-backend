---
status: complete
priority: p2
issue_id: "005"
tags: [performance, code-review]
dependencies: []
---

# Single-Pass Lobby Categorization + Single DB Query

## Problem Statement
`categorize_lobby/2` makes 5 separate passes over all rooms (filter + 4 category checks). Then `serialize_lobby` in LobbyChannel calls `Auth.get_users_map` 4 separate times (one per category). With 100 rooms, that's 2,000 iterations + 4 DB queries per lobby request.

## Findings
- Location: `room_manager.ex:2297-2361` — 5-pass `categorize_lobby`
- Location: `lobby_channel.ex:240-246` — `serialize_lobby` makes 4 DB queries
- Each pass iterates all rooms and checks all 4 seats per room: O(20n) per call

## Proposed Solutions

### Option 1: Single-pass categorization + batched DB query
- Collapse `categorize_lobby` into `Enum.reduce` that categorizes each room in one pass
- In `serialize_lobby`, collect all player IDs across all categories first, make one `get_users_map` call, pass shared map to all serialization calls
- **Pros**: 5x improvement to categorization, 4x fewer DB queries
- **Cons**: Slightly more complex reduce function
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Refactor both functions. Simple mechanical change.

## Technical Details
- **Affected Files**: `room_manager.ex`, `lobby_channel.ex`
- **Related Components**: Lobby filtering, user serialization
- **Database Changes**: No

## Acceptance Criteria
- [ ] `categorize_lobby` uses single-pass `Enum.reduce`
- [ ] `serialize_lobby` makes exactly 1 DB query
- [ ] Lobby filtering tests pass unchanged
- [ ] Same output as before

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Performance Oracle of PR #15
