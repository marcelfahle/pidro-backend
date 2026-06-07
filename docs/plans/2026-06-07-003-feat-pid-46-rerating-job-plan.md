---
title: "feat: Rerating job — replayable ratings from game history"
type: feat
status: active
date: 2026-06-07
linear: PID-46
origin: docs/ratings-player-profiles/research/PID-46-rerating-job.md
---

# feat: Rerating job — replayable ratings from game history

## Overview

PID-44 shipped the `player_profiles` rating columns (`rating_mu`, `rating_sigma`,
`rating_games_count`) and the completion seam `Profiles.apply_completed_game/2`.
PID-45 shipped the pure estimator `PidroServer.Rating` (`default/0`, `rate/2`,
`ordinal/1`). Nothing yet computes ratings from games.

PID-46 delivers the **batch/replay** half of the rating system:

1. **The shared per-game rating step** — ONE pure function that turns a completed
   game's `player_results` + `winner` + a `prior_ratings` map into an updated
   ratings map. This is the **parity seam**: PID-47 (live wiring) and this rebuild
   both call it, so live and replayed ratings are identical by construction.
2. **`rerate_all/0`** — deterministic wipe-and-recompute of every profile's rating
   from the full `game_stats` history, in a fixed total order, seeded from
   `Rating.default/0`. Idempotent: re-running gives byte-identical results.
3. **`rerate_incremental/0`** — apply only games completed since the last run,
   using the current stored profile ratings as priors, then advance a watermark.
4. A `rating_state` singleton table (one tiny migration) holding the watermark.
5. A `mix pidro.rerate` task with `--all` / `--incremental` flags.

The parity-with-live acceptance reduces to four invariants, all guaranteed here:
(a) same per-game function, (b) same game ordering, (c) same starting defaults
(`Rating.default/0`), (d) same rated-game predicate. PID-46 owns all four; PID-47
inherits them by calling the same shared step.

## Non-Goals (owned by other tickets)

- **Live completion wiring (PID-47).** Calling the shared step from inside
  `Profiles.apply_completed_game/2` / the `Stats` write transaction, loading and
  persisting the four players' ratings per completed game, and advancing the
  watermark on the live path are **PID-47**. PID-46 ships the shared step as a pure,
  reusable function and documents the contract; it does NOT change the live path.
- **The authoritative bot/guest/abandoned POLICY (PID-47).** PID-46 implements the
  minimal honest `rated_game?/1` ("exactly 4 distinct valid-UUID `player_results`,
  two per team"). PID-47 may refine the predicate (e.g. exclude games with any
  `:abandoned`/`:substitute` seat, or guest seats). It is a **shared predicate**:
  both paths must use the same one, so when PID-47 refines it, the rebuild's
  rated-game set tracks the live set automatically.
- **Lifetime counters (PID-44).** `games_played`/`wins`/`losses` and their rebuild
  (`rebuild_from_history/1`, `rebuild_all/0`) are untouched. Rating replay is a
  **separate global ordered pass**; it does not fold into the order-agnostic counter
  rebuild (they have different iteration shapes — set-membership vs ordered replay).
- **The estimator math (PID-45).** We call `Rating.rate/2` as-is.
- **Tiers/veteran/playstyle/heritage.** Untouched.

## The shared per-game rating step (the parity seam)

A new pure function in `PidroServer.Profiles` (no new module — it lives beside the
existing completion logic and is the single thing PID-47 imports):

```elixir
@type rating :: {float(), float()}     # {mu, sigma}, as PidroServer.Rating

@doc """
Pure per-game rating update. Given one game's `player_results` map and `winner`,
plus a `prior_ratings` map `%{user_id => {mu, sigma}}` for the participating users,
returns `{:rated, updated_ratings}` where `updated_ratings` is `prior_ratings` with
the (up to four) participants replaced by their new `{mu, sigma}`; or `:unrated` if
the game does not satisfy `rated_game?/1`.

Pure: no DB. Tolerates atom- or string-keyed JSONB `player_results`. Missing priors
default to `Rating.default/0`. The caller owns where priors come from (rebuild: an
in-memory accumulator; PID-47: the players' stored profile rows).
"""
@spec rate_game(player_results :: map(), winner :: atom() | String.t(),
                prior_ratings :: %{optional(String.t()) => rating()}) ::
        {:rated, %{optional(String.t()) => rating()}} | :unrated
def rate_game(player_results, winner, prior_ratings)
```

