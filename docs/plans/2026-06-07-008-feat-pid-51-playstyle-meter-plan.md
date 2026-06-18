---
title: "feat: Playstyle Aggression Meter — bidding-win-rate needle + average winning bid (PID-51)"
type: feat
status: active
date: 2026-06-07
linear: PID-51
origin: docs/ratings-player-profiles/research/PID-51-playstyle-meter.md
---

# feat: Playstyle Aggression Meter (PID-51)

## Overview

PID-51 turns a player's **bidding-win rate** (share of bidding rounds they won the
bid) into a Careful↔Aggressive needle and surfaces their **average winning bid**.
Both read off the `player_profile` accumulators that PID-44 already shipped
(`playstyle_bidding_wins`, `playstyle_bidding_attempts`, `avg_winning_bid_sum`,
`avg_winning_bid_count`) — the columns exist with defaults; PID-51 is the first
ticket to **populate** and **interpret** them.

The math is a tiny **pure module** (`PidroServer.Playstyle`): rate → needle
(clamped 0–1, center 0.25 → 0.5, low 0.10 → 0.0, high 0.40 → 1.0, linear between)
→ label band, plus an `avg_winning_bid` helper. No DB, fully doctested, config-
tunable via the `Progression` `@defaults` + `config/1` idiom.

The data that feeds the accumulators lives only in the live engine
`GameState.events` log (one `{:bidding_complete, position, amount}` per hand) and
is thrown away once the game GenServer dies. So PID-51 adds **one minimal,
rebuildable JSONB column** — `game_stats.player_bidding` — populated at save time
by a pure folder `build_player_bidding(events, seats)` (sibling to the existing
`build_player_results/3`). The completion seam threads this per-game map into
`apply_completed_game` (extending the signature exactly like `scores` was, with a
shim) and folds it into the four accumulators inside the existing transaction;
`rebuild_from_history/1` folds the same map back out of each persisted row. The
accumulators are commutative per-game sums, so **live == rebuild by
construction** — the same property the XP and rating rebuilds already rely on.

This rides the exact seam PID-47/49/50 use: `Profiles.apply_completed_game/4`
(live) + `Profiles.rebuild_from_history/1` (rebuild). Per
`apps/pidro_server/CLAUDE.md`: pure math in a pure module, single source of truth,
minimal persistence, thin wiring.

## Non-Goals (explicit — owned elsewhere)

- **API / channel exposure** of the needle/label/avg bid — **PID-54**.
  `get_profile_for_screen/1` gains the derived fields in-process; wiring them to a
  controller/channel is PID-54.
- **Activating PID-50's dormant four** (`homerun`, `forcer`, `full_house`,
  `unstoppable`) — those need per-*hand* bid+made+points facts. PID-51's
  `player_bidding` map captures only **per-player won-bid counts/sums**, which is
  insufficient for the dormant four. Activating them is their own separable ticket.
- **Legacy `round_scores` / `game_play_data` import** — **PID-53**. Those Pidro-1
  per-round-JSON columns do not exist in Pidro 2 (research §"`round_scores`").
  Mapping the legacy shape into `player_bidding` is PID-53's concern, not this one.
- **Engine changes.** The `events` log already records everything needed; PID-51
  reads it at save time and does not touch `apps/pidro_engine/**`.

## Decisions (decided + justified)

### 1. The pure meter module — `PidroServer.Playstyle`

`apps/pidro_server/lib/pidro_server/playstyle.ex`. Pure, no DB, doctested. Mirrors
the `Progression` tunable idiom (`@defaults` map + public `defaults/0` + private
`config/1` overlaying `Application.get_env(:pidro_server, __MODULE__, [])`).

```
@defaults %{
  center: 0.25,        # 4-player baseline win rate → needle midpoint
  low:    0.10,        # ≤ this → full Careful (0.0)
  high:   0.40,        # ≥ this → full Aggressive (1.0)
  careful_max:    0.34, # needle < this → :careful
  aggressive_min: 0.66  # needle ≥ this → :aggressive; between → :balanced
}
```

**API + typespecs:**

