---
date: 2026-06-07
ticket: PID-51
status: complete
title: Playstyle — Aggression Meter + average winning bid — data availability for the bidding-win-rate needle
---

# PID-51 — Playstyle meter: research

## Summary

The needle the ticket wants (Careful→Aggressive, driven by **bidding-win rate** =
share of bidding rounds where the player wins the bid) needs, per human player,
the count of bidding rounds they participated in and the count they WON, plus the
amounts of the bids they won (for the average-winning-bid stat).

Key findings:

- **`round_scores` / `game_play_data` do NOT exist in Pidro 2.** A case-insensitive
  grep of the whole worktree for `round_scores`, `game_play_data`, `round_score`,
  `game_play`, `play_data` returns **zero hits** (excluding `_build`/`deps`). These
  are **legacy Pidro 1 names** (the ticket's "round JSON" with bidder + bid per
  round). Pidro 2 is event-sourced, not round-JSON-sourced.
- **Persisted bid data is exactly ONE number per game.** `game_stats` stores
  `bid_amount` (integer) + `bid_team` (string) — the **last hand's winning bid**,
  derived from the live `GameState.highest_bid` at save time. There is **NO
  per-round, per-hand, or per-player bid data persisted anywhere**.
- **The live `GameState.events` log is the only place the full bidding history
  survives.** `events` is appended-only and is **never reset across hands** (the
  new-hand reset list at `engine.ex:667-684` resets `bids`/`highest_bid` but NOT
  `events`). Each hand contributes one `{:bid_made, position, amount}` per bidding
  action and one `{:bidding_complete, position, amount}` (the winning seat+amount).
  So at completion we can reconstruct every hand's winning bidder + amount.
- **Events carry SEAT positions (`:north/:east/:south/:west`), not user_ids.** The
  seat→user_id mapping lives in `room.seats` (`%{position => %Seat{user_id: …}}`),
  which `save_completed_game/4` already receives as `room.seats`. Mapping
  `bidding_complete` position → `room.seats[position].user_id` yields the winning
  player; iterating winners per hand gives per-player won-bid counts and amounts.
- **Profile accumulators already exist (PID-44):** `playstyle_bidding_wins`,
  `playstyle_bidding_attempts`, `avg_winning_bid_sum`, `avg_winning_bid_count`
  (all integer, default 0, all cast in the changeset). `get_profile_for_screen/1`
  already surfaces `avg_winning_bid` (derived `sum/count`) and the two playstyle
  counters; the needle math itself is not yet computed.
- **Cleanest rebuildable persistence:** a per-player bidding-facts JSONB map on
  `game_stats` (mirroring the existing `player_results`/`final_scores` `:map`
  columns), populated by the writer from `game_state.events` + `room.seats` at save
  time. Without persisting these facts, REBUILD (`rebuild_from_history/1`) cannot
  reproduce them — events live only in memory and are gone once the game GenServer
  dies.

## `round_scores` / `game_play_data` (legacy vs Pidro 2)

**Pidro 2:** Do not exist. Whole-worktree grep:

```
grep -rni "round_scores\|game_play_data\|round_score\|game_play\|play_data" \
  --include=*.ex --include=*.exs --include=*.heex .   # → 0 hits
```

These are **legacy Pidro 1** column/JSON names. The ticket's description ("bidder +
bid live in the round JSON", data from `round_scores`/`game_play_data`) describes
the **Pidro 1** persistence shape, not Pidro 2. Pidro 2 replaced per-round JSON
with an event-sourced in-memory log (`GameState.events`) and an end-of-game
aggregate row (`game_stats`). (Legacy `pidro_api` was not opened in this pass; the
legacy round-JSON shape is documented here only as the ticket-implied source for
PID-53 migration context.)

## Persisted bid data (game_stats) — one number, last hand only

`apps/pidro_server/lib/pidro_server/stats/game_stats.ex`:

- `field :bid_amount, :integer` (line 16), `field :bid_team, :string` (line 17).
  Both cast (lines 31-41); validated `bid_amount` 6..14 (line 47), `bid_team` ∈
  `north_south|east_west` (line 46). No other bid-related field. No per-round map.

Derivation at save time — `apps/pidro_server/lib/pidro_server/stats/stats.ex`:

- `save_completed_game/4` calls `bid_info = extract_bid_info(game_state)` (line 305)
  and writes `bid_amount: bid_info.bid_amount, bid_team: bid_info.bid_team` into
  `stats_attrs` (lines 314-315).