Behavior:

- **`rated_game?/1`** (the predicate; private here, but factored so PID-47 can
  reuse/refine it): a game is rated iff `player_results` has **exactly 4 distinct
  valid-UUID keys** (`Ecto.UUID.cast/1` filter, dropping legacy ids like
  `"dev_host"`), split **2 per team** by each entry's `team` field. Anything else
  (3-human + bot, malformed, `nil` `player_results`) → `:unrated`. This is the
  "started 4 distinct human seats, both teams populated" rule from the research.
  Document above the function that PID-47 owns the final policy and may tighten it.
- **Team grouping:** group the 4 entries by their `team` value, tolerating both
  atom (`:north_south`) and string (`"north_south"`) — exactly as the existing
  `Stats`/`Profiles` helpers do. Reuse the stored `team`; do not re-derive from
  position. Normalize `winner` to a string for the comparison.
- **Estimator call:** build `winners`/`losers` as lists of `{mu, sigma}` pulled
  from `prior_ratings` (defaulting absent users to `Rating.default/0`), **winning
  team first**, call `PidroServer.Rating.rate(winners, losers)`, then zip the
  returned `%{winners:, losers:}` back onto the same user ids (order preserved by
  `rate/2`) to produce the updated map.
- **Keys:** keep user-id keys exactly as they appear in `player_results` (string
  after a JSONB round-trip). The rebuild and PID-47 both key their accumulator /
  load by the same string ids, so no normalization needed beyond UUID validation.
- **Purity:** no `Repo`, no logging that depends on DB. This is the property that
  makes parity testable in isolation and makes both callers trivially consistent.

## From-scratch rebuild (`rerate_all/0`)

```elixir
@spec rerate_all() :: {:ok, %{profiles: non_neg_integer(), games: non_neg_integer()}}
def rerate_all()
```

Algorithm:

1. **Reset.** `Repo.update_all(PlayerProfile, set: [rating_mu: dmu, rating_sigma:
   dsig, rating_games_count: 0])` where `{dmu, dsig} = Rating.default/0`. This wipes
   every existing profile's rating to the canonical default **from `Rating.default/0`**
   (8.333333…, NOT the rounded 8.333 schema default) so replayed values and the
   accumulator seed are bit-identical — closes research Open Question 6. (We reset
   only rating columns; counters/veteran/etc. are left alone.)
2. **Query all games in deterministic total order:**
   ```elixir
   from(gs in GameStats, order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id])
   ```
   `completed_at` is the domain key; `inserted_at` then `id` make the order **total
   and stable** (same input rows → same order) even for same-second ties. Same order
   the live path applied games in, up to same-second ties (acceptable — see Cursor).
3. **Fold with an in-memory accumulator** `acc = %{user_id => {mu, sigma}}`, seeded
   empty (each newly-seen user defaults to `Rating.default/0` inside `rate_game/3`),
   plus a `counts = %{user_id => integer}` for `rating_games_count`:
   - For each game, call `rate_game(player_results, winner, acc)`.
   - On `{:rated, updated}`: `acc = updated`; bump `counts` for each of the 4
     participants (`Map.update(counts, uid, 1, &(&1 + 1))`).
   - On `:unrated`: leave `acc` and `counts` untouched (the game contributes
     nothing — bot/3-human games never move ratings).
   - Track the **last game's** `{completed_at, inserted_at, id}` to seed the cursor.