```elixir
@spec bidding_win_rate(non_neg_integer(), non_neg_integer()) :: float() | :insufficient
# attempts == 0 → :insufficient (no completed bidding rounds; screen shows a
# center/neutral needle with a "not enough data" flag). attempts > 0 → wins/attempts.

@spec needle(float() | :insufficient) :: float()   # always in 0.0..1.0
# :insufficient → center (0.5). A float rate is piecewise-linearly mapped + clamped.

@spec label(float()) :: :careful | :balanced | :aggressive
# needle < careful_max → :careful; >= aggressive_min → :aggressive; else :balanced.

@spec avg_winning_bid(non_neg_integer(), non_neg_integer()) :: float() | nil
# count == 0 → nil ("never won a bid"); else sum / count.

@spec defaults() :: map()
```

**Exact linear-map math (the heart of the ticket).** Two segments hinged at the
center, because the ticket fixes THREE anchors (low→0.0, center→0.5, high→1.0) and
center is not necessarily the arithmetic midpoint of [low, high] (it happens to be
for the defaults, but config can move it). A single straight line `low→high ⇒
0.0→1.0` would only honor the center anchor when `center == (low+high)/2`; the
two-segment form honors all three under any config:

```
needle(rate) =
  rate <= low                    -> 0.0
  rate >= high                   -> 1.0
  rate <= center                 -> 0.5 * (rate - low)    / (center - low)
  rate  > center                 -> 0.5 + 0.5 * (rate - center) / (high - center)
```

Clamp the result into `0.0..1.0` defensively (degenerate config where
`center == low` or `center == high` collapses a segment — guard by returning the
boundary 0.0/0.5/1.0 rather than dividing by zero).

**Worked example (defaults low=0.10, center=0.25, high=0.40):**

| rate | branch | computation | needle |
|---|---|---|---|
| 0.00 | `<= low` | — | **0.0** |
| 0.10 | `<= low` | — | **0.0** |
| 0.175 | lower seg | `0.5 * (0.175-0.10)/(0.25-0.10) = 0.5*0.075/0.15` | 0.25 |
| 0.25 | lower seg | `0.5 * (0.25-0.10)/0.15 = 0.5*1.0` | **0.5** |
| 0.325 | upper seg | `0.5 + 0.5*(0.325-0.25)/(0.40-0.25) = 0.5+0.5*0.5` | 0.75 |
| 0.40 | `>= high` | — | **1.0** |
| 1.00 | `>= high` | — | **1.0** |

So the three stated anchors `0.10 / 0.25 / 0.40 → 0.0 / 0.5 / 1.0` hold exactly.

**Label bands** (decided): needle in `0.0..1.0` → `:careful` below `0.34`,
`:aggressive` at/above `0.66`, `:balanced` between. Justification: equal thirds of
the needle range is the simplest defensible split and keeps "center 0.5" squarely
inside `:balanced`; cutoffs are config knobs so copy can be re-tuned without code.

### 2. Persistence — one rebuildable JSONB column `game_stats.player_bidding`

**Decision: add `player_bidding :map` (JSONB), mirroring `player_results` /
`final_scores`.** Without persisting per-player bidding facts, `rebuild_from_history/1`
cannot reproduce the accumulators — `events` live only in memory and are gone once
the game process dies (research §"Rebuild requires persistence"). This is the
minimal capture: per-player counters only, NOT a per-hand log (over-capture we
explicitly avoid — the dormant-four per-hand facts are a separate ticket).

**Shape** (string keys after a JSONB round-trip):

```
%{ user_id => %{
     "attempts"    => integer,  # bidding rounds the seat participated in
     "wins"        => integer,  # bids this seat won (== won-bid count)
     "won_bid_sum" => integer   # Σ winning-bid amounts for this seat
} }
```

Note `wins == won-bid count`, so the average winning bid is `won_bid_sum / wins` —
no separate count field is stored (keeps the map lean; the profile's
`avg_winning_bid_count` accumulator is fed from `wins`).

**`build_player_bidding(events, seats)` — pure folder** (lives in `stats.ex`,
sibling to `build_player_results/3`):

- **Input — events:** the ordered `GameState.events` list. Relevant tuples
  (`apps/pidro_engine/.../types.ex:175-177`):
  `{:bid_made, position, amount}`, `{:player_passed, position}`,
  `{:bidding_complete, position, amount}`. The fold reads **only**
  `:bidding_complete` (the per-hand winner+amount) for wins/sums, and **counts**
  `:bidding_complete` events for the attempts denominator. `events` is appended-
  only across all hands (research §"events is never reset"), so one game's list
  holds one `:bidding_complete` per hand.