- `extract_bid_info/1` (lines 461-477) reads **`game_state.highest_bid`** only:

  ```elixir
  defp extract_bid_info(%{highest_bid: {position, amount}})
       when position in [:north, :east, :south, :west] and is_integer(amount) do
    %{bid_amount: amount, bid_team: team_for_position(position)}
  end
  # …also tolerates %{position: …, amount: …} map form; else %{bid_amount: nil, bid_team: nil}
  ```

`highest_bid` is reset to `nil` at the start of every hand (`engine.ex:671`), so at
game-over it holds **the final hand's winning bid only**. Confirmed: this single
`bid_amount`/`bid_team` pair is the ONLY bid data persisted, and it is neither
per-player nor per-round.

## LIVE bidding events at completion + seat→user mapping

### Event payloads (engine, `apps/pidro_engine/`)

`apps/pidro_engine/lib/pidro/core/types.ex:175-177` defines the event tuples:

```
| {:bid_made, position(), bid_amount()}
| {:player_passed, position()}
| {:bidding_complete, position(), bid_amount()}
```

Emission:

- **`bid_made`** — `apps/pidro_engine/lib/pidro/game/bidding.ex:227`:
  `GameState.update(:events, state.events ++ [{:bid_made, position, amount}])`.
  Carries the **bidder's seat position + bid amount**.
- **`player_passed`** — `bidding.ex:294`: `{:player_passed, position}` (no amount).
- **`bidding_complete`** — emitted by `finalize_bidding/1`,
  `bidding.ex:484-491`: `event = {:bidding_complete, position, amount}` where
  `%GameState{highest_bid: {position, amount}}` — i.e. the **winning seat +
  winning amount** for that hand. Appended to `events` (line 491).
- **`hand_scored`** — `{:hand_scored, team, points}` (`events.ex:323`,
  `types.ex:186`); team-level, not bid data.

All carry **seat positions** (`:north/:east/:south/:west`), never user_ids.

### events is never reset across hands

The new-hand reset (`engine.ex:660-707`, `handle_automatic_phase` for
`:hand_complete`) resets `highest_bid`, `bidding_team`, `bids`, `tricks`,
`hand_points`, etc. (lines 671-683) but **does NOT touch `:events`**. `events` is
appended-only for the whole game. The struct default is `events: []`
(`types.ex:314`, `gamestate.ex:113`). So at completion `state.events` contains the
**ordered bidding history of every hand**: one `bidding_complete` per hand plus the
`bid_made`/`player_passed` actions that led to it.

### Bidding rounds per game (≈ how many)

One bidding round per hand. A hand ends in `:hand_complete` then a new hand begins
unless a team reached `winning_score` (default **62**, `state_machine.ex:385`).
Hands deal ~6-14 points each, so a full game is **roughly 6-12 hands** ⇒ ~6-12
`bidding_complete` events per completed game (variable; no fixed count).

### Seat → user_id mapping at completion

`save_completed_game/4` is called with the live room:
`apps/pidro_server/lib/pidro_server/games/room_manager.ex:1774`:

```elixir
:ok = Stats.save_completed_game(finished_room, winner, scores, game_state)
```

where `game_state` is fetched live just above (lines 1761-1765) via
`GameAdapter.get_state(room_code)` (the `Pidro.Core.Types.GameState`). The room's
`seats` is `%{position => %Seat{}}` and each `Seat`
(`apps/pidro_server/lib/pidro_server/games/room/seat.ex:26-52`) has fields
`position` (`:north|:east|:south|:west`), `occupant_type` (`:human|:bot|:vacant`),
`user_id`, `reserved_for`, `substitute`, `status`. So `room.seats[position].user_id`
maps an event's seat to the human at that seat. (Caveat: a seat that was
**abandoned → bot** mid-game has `user_id: nil` and `reserved_for` set
(`seat.ex:136`), so bids made by the substitute bot under that position are NOT a
human's bids — see Open Questions for attribution policy. `Stats.build_player_results/3`
at `stats.ex:239-257` already encodes the seat-classification policy
(`:played`/`:abandoned`/`:substitute`/skip-bot) we'd reuse.)

### What's computable per human player, per completed game

From `game_state.events` + `room.seats`, for each human-occupied seat position:

1. **bidding rounds participated** = number of hands (count of `bidding_complete`
   events) — every still-seated human is in every hand's bidding. (i)
2. **bidding rounds WON** = count of `bidding_complete` whose `position` maps to
   this player's seat. (ii)
3. **amounts of bids they won** = the `amount` from each such `bidding_complete`
   event (sum + count → average winning bid). (iii)