4. **Persist** the final `acc` + `counts`. Per-user `Repo.update`/`update_all`
   keyed on `user_id`, wrapped in a single `Repo.transaction`. Only persist users
   that appear in `acc` (untouched-default users already hold the reset default and
   `count 0`, so writing them is a no-op — skip them). A `{mu, sigma}` write is a
   read-modify-write **overwrite**, NOT an `inc:`, so it cannot reuse the counter
   path; a targeted `update_all(set:)` per user is the simplest correct write.
5. **Advance the cursor** to the last processed game's tuple (Step 3). On an empty
   history, clear the cursor (and the reset in Step 1 is the whole job).

**Iteration choice — `Repo.all`, not `Repo.stream`.** Per research: the launch DB is
fresh (legacy ~70k accounts are NOT yet imported here, and a full re-rate at that
scale is a one-off ops event, not a hot path). `Repo.all` + `Enum.reduce` is the
smallest correct thing and matches the existing `rebuild_all/0` style; no
`Repo.stream`/cursor-transaction machinery exists in the codebase today (YAGNI).
The whole `rerate_all/0` runs inside one `Repo.transaction` so reset + replay +
persist + cursor advance commit atomically (a crashed re-rate never leaves
half-reset ratings). If volume ever forces streaming, it is a localized change to
this one function with no API impact — note it as a future option, do not build it.

**Idempotency:** Step 1 resets to the same defaults, Step 2 is a deterministic total
order, Step 3 is a pure fold from a fixed seed, Step 4 overwrites absolute values.
Re-running produces byte-identical `rating_mu`/`rating_sigma`/`rating_games_count`.

## Incremental mode (`rerate_incremental/0`)

```elixir
@spec rerate_incremental() :: {:ok, %{games: non_neg_integer()}}
def rerate_incremental()
```

**Watermark mechanism — a singleton `rating_state` table (option a).** Chosen over a
table-free alternative because: (1) `completed_at` is second-precision and non-unique,
so the honest cursor is the full `{completed_at, inserted_at, id}` tuple — a
`max(completed_at)` probe cannot disambiguate same-second boundary games and would
re-process or skip them; (2) there is no other durable place to stash three values;
(3) one row in a tiny table is far simpler and more obviously correct than encoding a
composite cursor into some existing column. The cost is one trivial migration.

Schema `PidroServer.Profiles.RatingState` — single row (enforced by a fixed PK):

| column | type | notes |
|---|---|---|
| `id` | `:integer` PK, fixed value `1` | singleton guard (`check id = 1`) |
| `last_completed_at` | `:utc_datetime` | cursor tuple, part 1 (nullable: no run yet) |
| `last_inserted_at` | `:naive_datetime` | cursor tuple, part 2 (matches `game_stats.inserted_at`) |
| `last_game_id` | `:binary_id` | cursor tuple, part 3 |
| `inserted_at`/`updated_at` | `timestamps()` | |

`rerate_incremental/0` algorithm:

1. Load the cursor row (lazily insert the singleton if absent → no cursor = behaves
   like a full run over all games using current profile ratings as priors).
2. **Query games strictly after the cursor**, in the same total order. Because the
   order key is composite, the "after" filter must be the composite-key comparison,
   not `completed_at > x`:
   ```elixir
   where: gs.completed_at > ^c_at
       or (gs.completed_at == ^c_at and gs.inserted_at > ^c_ins)
       or (gs.completed_at == ^c_at and gs.inserted_at == ^c_ins and gs.id > ^c_id)
   ```
   (When the cursor is null, no `where` — process everything.)
3. **Seed the accumulator from CURRENT profile ratings**, not defaults: load the
   stored `{rating_mu, rating_sigma}` for the users appearing in this batch (lazily
   defaulting unseen users via `rate_game/3`). This is equivalent to continuing the
   `rerate_all/0` accumulator from where it left off — the priors at the cursor are
   exactly the persisted post-cursor-game ratings.
