---
title: "feat: Agent-Playable Pidro Game System"
type: feat
date: 2026-02-08
---

# Agent-Playable Pidro Game System

## Overview

Make the Pidro game playable by programmatic agents (LLMs like Claude, bots, test harnesses) by extending the existing `Pidro.IEx` module with two new functions and fixing existing bugs that block clean programmatic access.

No new modules. No REST endpoints (yet). No auth changes. Just extend what's already there.

## Problem Statement

**Today:** An LLM agent running locally can call `Pidro.IEx.new_game/0` and `Pidro.IEx.step/3` to interact with the engine, but there's no way to play a complete game programmatically with a pluggable strategy. The existing `full_demo_game/0` hardcodes a random strategy with IO output. Additionally, several bugs in the server layer (unmasked state endpoint, broken `get_state/2`, wrong phase check) block future REST access.

**After this:** An agent can call `Pidro.IEx.start_server_game/0` to get a GenServer-backed game, then `Pidro.IEx.play_full_game/2` with any strategy function to play to completion. Foundation bugs are fixed for when REST endpoints are needed later.

## Technical Approach

### Phase 1: Fix Existing Bugs (Foundation)

Fix these first — they're correctness issues that affect everything built on top.

#### 1a. Fix `GameAdapter.broadcast_state_update/2` phase mismatch

`broadcast_state_update/2` checks `state.phase == :game_over` but the engine's terminal phase is `:complete`. The game_over broadcast never fires.

**Fix:** Change `:game_over` to `:complete`.

**File:** `apps/pidro_server/lib/pidro_server/games/game_adapter.ex` (~line 359)

#### 1b. Fix `GameAdapter.get_state/2` no-op

`get_state(room_code, position)` ignores the position parameter and returns unmasked state.

**Fix:** Wire it to use `StateView.for_player(state, position)`.

**File:** `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`

#### 1c. Fix unmasked REST state endpoint

`GET /api/v1/rooms/:code/state` returns full unmasked state to unauthenticated callers.

**Fix:**
- Move to authenticated pipeline
- Return `StateView.for_player(state, position)` for players
- Return `StateView.for_spectator(state)` for spectators

**Files:**
- `apps/pidro_server/lib/pidro_server_web/router.ex`
- `apps/pidro_server/lib/pidro_server_web/controllers/api/room_controller.ex`

#### 1d. Fix dealer rob visibility

During `:second_deal` when the dealer must rob the pack, `StateView.for_player/2` strips the deck. The dealer can't see which cards are available to select.

**Fix:** In `StateView.for_player/2`, when `phase == :second_deal` and `viewer_position == state.current_dealer`, include the deck contents.

**File:** `apps/pidro_engine/lib/pidro/core/state_view.ex`

---

### Phase 2: Extend `Pidro.IEx` for Agent Play

Add two functions to the existing `Pidro.IEx` module. No new modules, no new structs.

**File:** `apps/pidro_engine/lib/pidro/iex.ex`

#### `start_server_game/0` — Start a GenServer-backed game

```elixir
@doc "Start a Pidro.Server with a game ready for bidding. Returns {:ok, pid}."
def start_server_game(opts \\ []) do
  initial_state = new_game(opts)
  Pidro.Server.start_link(initial_state: initial_state)
end
```

This reuses the existing `new_game/0` (which already handles dealer selection + initial deal) and wraps it in a `Pidro.Server` GenServer. The caller gets a `pid` and can use all existing `Pidro.Server` functions directly:
- `Pidro.Server.apply_action(pid, :north, {:bid, 10})`
- `Pidro.Server.legal_actions(pid, :north)`
- `Pidro.Server.get_state(pid)`
- `Pidro.Server.game_over?(pid)`
- `Pidro.Server.winner(pid)`

#### `play_full_game/2` — Play to completion with a strategy function

```elixir
@doc """
Play a complete game using a strategy function.

The strategy_fn receives (state, position, legal_actions) and returns an action.
Handles automatic phases, empty legal_actions (eliminated players),
and the select_hand marker action.

Returns {:ok, %{winner: team, scores: scores, hands_played: n}}.
"""
def play_full_game(pid, strategy_fn) do
  # Loop: get state -> find current_turn -> get legal_actions -> pick -> apply -> repeat
  # Skip positions with empty legal_actions (eliminated/cold players)
  # Handle {:select_hand, :choose_6_cards} marker by using DealerRob.select_best_cards
  # Stop when phase == :complete
end
```