All three are derivable at save time. They are **NOT** derivable later from the
persisted row unless we persist them (events are in-memory only).

## Profile playstyle columns (PID-44)

`apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:39-43`:

```elixir
# --- Playstyle (PID-51 computes; PID-44 defaults only) ---
field :playstyle_bidding_wins, :integer, default: 0
field :playstyle_bidding_attempts, :integer, default: 0
field :avg_winning_bid_sum, :integer, default: 0
field :avg_winning_bid_count, :integer, default: 0
```

All four are in `@castable` (lines 61-64) and cast by `changeset/2` (line 70). They
are the accumulators the meter reads:

- needle input = `playstyle_bidding_wins / playstyle_bidding_attempts` (bidding-win
  rate; attempts = participations, wins = bids won).
- average winning bid = `avg_winning_bid_sum / avg_winning_bid_count`.

Read seam already exists — `Profiles.get_profile_for_screen/1`
(`profiles.ex:97-99`) already returns `playstyle_bidding_wins`,
`playstyle_bidding_attempts`, and `avg_winning_bid` (computed via the private
`average/2` helper, `profiles.ex:1009-1010`). The clamped 0–1 needle itself is not
yet computed in this read path.

## Completion seam + rebuild + the persistence needed

### Where accumulation hooks

`Profiles.apply_completed_game/4` (`profiles.ex:226-256`) runs inside the
`save_completed_game/4` transaction (`stats.ex:322-337`). It already has
`player_results`, `winner`, `scores` in scope and loops every valid-UUID
participant for counters/XP (lines 234-243) and now returns per-user newly-earned
achievement keys (PID-50). A per-player bidding accumulation would hook **in this
same per-participant loop** (alongside `apply_one/2` and `apply_xp/3`): increment
`playstyle_bidding_attempts` by the player's participated-rounds, `_bidding_wins`
by won-rounds, `avg_winning_bid_sum` by sum-of-won-amounts, `avg_winning_bid_count`
by count-of-won-amounts.

BUT `apply_completed_game/4`'s arguments today (`player_results`, `winner`,
`scores`) **do not include the per-player bidding facts** — those come from
`game_state.events`. Two options the codebase already supports:

- pass a per-player bidding-facts map into `apply_completed_game` (the writer
  computes it from `game_state.events` + `room.seats` before the transaction), OR
- persist the facts on the `game_stats` row first (below) and have
  `apply_completed_game` read them — required anyway for rebuild.

### Rebuild requires persistence on game_stats

`Profiles.rebuild_from_history/1` (`profiles.ex:267-317`) recomputes counters + XP
**purely from persisted `game_stats` rows** (`final_scores`, `player_results`,
`winner`, `player_ids`). It never sees live events. For the playstyle accumulators
to be rebuildable (the PID-44/47 drift-then-rebuild contract), the per-player
bidding facts **must be persisted on `game_stats`**.

### Persistence convention (mirrors existing jsonb maps)

`game_stats` already has two `:map` (JSONB) columns populated from completion-time
data: `final_scores` (the `scores` map) and `player_results`
(`%{user_id => %{participation, result, team, position}}`, built by
`Stats.build_player_results/3`). The mirror for PID-51 is a new JSONB column, e.g.
`player_bidding :map`, shaped as:

```
%{ user_id => %{
     "rounds" => integer,        # bidding rounds participated
     "wins" => integer,          # bids won
     "won_bid_sum" => integer,   # Σ winning bid amounts
     "won_bid_count" => integer  # count (== wins)
} }
```

Conventions to follow (from PID-44/49 migrations + the existing columns):
`add :player_bidding, :map, default: %{}` in a migration mirroring how
`player_results`/`final_scores` are declared; cast in `GameStats.changeset/2`;
write it in `save_completed_game/4`'s `stats_attrs` (lines 310-320) from a new
`build_player_bidding(game_state.events, room.seats)` helper (sibling to
`build_player_results/3`); and have both `apply_completed_game` (live) and
`rebuild_from_history` (reads the persisted map, JSONB string-keyed — reuse the
`Map.get(..) || Map.get(.., to_string(..))` tolerance pattern used throughout
`stats.ex`/`profiles.ex`) populate the accumulators identically. The accumulators
are commutative per-game sums, so the rebuild mirrors the live path exactly (same
property the XP rebuild relies on, `profiles.ex:283-285`).

### save_completed_game already receives the live state (PID-49/50)