4. Fold the batch through `rate_game/3` exactly as in `rerate_all/0`, accumulating
   `{mu, sigma}` deltas and per-user **increments** to `rating_games_count` (here we
   `inc:` the count because we are extending, not recomputing from zero).
5. Persist updated `{mu, sigma}` (overwrite) + `rating_games_count` (increment),
   then **advance the cursor** to the last processed game (no-op if the batch was
   empty). All inside one `Repo.transaction`.

**Documented assumptions:** incremental mode assumes **monotonic `completed_at`
arrival** — games are written in roughly completion order, so "after the cursor" is
the genuinely-new set. If a game arrives out of order (a backfill with an old
`completed_at`, or a same-second tie that sorts before the cursor), incremental will
skip it. The **full `rerate_all/0` is the source of truth** and repairs any such
drift — it re-sorts and replays everything. This is the same drift-then-rebuild
contract PID-44's counters already use; we do not add out-of-order detection.

`rerate_all/0` resets the cursor to its last processed game (Step 5 above), so
running `--all` then `--incremental` processes zero new games — the two modes meet
exactly at the watermark.

## Mix task

**Add a new task `mix pidro.rerate`** (do NOT overload `pidro.rebuild_profiles`,
which is the order-agnostic counter repair — different concern, different
semantics). Mirrors the existing task pattern (`use Mix.Task`, `@shortdoc`,
`@moduledoc` with usage, `Mix.Task.run("app.start")` first, `Mix.shell().info/1`).

Usage:

```bash
mix pidro.rerate --all          # wipe + recompute every rating from history
mix pidro.rerate --incremental  # apply only games since the last run
```

- Exactly one of `--all` / `--incremental` required (default to `--all` with an
  info message if neither given, or print usage — decide: **require one explicitly**,
  print usage and exit otherwise; safest given `--all` is destructive).
- `--all` → `Profiles.rerate_all/0`, print `{profiles, games}` counts.
- `--incremental` → `Profiles.rerate_incremental/0`, print games applied.
- Parse with `OptionParser.parse(args, strict: [all: :boolean, incremental: :boolean])`.

## Test Plan (ExUnit)

`PidroServer.RerateTest` — `apps/pidro_server/test/pidro_server/profiles/rerate_test.exs`
`use PidroServer.DataCase, async: true`. User ids via `Ecto.UUID.generate()`. Seed
`game_stats` rows through the **real `Stats.save_game_result/1`** path (so
`player_results` round-trips to string-keyed JSONB — the realistic shape). A local
helper `complete_game(team_ids, winner, completed_at)` builds a 4-seat
`player_results`, inserts the row, and (for the live simulation) applies the shared
step to profiles read-modify-write. Float comparisons via `assert_in_delta` with a
tight delta (e.g. `1.0e-9`) since both paths run the identical estimator.

### `describe "rate_game/3" (pure)`
- 4-human 2v2 game → `{:rated, map}`; winners' μ up, losers' μ down, all σ shrink
  vs the priors; non-participant priors in the map are untouched.
- missing prior for a user defaults to `Rating.default/0` before rating.
- tolerates string-keyed JSONB `player_results` AND atom-keyed in-memory maps.
- string vs atom `winner` ("north_south" vs `:north_south`) both select the same
  winning team.
- **unrated:** 3 human + 1 bot (3 keys) → `:unrated`; non-UUID key present (e.g.
  `"dev_host"`) dropped, leaving 3 valid → `:unrated`; `player_results == nil` →
  `:unrated`; 4 humans all on one team (impossible-but-defensive) → `:unrated`.
- determinism: same inputs twice → `==`.

