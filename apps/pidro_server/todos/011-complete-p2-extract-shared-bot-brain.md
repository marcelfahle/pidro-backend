---
status: complete
priority: p2
issue_id: "011"
tags: [architecture, duplication, code-review]
dependencies: []
---

# Extract Shared BotBrain Module from SubstituteBot/BotPlayer

## Problem Statement
`SubstituteBot` and `BotPlayer` share ~80% identical code: `execute_move`, `resolve_action`, `get_game_state`, `should_make_move?` are nearly line-for-line identical. This creates a maintenance burden and divergence risk.

## Findings
- Location: `substitute_bot.ex:137-220` — move execution logic
- Location: `bot_player.ex:197-284` — nearly identical move execution logic
- Key differences: BotPlayer joins room on init, supports pause/resume; SubstituteBot takes over existing seat

## Proposed Solutions

### Option 1: Extract BotBrain shared module
- Create `PidroServer.Games.Bots.BotBrain` with shared functions
- Both GenServers delegate move logic to BotBrain
- Each keeps only lifecycle-specific code (join vs takeover, pause/resume)
- **Pros**: DRY, single place to improve bot logic
- **Cons**: Medium refactor
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
Extract `BotBrain` module with `should_make_move?/2`, `execute_move/3`, `resolve_action/3`, `get_game_state/1`.

## Technical Details
- **Affected Files**: `substitute_bot.ex`, `bot_player.ex`, new `bots/bot_brain.ex`
- **Related Components**: Bot system
- **Database Changes**: No

## Acceptance Criteria
- [ ] Shared logic in `BotBrain` module
- [ ] Both bot GenServers delegate to it
- [ ] Bot behavior unchanged
- [ ] All bot-related tests pass

## Work Log

### 2026-03-08 - Approved for Work
**By:** Claude Triage System
**Actions:**
- Issue approved during triage session
- Status: ready

## Notes
Source: Architecture Strategist of PR #15