- **Input — seats:** `room.seats` = `%{position => %Seat{}}`. Reuse the existing
  seat-classification (`classify_seat/1` in `stats.ex`) to resolve each position to
  the human `user_id` (`:played` / `:abandoned` reserved_for / `:substitute`); bot
  seats with no resolvable user_id are excluded.
- **attempts attribution:** every human-resolved seat participates in **every**
  hand's bidding, so `attempts` for each such user = the number of
  `:bidding_complete` events (the hand count). (A player who left mid-game is still
  attributed to their seat's resolved id for the whole game — the simplest
  defensible rule, and the same FINAL-seat-state attribution `build_player_results/3`
  already uses; documented as such.)
- **wins / won_bid_sum:** for each `:bidding_complete{position, amount}`, resolve
  `position → user_id` via `seats`; if it resolves to a human, increment that
  user's `wins` by 1 and `won_bid_sum` by `amount`. Positions resolving to a bot
  (no user_id) contribute nothing.
- **Output:** the map above, keyed by user_id. Users who participated but never won
  a bid still get a row (`wins: 0, won_bid_sum: 0`) so `attempts` is captured.
- **Tolerant base case:** `build_player_bidding(events, seats)` when `events` is not
  a list, or `seats` not a map, or no `:bidding_complete` present → `%{}` (legacy /
  bot-only / missing — contributes zero on accumulate and rebuild).

**Seat attribution decisions (encoded):**
- `:abandoned` / `:substitute` seats → attribute to the seat's currently-resolved
  `user_id` / `reserved_for` (simplest; aligns with `build_player_results/3`).
- Bot seats (no user_id) → excluded from both attempts and wins.

**Migration** `priv/repo/migrations/20260607030000_add_player_bidding_to_game_stats.exs`,
matching `20260308083652_add_player_results_to_game_stats.exs` exactly:

```elixir
defmodule PidroServer.Repo.Migrations.AddPlayerBiddingToGameStats do
  use Ecto.Migration

  def change do
    alter table(:game_stats) do
      add :player_bidding, :map
    end
  end
end
```

**Schema** `game_stats.ex`: add `field :player_bidding, :map` and include
`:player_bidding` in the `cast/3` list. No validation (free-form per-player map,
same as `player_results`).

### 3. Writer change — `save_completed_game/4`

`save_completed_game/4` already has `game_state` (4th arg, with `.events`) and
`room.seats` in scope (confirmed: `stats.ex:299-308`; call site
`room_manager.ex:1774`). Add, alongside the existing `player_results` build:

```elixir
player_bidding = build_player_bidding(events_of(game_state), room.seats)
```

(`events_of/1` = a tiny guard pulling `game_state.events` when present, else `[]`,
tolerating `game_state == nil`.) Add `player_bidding: player_bidding` to
`stats_attrs`. Then thread it into the profile apply (Decision 4).

### 4. Completion seam — thread `player_bidding` into `apply_completed_game`

**Signature change** (extend exactly like `scores` was added, keep a shim):

```elixir
# new arity-5, default arg preserves existing /4 callers:
def apply_completed_game(player_results, winner, scores, player_bidding \\ %{}, opts \\ [])
```

Keep the existing `apply_completed_game/2` shim delegating with `%{}` scores and
`%{}` bidding. (Mechanically: today's `/4` has `opts` as the 4th arg; inserting
`player_bidding` before `opts` is the same "add a positional fact + keep a shim"
move the plan history shows for `scores`. The `stats.ex` call site updates to pass
`player_bidding` positionally.)

Return value is **unchanged** in shape: still `{:ok, %{user_id => [newly_earned_key]}}`
from PID-50. Playstyle accumulation has no payload to surface here.

**Accumulation — in the existing per-participant loop**, alongside `apply_one/2`
and `apply_xp/3`:

```elixir
apply_playstyle(valid_id, Map.get(player_bidding, user_id) || Map.get(player_bidding, to_string(user_id)))
```

`apply_playstyle/2` (new private, mirrors `apply_one/2`): given the per-user facts
map (string- or atom-keyed tolerant; `nil` → no-op), `Repo.update_all(inc: …)`:

```
playstyle_bidding_attempts += attempts
playstyle_bidding_wins     += wins
avg_winning_bid_sum        += won_bid_sum
avg_winning_bid_count      += wins      # wins == won-bid count
```

