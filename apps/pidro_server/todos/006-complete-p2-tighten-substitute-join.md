---
status: complete
priority: p2
issue_id: "006"
tags: [security, authorization, code-review]
dependencies: []
---

# Tighten Substitute Join Authorization

## Problem Statement
`determine_user_role/2` in GameChannel grants `:substitute` role to ANY authenticated user if the room has a vacant seat, without verifying the seat was explicitly opened by the owner via `open_seat`. While `RoomManager.join_as_substitute/2` does validate the seat, the channel-level check is too permissive.

## Findings
- Location: `game_channel.ex:656-666` — `determine_user_role` checks `has_vacant_seat?` too loosely
- Location: `game_channel.ex:670-673` — `has_vacant_seat?/1` checks for ANY vacant seat
- A seat could be vacant due to cascade transitions, not just explicit owner opening

## Proposed Solutions

### Option 1: Tighten has_vacant_seat? to check for explicitly opened seats
- Only match seats where `occupant_type == :vacant` AND `status == :connected` (or a dedicated `:open_for_substitute` status)
- Or add a boolean flag to Seat that marks it as explicitly opened
- **Pros**: Defense in depth, clearer intent
- **Cons**: Minor Seat struct change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Verify that `has_vacant_seat?` only matches seats opened via `Seat.open_for_substitute/1`, not any vacant seat.

## Technical Details
- **Affected Files**: `game_channel.ex`, possibly `seat.ex`
- **Related Components**: Substitute join flow
- **Database Changes**: No

## Acceptance Criteria
- [ ] Only seats explicitly opened by owner allow substitute joins
- [ ] Vacant seats from other transitions don't trigger substitute role
- [ ] Substitute seat tests pass
- [ ] Existing join tests pass

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Security Sentinel of PR #15
