---
status: complete
priority: p1
issue_id: "002"
tags: [bug, stats, code-review]
dependencies: []
---

# Substitutes Not Classified at Game Over

## Problem Statement
`stats.ex:223` has a TODO saying "detect substitutes when Phase 8 is implemented" but Phase 8 IS implemented in this PR. `classify_seat/1` never returns `:substitute`, so substitute players get wrong participation type in game stats.

## Findings
- Location: `stats.ex:223` — stale TODO comment
- Location: `stats.ex` `classify_seat/1` function — missing `:substitute` classification
- Phase 8 (substitute seat opening) is fully implemented
- Substitute players are being misclassified (likely as `:played`)

## Proposed Solutions

### Option 1: Implement substitute detection in classify_seat/1
- Check if the seat's `joined_at` is after game start, or if the seat was filled via `fill_seat` during a `:playing` room
- A substitute is a human who joined a playing room to replace a bot
- **Pros**: Fixes the bug, removes stale TODO
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Add `:substitute` classification to `classify_seat/1`. A substitute is a connected human whose seat was filled after the game started (or track via a flag on the Seat struct).

## Technical Details
- **Affected Files**: `stats/stats.ex`
- **Related Components**: Score protection, game stats recording
- **Database Changes**: No

## Acceptance Criteria
- [ ] `classify_seat/1` returns `:substitute` for players who joined mid-game
- [ ] Stale TODO comment removed
- [ ] Score protection tests updated to cover substitute classification
- [ ] Existing tests pass

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Pattern Recognition Specialist + Code Simplicity Reviewer of PR #15