**Runs for ALL games incl. single-player / bot-filled.** Justification: playstyle
is *character*, not skill — like XP (PID-49), it ticks everywhere and is NOT behind
`rated_game?/1`. A player who only ever wins bids against bots still has a real
aggression tendency; gating it would leave most early profiles permanently
`:insufficient`. (Bot seats never appear as keys in `player_bidding`, so bots never
pollute a human's accumulators; only the human's own bidding is counted.) This
matches the research recommendation that counters/XP run for every completed game.

All four increments are inside the existing `Repo.transaction` in
`save_completed_game/4` (the same transaction that wraps counters/XP/rating/
achievements), so a rollback un-does playstyle accumulation atomically with the rest.

### 5. Rebuild — `rebuild_from_history/1` folds `player_bidding` back out

`rebuild_from_history/1` already loads the user's ordered `game_stats` rows. Add a
fold that, for each row, reads `game.player_bidding` (string-keyed JSONB; reuse the
`Map.get(map, id) || Map.get(map, to_string(id))` tolerance pattern), extracts this
user's facts (nil / missing row → contributes nothing), and sums:

```
playstyle_bidding_attempts = Σ attempts
playstyle_bidding_wins     = Σ wins
avg_winning_bid_sum        = Σ won_bid_sum
avg_winning_bid_count      = Σ wins
```

Write these four into the same `PlayerProfile.changeset/2` that already sets
`games_played`/`wins`/`losses`/`veteran_xp`/`veteran_level`. (`@castable` already
lists all four playstyle fields — no schema change needed.)

**Parity argument:** the live path adds one game's facts; the rebuild sums the same
facts from each persisted row. Both read the identical per-game `player_bidding`
map (live: just-built; rebuild: the stored copy of that same build). Per-game sums
are commutative and associative, so `live total == rebuild total` by construction —
the same invariant XP rebuild relies on (`profiles.ex:283-285`).

**Historical rows note:** rows written before this column exists (or where events
were unavailable at save) have `player_bidding == nil` and contribute zero — so
their participants show `:insufficient` until they play a post-column game. At fresh
launch this is moot (no pre-column rows). Documented in the moduledoc + plan;
backfill is out of scope (and impossible — discarded events).

### 6. Read off the profile — `get_profile_for_screen/1`

`get_profile_for_screen/1` already returns the raw `playstyle_bidding_wins`,
`playstyle_bidding_attempts`, and `avg_winning_bid`. Add the **derived** view
(keep the raw counters too — internal, harmless):

```elixir
rate   = Playstyle.bidding_win_rate(profile.playstyle_bidding_wins,
                                    profile.playstyle_bidding_attempts)
needle = Playstyle.needle(rate)

# additions to the returned map:
bidding_win_rate:        (rate == :insufficient && nil) || rate,   # nil when no data
aggression_needle:       needle,                                   # 0.0..1.0
aggression_label:        Playstyle.label(needle),                  # :careful|:balanced|:aggressive
aggression_insufficient: rate == :insufficient,                    # "not enough data" flag
avg_winning_bid:         Playstyle.avg_winning_bid(profile.avg_winning_bid_sum,
                                                   profile.avg_winning_bid_count)
```

(`avg_winning_bid` switches from the private `average/2` — which returns `0.0` on
empty — to `Playstyle.avg_winning_bid/2`, which returns `nil` on no won bids; a
genuine "never won a bid" reads as nil, not a misleading 0.0. Confirm the screen
contract tolerates nil; if a numeric is required, keep `average/2`. Default:
nil-on-empty.)

## Test Plan (ExUnit)

### `PidroServer.PlaystyleTest` — `.../playstyle_test.exs`, `async: true`
Pure, table-driven (mirrors `progression_test.exs` / `rating_test.exs`).

- **`bidding_win_rate/2`:** `(0,0) → :insufficient`; `(0,4) → 0.0`;
  `(1,4) → 0.25`; `(2,4) → 0.5`; `(4,4) → 1.0`.
- **`needle/1` anchors + clamps:** `0.10 → 0.0`, `0.25 → 0.5`, `0.40 → 1.0`
  (the three required anchors); below-low `0.0 → 0.0`; above-high `1.0 → 1.0`;
  lower-segment midpoint `0.175 → 0.25`; upper-segment midpoint `0.325 → 0.75`;
  `:insufficient → 0.5` (center). Assert every output is within `0.0..1.0`.
- **`needle/1` under config override** (`Application.put_env` + `on_exit`): move
  `center`/`low`/`high` and assert the three anchors track the new config (proves
  two-segment form honors a non-midpoint center).