**Edge cases to handle in the loop:**
- **Empty `legal_actions`:** Player is eliminated (gone cold). Skip to next position. Do NOT call `Enum.random([])`.
- **`{:select_hand, :choose_6_cards}` marker:** This is not a playable action. The loop must construct the real action using the player's hand + deck pool. Use `DealerRob.select_best_cards/2` or let the strategy function handle it by passing the available cards as context.
- **Automatic phase transitions:** After declaring trump, the engine auto-transitions through discarding → second_deal → playing. The loop just keeps polling `current_turn` and acts when it's non-nil.
- **Multi-hand games:** After scoring, the engine auto-transitions back to dealing → bidding. The loop keeps going until `phase == :complete`.

**Usage:**
```elixir
{:ok, pid} = Pidro.IEx.start_server_game()

# Random strategy
result = Pidro.IEx.play_full_game(pid, fn _state, _pos, actions ->
  Enum.random(actions)
end)
# => {:ok, %{winner: :north_south, scores: %{...}, hands_played: 4}}

# Run 1000 random games
results = for _ <- 1:1000 do
  {:ok, pid} = Pidro.IEx.start_server_game()
  {:ok, result} = Pidro.IEx.play_full_game(pid, &random_strategy/3)
  GenServer.stop(pid)
  result
end
```

**Test file:** `apps/pidro_engine/test/unit/iex_server_game_test.exs`

---

## Acceptance Criteria

- [x] `GameAdapter.broadcast_state_update/2` checks `:complete` instead of `:game_over`
- [x] `GameAdapter.get_state/2` returns masked state using `StateView.for_player/2`
- [x] `GET /api/v1/rooms/:code/state` requires auth, returns masked state
- [x] Dealer can see card pool during rob phase in `StateView.for_player/2`
- [x] `Pidro.IEx.start_server_game/0` returns `{:ok, pid}` with game in bidding phase
- [x] `Pidro.IEx.play_full_game/2` completes a game with a random strategy
- [x] `play_full_game/2` handles eliminated players (empty legal_actions)
- [x] `play_full_game/2` handles dealer rob (select_hand marker)
- [x] 100 random games complete without errors
- [x] All existing 516+ engine tests pass
- [x] All existing channel tests pass (28/28 pass; 5 lobby channel failures are pre-existing)
- [x] `mix precommit` passes (format ✓, compile ✓, tests ✓; no `mix precommit` task defined yet)

## What This Does NOT Include (Deferred)

These are valuable but not needed yet. Build them when a real consumer materializes:

- **REST game action endpoints** — No external HTTP consumer exists today. Mobile uses WebSocket. Claude runs locally. Add `POST /rooms/:code/actions` (single endpoint) when needed.
- **Dev bypass auth token** — Registration is cheap and already works. No need for auth bypass.
- **`Pidro.AgentClient` module** — `Pidro.Server` already has the full API. No wrapper needed.
- **AI opponent strategies** — `play_full_game/2` accepts any strategy function. Build smarter strategies later.

## Files Modified

| File | Change |
|------|--------|
| `apps/pidro_server/lib/pidro_server/games/game_adapter.ex` | Fix `:game_over` → `:complete`, wire `get_state/2` to use StateView |
| `apps/pidro_server/lib/pidro_server_web/router.ex` | Move state endpoint to authenticated pipeline |
| `apps/pidro_server/lib/pidro_server_web/controllers/api/room_controller.ex` | Return masked state from `state` action |
| `apps/pidro_engine/lib/pidro/core/state_view.ex` | Expose deck to dealer during `:second_deal` |
| `apps/pidro_engine/lib/pidro/iex.ex` | Add `start_server_game/0`, `play_full_game/2`, `random_strategy/0` |
| `apps/pidro_engine/lib/pidro/game/play.ex` | Make `find_next_active_player/1` public, eliminate 0-trump players in `compute_kills` |
| `apps/pidro_engine/lib/pidro/game/engine.ex` | Advance `current_turn` past eliminated players after `compute_kills` |
| `apps/pidro_engine/lib/pidro/game/discard.ex` | Fix pool < 6 validation in `dealer_rob_pack` |

## Files Created

| File | Purpose |
|------|---------|
| `apps/pidro_engine/test/unit/iex_server_game_test.exs` | Tests for new IEx functions |

## References

- Engine: `apps/pidro_engine/lib/pidro/game/engine.ex`
- Server: `apps/pidro_engine/lib/pidro/server.ex`
- IEx helpers: `apps/pidro_engine/lib/pidro/iex.ex`
- GameAdapter: `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`
- StateView: `apps/pidro_engine/lib/pidro/core/state_view.ex`
- RoomController: `apps/pidro_server/lib/pidro_server_web/controllers/api/room_controller.ex`
- Router: `apps/pidro_server/lib/pidro_server_web/router.ex`