### `describe "rerate_all/0" (parity — acceptance c)`
- **Parity with live:** insert N (≥ 6) completed games in known completion order;
  separately simulate "live" by folding the shared step over profiles read-
  modify-write per game in completion order (seeding each profile lazily at
  `Rating.default/0`); snapshot every profile's `{rating_mu, rating_sigma,
  rating_games_count}`. Then `rerate_all/0`. Assert per-profile equality
  (`assert_in_delta` on μ/σ, `==` on count) for every user. **This is acceptance (c).**
- **Idempotency:** run `rerate_all/0` twice; second run yields identical μ/σ/count
  for every profile.
- **Reset semantics:** pre-corrupt a profile's `rating_mu`/`rating_games_count` to
  garbage, run `rerate_all/0`, assert it is overwritten to the replayed value (and
  a user with zero rated games is reset exactly to `Rating.default/0`, count 0).
- **Deterministic ordering under same-second ties:** insert ≥ 3 games sharing one
  `completed_at` (distinct `inserted_at`/`id`); `rerate_all/0` twice → identical
  results (the total order is stable, so ties resolve the same way both runs).
- **Unrated games leave ratings untouched:** a mix of rated (4-human) and unrated
  (3-human/bot) games; only the 4-human games move ratings and bump
  `rating_games_count`; users who only appear in unrated games keep default rating
  and count 0.
- Returns `{:ok, %{profiles: _, games: _}}` with sane counts.

### `describe "rerate_incremental/0"`
- **incremental == full:** seed games A; `rerate_all/0`; seed more games B (later
  `completed_at`); `rerate_incremental/0`. Snapshot. Separately, fresh DB with A+B,
  `rerate_all/0`. Assert identical μ/σ/count for every profile. (The headline
  incremental-correctness test.)
- empty batch: with the cursor at the latest game, `rerate_incremental/0` applies
  0 games and changes nothing.
- first-ever incremental (null cursor) processes all games, equivalent to `all`.
- cursor advance: after a run, the `rating_state` row holds the last processed
  game's `{completed_at, inserted_at, id}`.
- composite-cursor boundary: two games share the cursor's `completed_at` but sort
  after it by `inserted_at`/`id`; assert they ARE picked up (not skipped by a naive
  `completed_at >` filter).
- `--all` resets the cursor: `rerate_all/0` then `rerate_incremental/0` → 0 games.

### Mix task (light)
- Optional: a thin test (or doctest-style) that `--all` and `--incremental` invoke
  the right context function. Kept minimal — logic is tested at the context level.

## Implementation Checklist (ordered, each independently verifiable)

1. **Migration** — `..._create_rating_state.exs`: singleton `rating_state` table
   (id PK fixed to 1 via check constraint, three nullable cursor columns,
   timestamps). `mix ecto.migrate` up/down round-trips.
2. **`RatingState` schema** — `player_profiles/rating_state.ex` (or
   `profiles/rating_state.ex`), binary_id-style conventions, `changeset/2`.
   Verifiable: insert/update the singleton in `iex`.
3. **Shared step** — add `Profiles.rate_game/3` + private `rated_game?/1` +
   team-grouping helper (reuse atom/string tolerance from existing helpers).
   Verifiable by the `rate_game/3` pure tests (no DB needed for these).
4. **`rerate_all/0`** — reset → ordered `Repo.all` fold → persist → cursor advance,
   all in one `Repo.transaction`. Verifiable by parity + idempotency + reset +
   ordering + unrated tests.
5. **`rerate_incremental/0`** — load cursor, composite-key `where`, seed from
   current profiles, fold, persist (overwrite μ/σ, inc count), advance cursor.
   Verifiable by incremental==full + boundary + empty-batch tests.
6. **Mix task** — `mix pidro.rerate --all|--incremental`. Verifiable manually +
   light test.
7. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer, credo
   all green.

## Files to Create / Modify

**Create:**
- `apps/pidro_server/priv/repo/migrations/20260607010000_create_rating_state.exs`
  (timestamp after `20260607000000_create_player_profiles`).
- `apps/pidro_server/lib/pidro_server/profiles/rating_state.ex` — singleton schema.
- `apps/pidro_server/lib/mix/tasks/pidro.rerate.ex` — `mix pidro.rerate` task.
- `apps/pidro_server/test/pidro_server/profiles/rerate_test.exs` — full suite above.

**Modify:**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` — add `rate_game/3`
  (public, the parity seam), private `rated_game?/1` + team-grouping helper,
  `rerate_all/0`, `rerate_incremental/0`, cursor load/advance helpers, and
  `alias PidroServer.{Rating, Profiles.RatingState}`.