- **`label/1` bands:** `0.0 → :careful`, `0.33 → :careful`, `0.34 → :balanced`,
  `0.5 → :balanced`, `0.65 → :balanced`, `0.66 → :aggressive`, `1.0 → :aggressive`;
  band cutoffs follow config overrides.
- **`avg_winning_bid/2`:** `(_, 0) → nil`; `(30, 4) → 7.5`; `(48, 6) → 8.0`.
- **`defaults/0`** returns the documented keys.
- **Degenerate config guard:** `center == low` or `center == high` does not raise
  (returns a clamped boundary value).

### `PidroServer.Stats` — `build_player_bidding/2` (in `stats_test.exs` or a focused file)
`async: true`, pure (no DB).

- **Synthetic events fold:** given `seats` mapping `:north→userA`, `:east→userB`,
  `:south→userC`, `:west→userD` and an `events` list with three
  `:bidding_complete` (e.g. `{:bidding_complete, :north, 7}`,
  `{:bidding_complete, :east, 9}`, `{:bidding_complete, :north, 6}`) plus assorted
  `:bid_made` / `:player_passed` noise → assert `userA = %{"attempts"=>3, "wins"=>2,
  "won_bid_sum"=>13}`, `userB = %{"attempts"=>3,"wins"=>1,"won_bid_sum"=>9}`,
  `userC`/`userD = %{"attempts"=>3,"wins"=>0,"won_bid_sum"=>0}`.
- **Bot seat excluded:** a `:bidding_complete` for a position whose seat resolves to
  a bot (no user_id) contributes to nobody; that position is absent from the map.
- **Abandoned/substitute attribution:** a `:abandoned` (bot, `reserved_for` set)
  seat's position attributes its won bids to `reserved_for`.
- **Tolerant base cases:** `events == nil`, `events == []`, `seats == %{}`,
  no `:bidding_complete` present → `%{}`.

### Accumulation (live) + parity — extend `stats/profile_rollup_test.exs` (`DataCase`)

- **Live accumulation:** complete a game whose `game_state.events` yields known
  per-player wins/attempts/sums; assert each participant's profile shows the
  expected `playstyle_bidding_attempts`, `_wins`, `avg_winning_bid_sum`,
  `avg_winning_bid_count`. A second completed game **adds** to them.
- **Live == rebuild parity (headline guard):** run a scripted sequence of
  completions, snapshot each user's four playstyle accumulators, run `rebuild_all/0`,
  assert the four accumulators are **identical** per user (no drift).
- **Single-player / bot-filled counts:** a game with one human + three bots still
  accumulates the human's bidding facts (attempts == hand count; wins/sum from the
  human's won bids), proving playstyle is NOT rated-gated. Bot seats never appear.
- **Pre-column / nil row contributes zero:** a `game_stats` row with
  `player_bidding == nil` adds nothing on rebuild (no crash, no negative).
- **Transaction atomicity:** a forced changeset failure rolls back playstyle
  accumulation along with the rest (no partial inc).

### `get_profile_for_screen/1` — extend `profiles_test.exs`

- Fresh profile (attempts == 0): `bidding_win_rate == nil`,
  `aggression_insufficient == true`, `aggression_needle == 0.5`,
  `aggression_label == :balanced`, `avg_winning_bid == nil`.
- Populated profile: `bidding_win_rate`, `aggression_needle` (0–1),
  `aggression_label`, and `avg_winning_bid` reflect the accumulators and equal a
  direct `Playstyle.*` call on the same numbers.

## Implementation Checklist (ordered, each independently verifiable)

1. **Migration** `20260607030000_add_player_bidding_to_game_stats.exs`
   (`add :player_bidding, :map`). `mix ecto.migrate`.
2. **Schema** `game_stats.ex`: add `field :player_bidding, :map` + cast it.
3. **Meter module** `playstyle.ex`: `@defaults` + `defaults/0` + `config/1`;
   `bidding_win_rate/2`, `needle/1`, `label/1`, `avg_winning_bid/2`; moduledoc +
   doctests for the three needle anchors and the avg-bid helper.
4. **`build_player_bidding/2`** in `stats.ex` (reuse `classify_seat/1` /
   position→team helpers; pure). Plus `events_of/1` guard.
5. **Write the pure tests** (`playstyle_test.exs`, `build_player_bidding` tests);
   run green before touching the seam.
