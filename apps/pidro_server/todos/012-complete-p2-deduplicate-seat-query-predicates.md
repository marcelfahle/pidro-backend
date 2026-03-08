---
status: complete
priority: p2
issue_id: "012"
tags: [architecture, duplication, code-review]
dependencies: []
---

# Deduplicate Seat Query Predicates Across Modules

## Problem Statement
`has_vacant_seat?/1` and `has_reserved_seat?/2` are reimplemented in 3 modules (GameChannel, LobbyChannel, RoomManager). If the definition of "reserved seat" changes, three places need updating.

## Findings
- Location: `game_channel.ex:669-680` — `has_vacant_seat?/1`, `has_reserved_seat?/2`
- Location: `lobby_channel.ex:268-282` — same functions, slightly different implementation
- Location: `room_manager.ex:1755-1759, 2329-2337` — `find_vacant_seat_position/1`, `seat_reserved_for_user?/2`
- All query the same Seat struct data; should live in Seat module

## Proposed Solutions

### Option 1: Add room-level query functions to Seat module
- Add `Seat.any_vacant?(seats_map)` and `Seat.reserved_for_user?(seats_map, user_id)` to the Seat module
- Replace all 3 implementations with calls to these shared functions
- **Pros**: Single source of truth, follows existing Seat module pattern
- **Cons**: Minor refactor across 3 files
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Add the query functions to `Seat` module and replace duplicates.

## Technical Details
- **Affected Files**: `seat.ex`, `game_channel.ex`, `lobby_channel.ex`, `room_manager.ex`
- **Related Components**: Seat queries, lobby filtering, substitute joins
- **Database Changes**: No

## Acceptance Criteria
- [ ] `has_vacant_seat?` and `has_reserved_seat?` live in Seat module
- [ ] All 3 modules use shared implementation
- [ ] All tests pass unchanged

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Architecture Strategist + Pattern Recognition + Simplicity Reviewer of PR #15