Confirmed: call path `room_manager.ex:1774` →
`Stats.save_completed_game(finished_room, winner, scores, game_state)`; signature
`@spec save_completed_game(map(), atom(), map(), map() | nil)` at `stats.ex:298`,
`def save_completed_game(%{code: room_code} = room, winner, scores, game_state \\ nil)`
at line 299. The `game_state` (with `.events`) and `room.seats` are both in scope at
save time — everything the bidding-facts builder needs is already available.

## Meter math + config

### Ticket-specified math

- bidding-win rate `r = wins / attempts` (guard `attempts == 0` → centre/0.5 or
  nil; follow the existing `average/2` `_,0 -> 0.0` guard idiom, `profiles.ex:1009`).
- piecewise-linear clamp to a 0–1 needle: `r ≤ 0.10` → 0.0 (full Careful);
  `r ≥ 0.40` → 1.0 (full Aggressive); centre `r = 0.25` (4-player baseline) → 0.5;
  linear between (two segments: 0.10→0.25 maps 0.0→0.5, 0.25→0.40 maps 0.5→1.0,
  OR a single linear map 0.10→0.40 ⇒ 0.0→1.0 with 0.25 landing at 0.5 — both
  satisfy the three stated anchors since 0.25 is the midpoint of [0.10, 0.40]).
- average winning bid = `avg_winning_bid_sum / avg_winning_bid_count`.

### Config idiom (`Application.get_env` + `@defaults`)

Mirror `PidroServer.Progression` (`apps/pidro_server/lib/pidro_server/progression.ex`):

```elixir
@defaults %{ center: 0.25, low: 0.10, high: 0.40 }          # progression.ex:40-58 analog
def defaults, do: @defaults                                  # progression.ex:256-257
defp config(key) when is_map_key(@defaults, key) do          # progression.ex:259-262
  app_config = Application.get_env(:pidro_server, __MODULE__, [])
  Keyword.get(app_config, key, Map.fetch!(@defaults, key))
end
```

i.e. a module-level `@defaults` map, a public `defaults/0`, and a private
`config/1` that overlays `Application.get_env(:pidro_server, __MODULE__, [])`. This
is the same tunable pattern used by Progression (XP curve/bonuses) and the Rating /
Tier modules.

## Pure-module + test conventions

Per `apps/pidro_server/CLAUDE.md`: "Pure functions over GenServer logic" — the
meter belongs in a pure module (e.g. `PidroServer.Playstyle`) with: needle math
(`needle/1` taking a rate or wins/attempts), the config overlay (`@defaults` +
`config/1`), and a pure `build_player_bidding/2` events→facts reducer (sibling to
the pure `Stats.build_player_results/3`). Tests mirror
`apps/pidro_server/test/pidro_server/progression_test.exs` /
`rating_test.exs` (ExUnit, table-driven over the math anchors + clamp edges:
r=0.0, 0.10, 0.25, 0.40, 1.0, and attempts=0). Run via `mix test` /
`mix precommit` (format, compile, test, dialyzer, credo).

## Open Questions

1. **Abandoned/substitute seat bid attribution.** Bids made by a substitute bot
   under an abandoned human's position carry that seat's position; after
   substitution `seat.user_id` is `nil` and `reserved_for` holds the original
   human. Policy: attribute won bids only to the human who actually bid (i.e. while
   the seat was human), or attribute all of a position's won bids to the
   `reserved_for`/`user_id`? `build_player_results/3`'s seat classification
   (`:played`/`:abandoned`/`:substitute`) is the natural place to align this, but
   it operates on FINAL seat state, while events span the whole game — a player who
   left mid-game still has earlier hands attributed to their position. Needs a
   decision.
2. **attempts==0 needle value.** Centre (0.5) vs nil/“no data” for a player with no
   completed games. The screen read currently returns `0.0` from `average/2` for
   avg_winning_bid; the needle likely wants centre or a "not enough data" sentinel.
3. **Single-player / bot games.** Counters + XP currently run for all games
   (not rated-gated). Should playstyle accumulate from games where the opponents
   were bots? (Bidding-win rate vs bots is not comparable to the 25% 4-human
   baseline the centre is calibrated to.) Likely accumulate only from full-human
   bidding rounds, but undecided.
4. **bid_amount validation range vs avg.** Persisted `bid_amount` is validated
   6..14; the per-hand winning bids in events share that range, so
   `avg_winning_bid` will sit in ~6..14 — confirm the UI expects that scale.
5. **Backfill.** Existing `game_stats` rows have no persisted bidding facts (events
   were discarded). A rebuild can only produce playstyle accumulators for games
   completed AFTER the new column ships; historical rows yield zeroes. Same
   limitation noted for any event-derived persistence.
