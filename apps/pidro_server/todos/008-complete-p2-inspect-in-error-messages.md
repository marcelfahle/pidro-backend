---
status: complete
priority: p2
issue_id: "008"
tags: [security, error-handling, code-review]
dependencies: []
---

# Replace inspect(reason) in Client-Facing Error Messages

## Problem Statement
Channel error responses use `inspect(reason)` which sends Elixir internal representations to clients. Could leak module paths, struct names, or stack traces from unexpected errors.

## Findings
- Location: `game_channel.ex:116-118` — reconnection failure: `inspect(reason)`
- Location: `game_channel.ex:132` — substitute join failure: `inspect(reason)`
- `format_error/1` already exists at line 691 but isn't used in these paths

## Proposed Solutions

### Option 1: Use existing format_error/1
- Replace `inspect(reason)` with `format_error(reason)` in both locations
- **Pros**: Uses existing helper, no new code needed
- **Cons**: None
- **Effort**: Small (5 minutes)
- **Risk**: Low

## Recommended Action
Replace both `inspect(reason)` calls with `format_error(reason)`.

## Technical Details
- **Affected Files**: `game_channel.ex`
- **Related Components**: Channel error responses
- **Database Changes**: No

## Acceptance Criteria
- [ ] No `inspect()` in client-facing error messages
- [ ] `format_error/1` used instead
- [ ] Error messages are still meaningful for debugging

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Security Sentinel of PR #15
