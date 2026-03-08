---
status: complete
priority: p1
issue_id: "001"
tags: [security, authentication, code-review]
dependencies: []
---

# Game State Endpoint Exposes All Player Hands Without Auth

## Problem Statement
`GET /api/v1/rooms/:code/state` is in the unauthenticated router pipeline and returns every player's hand of cards. Room codes are 4 alphanumeric chars (~1.68M combinations), easily brute-forced. This enables cheating in a card game where hand secrecy is fundamental.

## Findings
- Location: `router.ex:48` — route in unauthenticated pipeline
- Location: `room_controller.ex:1071-1079` — state action
- Location: `game_state_serializer.ex:60-67` — serializes `player.hand` for ALL players
- Any unauthenticated user can see every player's cards

## Proposed Solutions

### Option 1: Move route behind auth + per-player hand filtering
- Move `/rooms/:code/state` into the authenticated `:api` pipeline
- Filter hand data: each player sees only their own hand, others see card count only
- **Pros**: Fixes both auth gap and information leakage
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Move the route behind auth pipeline. Update serializer to accept a `viewer_user_id` and only include full hand for that player.

## Technical Details
- **Affected Files**: `router.ex`, `room_controller.ex`, `game_state_serializer.ex`
- **Related Components**: REST API, game state serialization
- **Database Changes**: No

## Acceptance Criteria
- [ ] `/rooms/:code/state` requires authentication
- [ ] Response only includes the requesting player's hand
- [ ] Other players' hands are returned as card counts
- [ ] Existing tests pass

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Security Sentinel review of PR #15
