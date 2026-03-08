---
status: complete
priority: p2
issue_id: "010"
tags: [bug, error-handling, code-review]
dependencies: []
---

# Missing FallbackController Clause for :no_vacant_seat

## Problem Statement
`RoomManager.join_as_substitute/2` can return `{:error, :no_vacant_seat}` but FallbackController has no matching clause. This produces a 500 Internal Server Error instead of a proper error response. Also missing a catch-all for any future unhandled error atoms.

## Findings
- Location: `room_manager.ex:1758` — returns `{:error, :no_vacant_seat}`
- Location: `fallback_controller.ex` — no clause for `:no_vacant_seat`

## Proposed Solutions

### Option 1: Add specific clause + catch-all
- Add `{:error, :no_vacant_seat}` handler returning 422
- Add catch-all `{:error, reason} when is_atom(reason)` returning generic 422
- **Pros**: Handles current gap + future-proofs
- **Cons**: None
- **Effort**: Small (5 minutes)
- **Risk**: Low

## Recommended Action
Add both the specific clause and a catch-all.

## Technical Details
- **Affected Files**: `fallback_controller.ex`
- **Related Components**: REST API error handling
- **Database Changes**: No

## Acceptance Criteria
- [ ] `:no_vacant_seat` returns proper error response
- [ ] Catch-all handles any future unmatched error atoms
- [ ] No 500 errors from known error paths

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Pattern Recognition + Security Sentinel of PR #15
