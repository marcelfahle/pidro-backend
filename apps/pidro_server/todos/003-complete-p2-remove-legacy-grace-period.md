---
status: complete
priority: p2
issue_id: "003"
tags: [dead-code, cleanup, code-review]
dependencies: []
---

# Remove Duplicate Legacy Grace Period System

## Problem Statement
Two parallel disconnect timeout systems exist: the legacy `disconnected_players` map + `:check_disconnect_timeout` handler, and the new Seat cascade (Phase 1/2/3). The legacy handler is dead code that could cause double-removal of positions. Also uses a different config source (`get_grace_period_ms/0`) than the Lifecycle module.

## Findings
- Location: `room_manager.ex:1176-1182` — legacy timer scheduling
- Location: `room_manager.ex:1423-1475` — legacy `:check_disconnect_timeout` handler (dead code)
- Location: `room_manager.ex:1217-1241` — legacy fallback branch in reconnect
- Location: `room_manager.ex:2129` — `get_grace_period_ms/0` reads from different config key
- The cascade (Phase 1/2/3) handles everything; legacy system fires after and double-removes

## Proposed Solutions

### Option 1: Remove the entire legacy system
- Remove `get_grace_period_ms/0`
- Remove `disconnected_players` field from Room struct
- Remove `:check_disconnect_timeout` handler
- Remove legacy timer scheduling at lines 1176-1182
- Remove legacy fallback branch in `handle_player_reconnect`
- **Pros**: Eliminates ~80 lines of dead code, removes double-removal bug, single config source
- **Cons**: None — the cascade system fully replaces it
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Remove all legacy grace period code. The Seat cascade is the complete replacement.

## Technical Details
- **Affected Files**: `room_manager.ex`
- **Related Components**: Disconnect handling, Room struct
- **Database Changes**: No

## Acceptance Criteria
- [ ] `get_grace_period_ms/0` removed
- [ ] `disconnected_players` field removed from Room struct
- [ ] `:check_disconnect_timeout` handler removed
- [ ] Legacy timer scheduling removed
- [ ] All existing tests pass
- [ ] No double-removal on disconnect

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Code Simplicity Reviewer of PR #15. ~80 LOC reduction.
