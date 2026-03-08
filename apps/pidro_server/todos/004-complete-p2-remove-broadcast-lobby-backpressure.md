---
status: complete
priority: p2
issue_id: "004"
tags: [performance, dead-code, code-review]
dependencies: ["003"]
---

# Remove broadcast_lobby Back-Pressure Loop

## Problem Statement
`broadcast_lobby/1` sends `{:lobby_update, rooms}` with the full room list. Each lobby channel subscriber then calls `RoomManager.list_lobby(user_id)` back synchronously — creating a feedback loop. With 200 lobby users, that's 200 GenServer.calls queued after every room change. `broadcast_lobby` is only called once (in the legacy dead code handler), making it doubly dead.

## Findings
- Location: `room_manager.ex:1465` — only call site (inside dead `:check_disconnect_timeout`)
- Location: `room_manager.ex:2364-2376` — `broadcast_lobby/1` function definition
- Location: `lobby_channel.ex:94-103` — handler calls `list_lobby` back to GenServer
- `broadcast_lobby_event/1` (used 20+ places) is the correct incremental approach

## Proposed Solutions

### Option 1: Delete broadcast_lobby/1 entirely
- Remove the function definition
- Remove the one call site (which is in dead code being removed by #003)
- Remove the `{:lobby_update, rooms}` handler in LobbyChannel
- **Pros**: Eliminates back-pressure loop, removes dead code
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

## Recommended Action
Delete `broadcast_lobby/1` and its LobbyChannel handler. Depends on #003 removing the call site first.

## Technical Details
- **Affected Files**: `room_manager.ex`, `lobby_channel.ex`
- **Related Components**: Lobby broadcasting, PubSub
- **Database Changes**: No

## Acceptance Criteria
- [ ] `broadcast_lobby/1` function removed
- [ ] `{:lobby_update, rooms}` handler removed from LobbyChannel
- [ ] All lobby tests pass
- [ ] Incremental `broadcast_lobby_event` still works

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Performance Oracle + Code Simplicity Reviewer of PR #15
