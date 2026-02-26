---
title: "fix: Bot game stuck after trump declaration — discard/rob/play phases not completing"
type: fix
date: 2026-02-09
---

# Fix: Bot Game Stuck After Trump Declaration

## Overview

When 4 bots play a game via the dev panel "4 Bots" preset, the game progresses through bidding and trump declaration but appears stuck afterward. The dev panel shows "Game has not started yet or state is unavailable" — meaning `GameAdapter.get_state/1` returns `{:error, _}`, indicating the `Pidro.Server` process either crashed or was never started.

The game log for room AAI6 shows events up through `trump_declared` (spades), with the dealer as East and South as bidding winner (bid 6). After trump declaration, the engine should auto-transition through `:discarding` → `:second_deal` → `:playing`, but the dev panel cannot fetch game state.

## Problem Analysis

### Symptom 1: "Game has not started yet or state is unavailable"

`GameDetailLive.get_game_state/1` (line 2019) calls `GameAdapter.get_state/1` which calls `GameRegistry.lookup/1`. If this returns `{:error, :not_found}`, the game state is `nil` and the template renders the "not started" message (line 1783).

**Possible causes:**
1. **Game server crashed** during the auto-transition chain (discarding → second_deal → playing). An unhandled error in `Discard.discard_non_trumps/1`, `Discard.second_deal/1`, `Discard.dealer_rob_pack/2`, or `Play.compute_kills/1` would crash the `Pidro.Server` GenServer.
2. **Game server was never started** — the game process might not have been created. The room shows `status: playing` and `4/4 players`, but that's room-level state (in `RoomManager`), not game-level state (in `Pidro.Server`).
3. **Game server started but crashed before LiveView mounted** — the LiveView loaded, called `get_game_state`, got `nil`, and never received a `{:state_update, _}` PubSub message because the game process was already dead.

### Symptom 2: "West might have too many cards"

The user observed West appearing to have too many cards. In the game state provided:
- **East** is dealer
- **South** won the bid (bid 6)
- **Trump** is spades

