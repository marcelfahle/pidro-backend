---
status: complete
priority: p2
issue_id: "009"
tags: [security, code-review]
dependencies: []
---

# Replace String.to_atom with Hardcoded Mapping

## Problem Statement
`parse_metadata/1` in RoomController uses `String.to_atom(key)` on user-derived input. While constrained by `Map.take(["name"])`, atoms are never garbage collected in the BEAM. If the whitelist were accidentally expanded, this becomes an atom table exhaustion vulnerability.

## Findings
- Location: `room_controller.ex:1138-1143` — `String.to_atom(key)` inside `parse_metadata/1`
- Currently safe due to `Map.take(["name"])` but fragile

## Proposed Solutions

### Option 1: Hardcoded key mapping
- Replace with: `%{} |> maybe_put(:name, room_params["name"])`
- **Pros**: No atom creation from user input, impossible to exploit
- **Cons**: None
- **Effort**: Small (5 minutes)
- **Risk**: Low

## Recommended Action
Replace `String.to_atom` with hardcoded mapping.

## Technical Details
- **Affected Files**: `room_controller.ex`
- **Related Components**: Room creation API
- **Database Changes**: No

## Acceptance Criteria
- [ ] No `String.to_atom` on user-derived input
- [ ] Room creation still works with name parameter
- [ ] Existing tests pass

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Security Sentinel + Pattern Recognition of PR #15