6. **Writer**: `save_completed_game/4` builds `player_bidding`, adds it to
   `stats_attrs`, and passes it to `apply_completed_game`.
7. **Seam**: extend `apply_completed_game` signature (`player_bidding \\ %{}`,
   keep shims); add `apply_playstyle/2` to the per-participant loop (4 increments,
   in the existing transaction).
8. **Rebuild**: `rebuild_from_history/1` folds `player_bidding` from each row into
   the four accumulators; write them in the existing changeset.
9. **Screen**: `get_profile_for_screen/1` adds `bidding_win_rate`,
   `aggression_needle`, `aggression_label`, `aggression_insufficient`,
   `avg_winning_bid` (via `Playstyle`).
10. **Extend `profile_rollup_test.exs` + `profiles_test.exs`** — live accumulation,
    live==rebuild parity, single-player counts, nil-row, screen fields. Run green.
11. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer,
    credo all green.

## Files to Create / Modify

**Create:**
- `apps/pidro_server/priv/repo/migrations/20260607030000_add_player_bidding_to_game_stats.exs`
- `apps/pidro_server/lib/pidro_server/playstyle.ex` — pure meter module.
- `apps/pidro_server/test/pidro_server/playstyle_test.exs`

**Modify:**
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex` — `player_bidding` field + cast.
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — `build_player_bidding/2`,
  `events_of/1`, writer wiring + pass into `apply_completed_game`; build tests.
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `apply_completed_game` signature + `apply_playstyle/2` in the loop;
  `rebuild_from_history/1` fold; `get_profile_for_screen/1` derived fields; alias
  `Playstyle`.
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` — live + parity.
- `apps/pidro_server/test/pidro_server/profiles_test.exs` — screen additions.
- `config/config.exs` — optional `config :pidro_server, PidroServer.Playstyle, …`
  block (tunable; defaults live in the module so this is optional).

**Explicitly NOT modified:**
- `apps/pidro_engine/**` — the `events` log already records the needed facts.
- `player_profile.ex` schema — the four playstyle columns + casts already exist (PID-44).

## Acceptance Criteria

- [ ] Per-player bidding-win rate → clamped 0–1 needle: center 0.25→0.5,
      ≤0.10→0.0 (Careful), ≥0.40→1.0 (Aggressive), linear between (anchors proven
      by test).
- [ ] Average winning bid surfaced (`won_bid_sum / wins`, nil when never won).
- [ ] Both read off the profile via `get_profile_for_screen/1`.
- [ ] `player_bidding` JSONB column populated at save from `events` + `seats`;
      accumulators fed live AND rebuilt; **live == rebuild parity** test green.
- [ ] Playstyle accumulates for ALL completed games (incl. single-player); bots
      never pollute a human's accumulators.
- [ ] `attempts == 0` → `:insufficient` (center needle + flag); no API exposure,
      no dormant-four activation, no legacy import. `mix precommit` green.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-349` —
  `save_completed_game/4` (has `game_state.events` + `room.seats`),
  `build_player_results/3` + `classify_seat/1` (seat→user policy to reuse),
  `extract_bid_info/1` (last-hand-only baseline this supersedes).
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `apply_completed_game/2..4` (+ shim, per-participant loop, `apply_one/2`,
  `apply_xp/3`), `rebuild_from_history/1`, `get_profile_for_screen/1`,
  `average/2`.
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:39-66` — the four
  playstyle columns + `@castable` (already present, PID-44).
- `apps/pidro_engine/lib/pidro/game/bidding.ex:227,294,484-491` +
  `types.ex:175-177` — `{:bid_made,…}`, `{:player_passed,…}`,
  `{:bidding_complete, position, amount}` emission; `events` never reset across
  hands.
- `apps/pidro_server/lib/pidro_server/games/room/seat.ex` (`user_id`,
  `reserved_for`, `occupant_type`) + `room_manager.ex:1774`
  (`Stats.save_completed_game(finished_room, winner, scores, game_state)`).
- `apps/pidro_server/lib/pidro_server/progression.ex:40-58,256-262` — `@defaults`
  + `config/1` tunable idiom mirrored by `Playstyle`.
- `apps/pidro_server/priv/repo/migrations/20260308083652_add_player_results_to_game_stats.exs`
  — the `alter table … add :map` migration convention to mirror.

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-51-playstyle-meter.md](../ratings-player-profiles/research/PID-51-playstyle-meter.md)
- **Linear issue:** PID-51