## Acceptance Criteria

- [ ] `Profiles.rate_game/3` is pure (no DB), tolerates atom/string `player_results`
      and atom/string `winner`, returns `{:rated, map}` for 4-distinct-human 2v2
      games and `:unrated` otherwise, defaulting missing priors to `Rating.default/0`.
- [ ] `rerate_all/0` wipes every profile's rating to `Rating.default/0`, replays all
      games in `[asc: completed_at, asc: inserted_at, asc: id]` order from a default
      seed, persists final μ/σ + `rating_games_count`, and is idempotent (acceptance a).
- [ ] `rerate_incremental/0` applies only games after the stored composite cursor,
      using current profile ratings as priors, then advances the cursor (acceptance b).
- [ ] **Parity (acceptance c):** sequential live application of `rate_game/3` and a
      from-scratch `rerate_all/0` produce identical μ/σ/`rating_games_count` for every
      profile — proven by test.
- [ ] `rerate_all/0` then `rerate_incremental/0` applies zero new games (modes meet
      at the watermark).
- [ ] Unrated (bot / 3-human) games leave ratings and `rating_games_count` untouched.
- [ ] `mix pidro.rerate --all|--incremental` works; counter rebuild
      (`pidro.rebuild_profiles`) is untouched.
- [ ] The bot-seat policy is the minimal shared `rated_game?/1`; PID-47 can refine
      it via the same shared predicate. PID-46 does not change the live path.
- [ ] `mix precommit` green.

## Dependencies & Risks

- **Upstream:** PID-44 (profile columns + completion seam), PID-45 (`Rating`).
- **Downstream:** PID-47 imports `Profiles.rate_game/3` and `rated_game?/1` for the
  live path and advances the same cursor — parity holds by shared code.
- **Risk — same-second ties / out-of-order arrival.** Incremental can skip an
  out-of-order or boundary-tie game; mitigated by the composite cursor (boundary
  ties within the cursor second are still picked up) and by `rerate_all/0` being the
  authoritative repair. Documented assumption, not a bug.
- **Risk — default seed mismatch.** Replay seeds from `Rating.default/0`
  (8.333333…) while the schema column default is rounded `8.333`; the Step-1 reset
  writes `Rating.default/0` so replayed and reset values match exactly (Open Q 6).
- **Risk — volume.** `Repo.all` over full history is fine for the fresh launch DB; a
  future large legacy import may want `Repo.stream` — a localized, API-preserving
  change to `rerate_all/0` only. Not built now (YAGNI).

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex:100-163` —
  `apply_completed_game/2`, `rebuild_from_history/1`, `rebuild_all/0`, win helpers
  (string/atom tolerance to reuse in `rate_game/3`).
- `apps/pidro_server/lib/pidro_server/rating.ex` — `default/0`, `rate/2`, `ordinal/1`.
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-344,406-454` —
  `save_completed_game/4`, `build_result/3`, `team_for_position/1` (team mapping).
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex` — `GameStats` schema
  (`completed_at :utc_datetime`, `inserted_at` plain `timestamps()`, `id` UUID).
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:30-33` — rating
  columns the job persists.
- `apps/pidro_server/lib/mix/tasks/pidro.rebuild_profiles.ex` — mix task pattern.
- `apps/pidro_server/test/support/data_case.ex` — DB test pattern.
- `apps/pidro_server/priv/repo/migrations/20260607000000_create_player_profiles.exs`
  — migration conventions.

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-46-rerating-job.md](../ratings-player-profiles/research/PID-46-rerating-job.md)
- **Linear issue:** PID-46