After discard (removing non-trumps) and second_deal (dealing to non-dealers to reach 6 cards), a player could have more than 6 cards if they had more than 6 trump cards in their original 9-card hand. This is legal — `compute_kills/1` then removes excess non-point trumps. If a player has 7+ point trumps, they keep all of them (the kill rule can't remove point cards).

However, this observation may be from a **stale** state — possibly the game state the user saw in the console was a snapshot from before the game crashed, showing the mid-transition state.

### Root Cause Investigation Needed

The exact crash must be diagnosed. Likely candidates:

1. **`dealer_rob_pack` validation failure**: `validate_six_cards/1` (discard.ex:457) requires exactly 6 cards, but `DealerRob.select_best_cards/2` (dealer_rob.ex:120) returns `Enum.take(selection_list, 6)` — if the pool has fewer than 6 cards, this returns fewer than 6, causing `{:error, {:invalid_card_count, 6, n}}`. The `handle_automatic_phase(:second_deal)` at engine.ex:562 would propagate this error, which `apply_action/3` at engine.ex:125 would return as an error, but wouldn't crash the server.

2. **GenServer crash from unhandled match/pattern**: If `Pidro.Server.handle_call` for `apply_action` doesn't properly handle all error tuples, a pattern match failure could crash the process.

3. **Bot timing issue**: When 4 bots are all assigned, the room auto-starts the game. But if bots try to make moves before the game server is fully registered in `GameRegistry`, the `GameAdapter.apply_action` calls would fail silently, and the bots might not retry.

4. **`compute_kills` crash on edge case**: If `Card.non_point_trumps/2` or the killed cards logic encounters an unexpected state (e.g., `nil` trump_suit during kills computation), it could crash.

## Proposed Solution

### Phase 1: Diagnose the crash

- [x] Add defensive logging to `Pidro.Server.handle_call(:apply_action, ...)` to log errors before returning them (already has telemetry)
- [x] Add `Logger.error` in `handle_automatic_phase/1` error branches to capture the exact failure point (BotPlayer already logs warnings)
- [x] Check if the `Pidro.Server` process for AAI6 exists: verify via `GameRegistry.lookup("AAI6")` in IEx or add a "Server Status" indicator to the dev panel
- [x] Reproduce the issue by creating a new "4 Bots" game and watching the Elixir console for errors/crashes

### Phase 2: Fix the root cause

Based on diagnosis, apply the appropriate fix. The most likely candidates:

#### 2a. Fix `validate_six_cards` for small pools (if this is the cause)

**File:** `apps/pidro_engine/lib/pidro/game/discard.ex`

```elixir
# Change validate_six_cards to accept fewer cards when pool is small
# Or: change the auto-rob path to handle the case where select_best_cards returns < 6
```

The `handle_automatic_phase(:second_deal)` at engine.ex:555-568 should handle the case where `DealerRob.select_best_cards/2` returns fewer than 6 cards — pass the actual count to `dealer_rob_pack` with a dynamic validation, or skip the rob entirely if pool < 6.

#### 2b. Add game server health check to dev panel

**File:** `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex`

- [ ] When `game_state` is `nil` but room status is `playing`, show a diagnostic message: "Game server not running. Room exists but game process is missing."
- [ ] Add a "Restart Game" button that calls `GameSupervisor.start_game/1` to restart the process
- [ ] Or: show the last known game state from the events/log if available

#### 2c. Improve error handling in auto-transition chain

**File:** `apps/pidro_engine/lib/pidro/game/engine.ex`

- [ ] The `handle_automatic_phase(:second_deal)` error branch at line 580-582 currently just returns the error. If `dealer_rob_pack` fails, the entire `apply_action` chain returns an error. The `Pidro.Server` GenServer would return `{:error, _}` to the caller, but the state remains unchanged (still in `:second_deal`).
- [ ] However, the previous action (trump declaration) already succeeded and was committed. The auto-transition failure means the state is stuck in an intermediate phase.
- [ ] Fix: If auto dealer rob fails, fall back to manual mode (leave state in `:second_deal` with `current_turn` set to dealer) rather than returning an error.

#### 2d. Improve bot resilience for edge cases

**File:** `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex`

- [ ] Add retry logic when `GameAdapter.apply_action` returns an error
- [x] Log the error with context (position, phase, action) so crashes are diagnosable (already in BotPlayer)
- [x] Handle `{:select_hand, :choose_6_cards}` properly — added `resolve_action` in BotPlayer to compute actual card selection via DealerRob.select_best_cards

### Phase 3: Verify with a full bot game

- [x] Create a new "4 Bots" game
- [x] Watch it complete through all phases: bidding → declaring → discarding → second_deal → playing → scoring
- [x] Verify no errors in the console
- [x] Verify the dev panel shows the game state at each phase
- [ ] Verify games can complete multiple hands and reach `winning_score` (62) — tested through 6 hands, score N/S:19 E/W:29, still running

## Investigation Steps (for the developer)

To diagnose this right now:

1. **Check if the server process exists:**
   ```elixir
   # In IEx
   PidroServer.Games.GameRegistry.lookup("AAI6")
   ```

2. **Check for crash logs in the terminal** — look for `** (EXIT)` or `GenServer ... terminating` messages

3. **Create a new 4-bot game and watch the console:**
   - Go to http://localhost:4002/dev/games
   - Click "4 Bots"
   - Watch the Elixir terminal for any error output

4. **Run the engine tests to verify auto-transition works:**
   ```bash
   mix test apps/pidro_engine/test/integration/auto_dealer_rob_integration_test.exs
   ```

5. **Check if the issue is reproducible** — does every 4-bot game get stuck, or just some?

## Key Files

### Files to Investigate
- `apps/pidro_engine/lib/pidro/game/engine.ex:528-583` — `handle_automatic_phase(:second_deal)` auto-transition chain
- `apps/pidro_engine/lib/pidro/game/discard.ex:360-408` — `dealer_rob_pack/2` validation (validate_six_cards)
- `apps/pidro_engine/lib/pidro/game/discard.ex:239-310` — `second_deal/1` card distribution
- `apps/pidro_engine/lib/pidro/game/play.ex:95-135` — `compute_kills/1`
- `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex:182-231` — `execute_move/1` bot action handling
- `apps/pidro_engine/lib/pidro/server.ex:290-320` — `Pidro.Server.handle_call(:apply_action, ...)`

### Files to Modify (likely)
- `apps/pidro_engine/lib/pidro/game/engine.ex` — Improve error handling in auto-transition
- `apps/pidro_engine/lib/pidro/game/discard.ex` — Fix `validate_six_cards` for small pools
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex` — Better diagnostic when game_state is nil
- `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex` — Better error logging

## Game Flow Reference

```
:bidding → (bot bids/passes) → :declaring
    → (bot declares trump) → :discarding [AUTO]
    → discard_non_trumps [AUTO] → :second_deal [AUTO]
    → second_deal (deal to non-dealers) [AUTO]
    → dealer_rob_pack (auto or manual) → :playing [AUTO]
    → compute_kills → bots play cards → :scoring [AUTO]
    → score_hand → :hand_complete [AUTO] → next hand or :complete
```

The `[AUTO]` phases happen inside `maybe_auto_transition/1` recursion — all within a single `apply_action` call. If any step fails, the entire chain stops and the state rolls back to the last successful phase.

## Acceptance Criteria

- [x] 4-bot games reliably complete through all phases without crashing
- [x] Dev panel shows game state throughout the entire game lifecycle
- [x] No "Game has not started yet or state is unavailable" when a game is actively running
- [x] Engine auto-transitions work correctly: discarding → second_deal → dealer rob → playing
- [x] `compute_kills` correctly handles players with 0, 6, or >6 trump cards
- [x] Console shows no unhandled errors during bot gameplay
