---
status: complete
priority: p2
issue_id: "007"
tags: [security, data-leakage, code-review]
dependencies: []
---

# Remove reserved_for from Lobby-Facing Serialization

## Problem Statement
`Seat.serialize/1` includes `reserved_for` (the disconnected player's user_id) in all responses. This is broadcast to every lobby user, leaking which specific user disconnected from which room.

## Findings
- Location: `seat.ex:295-306` — `serialize/1` includes `reserved_for`
- Location: `lobby_channel.ex:224-231` — broadcasts to all lobby users
- Location: `room_json.ex:113-129` — included in REST responses
- All lobby users can see which user_id is disconnected from which room

## Proposed Solutions

### Option 1: Replace reserved_for with boolean in public serialization
- Change `Seat.serialize/1` to output `has_reservation: true/false` instead of the raw user_id
- Keep `reserved_for` in internal state for the cascade logic
- **Pros**: No user_id leakage, lobby still knows if a seat is reserved
- **Cons**: Minor serialization change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Replace `reserved_for: user_id` with `has_reservation: boolean` in `Seat.serialize/1`.

## Technical Details
- **Affected Files**: `seat.ex`
- **Related Components**: Lobby channel, REST API, seat serialization
- **Database Changes**: No

## Acceptance Criteria
- [ ] `reserved_for` user_id not exposed in serialized output
- [ ] `has_reservation` boolean replaces it
- [ ] Seat serialization tests updated
- [ ] Lobby and REST responses still work

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Security Sentinel of PR #15
