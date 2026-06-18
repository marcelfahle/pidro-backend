---
title: "feat: Player profile + lifetime stats store"
type: feat
status: active
date: 2026-06-07
linear: PID-44
origin: docs/ratings-player-profiles/research/PID-44-player-profile-store.md
---

# feat: Player profile + lifetime stats store

## Overview

Today there is no per-user rollup. Lifetime stats are recomputed on every read by
scanning every `game_stats` row whose `player_ids` array contains the user id
(`PidroServer.Stats.get_user_stats/1`). That works at current scale but it is the
wrong substrate for the ratings / progression program (PID-45..PID-51): rating,
veteran level, XP, playstyle metrics and heritage flags all need a durable per-user
record to live on and to be updated incrementally as games complete.

PID-44 is the **foundation ticket**. It builds:

1. A `player_profiles` table — one row per user, created lazily.
2. A `PidroServer.Profiles` context with get-or-create, fetch-for-screen,
   update-on-completion, and idempotent rebuild-from-history.
3. The lifetime-count rollup (`games_played`, `wins`, `losses`, derived `win%`)
   maintained on game completion and reproducible from `game_stats` history.
4. The integration hook inside `Stats.save_completed_game/4`.

It also lays down — as **columns with sensible defaults only** — the progression
fields that later tickets will compute. PID-44 does NOT write any rating / XP /
level / playstyle / heritage logic. Those columns exist now so later tickets are
pure logic changes with no migration churn.

The profile becomes the "single cheap fetch" that powers the profile screen
(one `Repo.get_by/2` on a unique `user_id` index, no array scans).

## Problem Statement / Motivation

- `get_user_stats/1` does a GIN-array scan + in-memory reduce on every profile view.
- There is nowhere to persist progression state (rating μ/σ, veteran level, XP,
  playstyle counters, heritage flags) that later tickets need.
- The leaderboard code already carries a TODO that "in production you'd want a
  separate leaderboard table" (`stats.ex:191`) — the same pressure.
- We need a record that can be both updated incrementally on completion AND
  rebuilt deterministically from `game_stats` history (idempotency requirement).

## Non-Goals (owned by later tickets)

These are explicitly OUT of scope for PID-44. The columns exist with defaults;
the computation does not.

- **Rating (μ/σ + rating game count):** PID-45 / PID-47 own the OpenSkill-style
  rating math and which games count toward it. PID-44 ships `rating_mu`,
  `rating_sigma`, `rating_games_count` with defaults only.
- **Rating tiers / divisions:** PID-48 derives display tiers from μ/σ. No tier
  column in PID-44 (it's a pure function of rating; do not store).
- **Veteran level + XP:** PID-49 owns the XP curve and level computation.
  PID-44 ships `veteran_level`, `veteran_xp` with defaults only.
- **Heritage flags:** PID-49 owns heritage detection (e.g. classic-account
  migration markers). PID-44 ships `heritage_flags` (JSONB map) defaulting to `{}`.
- **Mastery achievements:** a many-per-user set. This is a SEPARATE table owned by
  **PID-50** (`player_achievements`, one row per earned achievement per user). The
  profile does NOT store achievements — no column, no JSONB list. PID-44 only notes
  the relationship.
- **Playstyle (bidding-win rate + average winning bid):** PID-51 owns the
  per-user playstyle computation. As the research flags, `game_stats` does not
  record which individual user placed the winning bid (only `bid_team`), so PID-51
  may need to either infer it (user's team == `bid_team` == `winner`) or persist
  per-player bid data upstream. That decision belongs to PID-51. PID-44 ships
  `playstyle_bidding_wins`, `playstyle_bidding_attempts`, `avg_winning_bid_sum`,
  `avg_winning_bid_count` with defaults only.
- No API/controller/LiveView changes. Rewiring `get_user_stats/1` consumers
  (`user_controller.ex`, dev LiveViews) onto the profile is a follow-up; PID-44
  keeps `get_user_stats/1` intact so nothing breaks.
- No guest-vs-registered policy enforcement. We create a profile for any user id
  that appears in `player_results` (bots are already excluded upstream). See
  "Bot & Guest Handling".

## Update-vs-Rebuild Decision

**Incremental update on completion, with a separate full-rebuild path for repair.**

Rationale (DHH "smallest thing that works"):

- `save_completed_game/4` is already the single, idempotent (per `room_code`)
  completion hook. A completed game touches at most 4 user profiles. An incremental
  `+1 games_played`, `+1 wins`/`losses` is O(4) and runs inside the same write path.
- Recompute-from-scratch on every completion would re-scan that user's entire
  `game_stats` history per game — exactly the cost we are trying to remove. No.
- BUT incremental counters drift if a write is missed or a bug ships. So we ALSO
  provide `rebuild_from_history/1` (per user) and `rebuild_all/0` (mix task) that
  recompute counters from `game_stats` and overwrite them. This is the idempotent
  source of truth and the acceptance-criterion (b) "can be rebuilt".

**Idempotency of the incremental path:** the increment must NOT run twice for the
same room. We do not add a per-room marker to the profile (that would duplicate
`game_stats`' own idempotency). Instead, the profile update is invoked only from
inside the `nil ->` branch of `save_completed_game/4` (i.e. only when a brand-new
`game_stats` row is actually inserted). Re-running `save_completed_game/4` for an
existing room hits the `%GameStats{} -> :ok` branch and never touches profiles.
This piggybacks on the existing per-`room_code` idempotency rather than inventing
a second one.

**Rebuild parity:** `rebuild_from_history/1` derives the same `games_played /
wins / losses` that the incremental path produced, so for any user the two paths
converge. Win/loss derivation is shared between both paths (one private helper)
to guarantee parity. The rebuild must tolerate JSONB string-keyed `player_results`
maps (see "Win/Loss Derivation").

## Schema

`PidroServer.Profiles.PlayerProfile` — `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex`

Follows house conventions verbatim: `use Ecto.Schema`, binary_id PK,
`@foreign_key_type :binary_id`, `@moduledoc`, `changeset/2` with cast →
validate_required → unique_constraint.

```elixir
defmodule PidroServer.Profiles.PlayerProfile do
  @moduledoc """
  Per-user profile + progression rollup.

  One row per user, created lazily. Holds lifetime play counters (maintained
  incrementally on game completion, rebuildable from game_stats history) plus
  progression columns that later tickets compute (rating, veteran, playstyle,
  heritage). PID-44 only owns the lifetime counters; progression columns ship
  with defaults and are written by PID-45..PID-51.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "player_profiles" do
    # Owner. Loose binary_id (no FK) to mirror game_stats.player_ids, which
    # deliberately has no users FK and whose deletes do not cascade.
    field :user_id, :binary_id

    # --- Lifetime counters (PID-44 owns these) ---
    field :games_played, :integer, default: 0
    field :wins, :integer, default: 0
    field :losses, :integer, default: 0
    # win_rate is DERIVED (wins / games_played) at read time — not stored.
    # first_seen_at derives from users.inserted_at — not stored.

    # --- Rating (PID-45/47 compute; PID-44 defaults only) ---
    field :rating_mu, :float, default: 25.0
    field :rating_sigma, :float, default: 8.333
    field :rating_games_count, :integer, default: 0

    # --- Veteran / XP (PID-49 computes; PID-44 defaults only) ---
    field :veteran_level, :integer, default: 0
    field :veteran_xp, :integer, default: 0

    # --- Playstyle (PID-51 computes; PID-44 defaults only) ---
    field :playstyle_bidding_wins, :integer, default: 0
    field :playstyle_bidding_attempts, :integer, default: 0
    field :avg_winning_bid_sum, :integer, default: 0
    field :avg_winning_bid_count, :integer, default: 0

    # --- Heritage (PID-49 computes; PID-44 defaults only) ---
    field :heritage_flags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @castable [
    :user_id,
    :games_played,
    :wins,
    :losses,
    :rating_mu,
    :rating_sigma,
    :rating_games_count,
    :veteran_level,
    :veteran_xp,
    :playstyle_bidding_wins,
    :playstyle_bidding_attempts,
    :avg_winning_bid_sum,
    :avg_winning_bid_count,
    :heritage_flags
  ]

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @castable)
    |> validate_required([:user_id])
    |> validate_number(:games_played, greater_than_or_equal_to: 0)
    |> validate_number(:wins, greater_than_or_equal_to: 0)
    |> validate_number(:losses, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id)
  end
end
```

Notes on choices (decisive, per Open Questions in research):

- **No `users` FK** (Q1). `game_stats.player_ids` is deliberately a loose array of
  ids with no FK and `delete_user/1` explicitly preserves history. The profile
  follows the same loose-id pattern: `user_id :binary_id`, unique index, no
  `references(:users)`, no cascade. Keeps deletion semantics consistent and avoids
  ordering constraints between user deletion and profile cleanup.
- **`timestamps(type: :utc_datetime_usec)`** (Q4) — match the `User` schema (the
  authoritative account record this row hangs off), not the older `game_stats`
  default. `inserted_at` doubles as the profile's own creation time;
  account-age / first-seen derives from `users.inserted_at` at read time.
- **`win_rate` not stored** — pure function of `wins / games_played`, computed in
  the fetch result. Single source of truth (per `apps/pidro_server/CLAUDE.md`).
- **`avg_winning_bid`** stored as sum + count (not a float) so PID-51 can update it
  incrementally without precision drift; the average is derived on read.
- **`rating_sigma` default 8.333** = 25/3, the standard OpenSkill default σ.
  PID-45 may override; it is just a sensible non-null seed.

## Migration

`apps/pidro_server/priv/repo/migrations/20260607000000_create_player_profiles.exs`
(timestamp is after the latest existing migration `20260424050000`).

```elixir
defmodule PidroServer.Repo.Migrations.CreatePlayerProfiles do
  use Ecto.Migration

  def change do
    create table(:player_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false

      add :games_played, :integer, null: false, default: 0
      add :wins, :integer, null: false, default: 0
      add :losses, :integer, null: false, default: 0

      add :rating_mu, :float, null: false, default: 25.0
      add :rating_sigma, :float, null: false, default: 8.333
      add :rating_games_count, :integer, null: false, default: 0

      add :veteran_level, :integer, null: false, default: 0
      add :veteran_xp, :integer, null: false, default: 0

      add :playstyle_bidding_wins, :integer, null: false, default: 0
      add :playstyle_bidding_attempts, :integer, null: false, default: 0
      add :avg_winning_bid_sum, :integer, null: false, default: 0
      add :avg_winning_bid_count, :integer, null: false, default: 0

      add :heritage_flags, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:player_profiles, [:user_id])
  end
end
```

The unique index on `user_id` is what backs both the "single cheap fetch" and the
get-or-create `on_conflict` race guard.

## Context Module

`PidroServer.Profiles` — `apps/pidro_server/lib/pidro_server/profiles/profiles.ex`

Plain context module, `alias PidroServer.Repo`, `import Ecto.Query, warn: false`,
`alias PidroServer.Profiles.PlayerProfile`. Public functions:

```elixir
@doc "Returns the profile for a user, creating a default row lazily if absent. Race-safe."
@spec get_or_create_profile(binary_id) :: {:ok, PlayerProfile.t()} | {:error, Ecto.Changeset.t()}
def get_or_create_profile(user_id)

@doc "Single cheap fetch for the profile screen: profile row + derived fields (win_rate, first_seen_at, account_age_days, avg_winning_bid). Lazily creates the row."
@spec get_profile_for_screen(binary_id) :: {:ok, map()} | {:error, term()}
def get_profile_for_screen(user_id)

@doc "Applies one completed game to a set of users' profiles. Increments games_played and wins/losses per the per-user result. Called once per newly-inserted game_stats row, inside the Stats write path. Bots are already excluded by the caller."
@spec apply_completed_game(player_results :: map(), winner :: atom() | String.t()) :: :ok
def apply_completed_game(player_results, winner)

@doc "Recomputes a single user's lifetime counters from game_stats history and overwrites them. Idempotent; reproduces what the incremental path would have produced."
@spec rebuild_from_history(binary_id) :: {:ok, PlayerProfile.t()} | {:error, term()}
def rebuild_from_history(user_id)

@doc "Rebuilds every known user's profile from history. Used by the rebuild mix task. Returns the count rebuilt."
@spec rebuild_all() :: {:ok, non_neg_integer()}
def rebuild_all()
```

Behavior detail:

- **`get_or_create_profile/1`**: `Repo.get_by(PlayerProfile, user_id: user_id)` →
  if found return it; else insert a default changeset with
  `Repo.insert(changeset, on_conflict: :nothing, conflict_target: :user_id)` and
  re-`get_by` on `:nothing` (handles the concurrent-insert race against the unique
  index). Mirrors the `record_abandonment/3` `on_conflict: :nothing` pattern
  already in `stats.ex`.

- **`get_profile_for_screen/1`**: calls `get_or_create_profile/1`, then returns a
  map with the stored fields plus derived:
  - `win_rate` = `wins / games_played` (0.0 when `games_played == 0`)
  - `avg_winning_bid` = `avg_winning_bid_sum / avg_winning_bid_count` (0.0 when count 0)
  - `first_seen_at` = `users.inserted_at` (one `Repo.get`), `account_age_days` derived.
  This is the function future API/LiveView consumers call instead of
  `Stats.get_user_stats/1`.

- **`apply_completed_game/2`**: for each `{user_id, result}` in `player_results`,
  `get_or_create_profile/1` then a single targeted `update_all`/changeset increment:
  `games_played + 1`, and `wins + 1` or `losses + 1` based on the shared
  `win?/2` helper. Wrap the per-game application in `Repo.transaction/1` (see
  Integration Point). `player_results` here is the in-memory atom-keyed map built
  by `build_player_results/3` (NOT a JSONB round-trip), so keys/values are atoms.

- **`rebuild_from_history/1`**: query
  `from gs in GameStats, where: ^user_id in gs.player_ids`, then
  `games_played = length`, `wins = Enum.count(games, &win?(&1, user_id))`,
  `losses = games_played - wins`. Overwrite via changeset. Reuses the same
  `win?/2` logic as the incremental path — but the input here is a persisted
  `GameStats` whose `player_results` is **string-keyed JSONB**, so the helper must
  read both atom and string keys (lift the existing `get_player_result/2` /
  position-fallback logic from `stats.ex`).

- **`rebuild_all/0`**: collect the distinct set of user ids from
  `game_stats.player_ids` (unnest/`Enum.uniq`), call `rebuild_from_history/1` for
  each. (At current scale a simple all-rows scan + flatten is fine; no batching.)

## Win/Loss Derivation

The per-user result is already computed upstream and lives in
`player_results[user_id]` as `%{participation, result, team, position}` where
`result` is `:win | :loss` (`build_result/3`, `stats.ex:393`). Both the incremental
and rebuild paths share one private helper in `PidroServer.Profiles`:

```elixir
# Returns true if the user won this game.
defp win?(player_results_or_game, user_id)
```

- **Incremental path** (atom-keyed in-memory map): `player_results[user_id].result == :win`.
- **Rebuild path** (string-keyed JSONB on a `GameStats`): read
  `Map.get(pr, user_id) || Map.get(pr, to_string(user_id))`, then `["result"] == "win"`,
  falling back to the position-vs-`winner` inference exactly as
  `Stats.count_user_wins/2` / `get_player_result/2` already do (handles both
  `:north_south` and `"north_south"` winners, and `:win`/`"win"`). Port that
  string/atom-tolerant logic so rebuild parity holds for historical rows written
  before `player_results` existed.

`losses = games_played - wins` (a non-win recorded game is a loss). Abandoned games
still count as a played game and as a win/loss by team-vs-winner — consistent with
how `get_user_stats/1` counts them today, so the rollup matches the existing screen.

## Integration Point — `Stats.save_completed_game/4`

The hook goes inside the existing `nil ->` branch (new-row path) of
`save_completed_game/4` (`stats.ex:298-331`), AFTER the `game_stats` row is
successfully inserted, so a failed stats insert never produces profile drift.

Current shape:

```elixir
case save_game_result(stats_attrs) do
  {:ok, _stats} ->
    Logger.info("Saved game stats for room #{room_code}")
    :ok
  {:error, changeset} -> ...
end
```

Change to wrap both writes in one transaction and apply profiles on success:

```elixir
result =
  Repo.transaction(fn ->
    case save_game_result(stats_attrs) do
      {:ok, stats} ->
        :ok = Profiles.apply_completed_game(player_results, winner)
        stats
      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end)

case result do
  {:ok, _stats} -> Logger.info("Saved game stats for room #{room_code}"); :ok
  {:error, changeset} -> Logger.error("Failed ... #{inspect(changeset)}"); :ok
end
```

Key points:

- **`player_results`** passed to `apply_completed_game/2` is the SAME in-memory
  atom-keyed map already built two lines above (`build_player_results(...)`), so
  no JSONB round-trip and no re-query. The keys are exactly the recorded user ids.
- **Bots are already excluded** — `build_player_results/3` / `classify_seat/1`
  skip pure bots (`:skip`) and never emit a bot id. `apply_completed_game/2` simply
  iterates whatever `player_results` contains, so bot handling is inherited for
  free. Abandoned humans (recorded under their real id) DO get a profile update,
  matching `get_user_stats/1`.
- **Transaction boundary:** stats insert + all profile increments are atomic.
  Either the game is recorded and all profiles bump, or neither happens (and the
  room is retried / left to the idempotent guard). This keeps counters consistent
  with `game_stats` and makes rebuild parity trivially true.
- **Idempotency:** the whole block is inside `nil ->`. A second
  `save_completed_game/4` for the same `room_code` short-circuits at
  `%GameStats{} -> :ok` and never re-enters this path, so profiles are never
  double-incremented. No new per-room marker needed.
- **New alias:** add `alias PidroServer.Profiles` to `stats.ex`.

`room_manager.ex:1774` (`:ok = Stats.save_completed_game(...)`) is unchanged — the
function still returns `:ok`.

## Bot & Guest Handling

- **Bots:** never users, never in `player_results` (skipped by `classify_seat/1`).
  No profile is created for them. Nothing to do.
- **Guests:** guest users have real `users` rows and appear in `player_ids`, so
  they get profiles like any other user. PID-44 does not special-case them; if a
  later ticket wants to exclude guests from rating, that is a PID-45+ filter on the
  rating column, not a profile-existence rule.
- **Stray non-UUID ids** (e.g. `"dev_host"`): `build_player_results/3` only emits
  ids that came from real seats; the `user_id :binary_id` column will reject a
  non-UUID at insert. In practice these don't reach `player_results`. If one ever
  did, the changeset/cast fails for that id and we log+skip (do not crash the
  transaction) — mirrors `Auth.get_users_map/1`'s `valid_uuid?/1` defensiveness.
  Implement `apply_completed_game/2` to skip ids that fail `Ecto.UUID.cast/1`.

## Test Plan (ExUnit)

All tests `use PidroServer.DataCase, async: true` unless they drive GenServers.
Use `Ecto.UUID.generate()` for user ids. Mirror lib paths.

### `test/pidro_server/profiles/profiles_test.exs`

Context unit tests (no GenServers; build `player_results` maps directly):

- **lazy creation**
  - `get_or_create_profile/1` creates a row when none exists, with all defaults
    (`games_played == 0`, `rating_mu == 25.0`, `heritage_flags == %{}`, etc.).
  - `get_or_create_profile/1` returns the existing row on second call (count stays 1).
  - concurrent-ish: calling twice never raises and never creates a duplicate
    (unique constraint + `on_conflict: :nothing` path).
- **fetch-for-screen**
  - `get_profile_for_screen/1` lazily creates and returns derived `win_rate == 0.0`
    when `games_played == 0` (no divide-by-zero).
  - `win_rate` computed correctly for a populated profile (e.g. 3 wins / 4 played
    == 0.75).
  - `avg_winning_bid == 0.0` when count is 0; correct average otherwise.
  - includes `first_seen_at` / `account_age_days` derived from the user's
    `inserted_at`.
- **incremental update** (`apply_completed_game/2`)
  - a winner's profile gets `games_played +1`, `wins +1`, `losses` unchanged.
  - a loser's profile gets `games_played +1`, `losses +1`.
  - creates profiles lazily for users with no prior profile.
  - abandoned-but-on-winning-team user is counted as a win (parity with
    `get_user_stats/1`).
- **win% edge cases**
  - 0 games → 0.0; all wins → 1.0; mixed.
- **rebuild parity**
  - given N inserted `GameStats` rows (string-keyed `player_results` via real
    insert/round-trip), `rebuild_from_history/1` produces the same
    `games_played/wins/losses` as applying each game incrementally.
  - rebuild is idempotent: running it twice yields identical counters.
  - rebuild overwrites drifted counters (manually corrupt a profile, rebuild,
    assert corrected).
  - rebuild tolerates a historical `GameStats` row with `player_results == nil`
    (pre-`player_results` data) via the position-vs-winner fallback.
  - `rebuild_all/0` rebuilds every user appearing in `player_ids` and returns the
    count.

### `test/pidro_server/stats/profile_rollup_test.exs` (integration)

`use PidroServer.DataCase, async: false`; drive `save_completed_game/4` (or the
`RoomManager` `:game_over` path, following `score_protection_test.exs`):

- completing a game inserts a `game_stats` row AND bumps each participating user's
  profile counters in one shot.
- **idempotent re-run:** sending the completion twice (or calling
  `save_completed_game/4` twice for the same `room_code`) leaves
  `games_played` incremented exactly once per user (and `GameStats` count == 1).
- bots produce no profile rows (only the human seats get profiles).
- transaction rollback: a forced stats-insert failure leaves NO profile change
  (counters untouched).

## Implementation Checklist (ordered, each independently verifiable)

1. **Migration** — add `20260607000000_create_player_profiles.exs`. Run
   `mix ecto.migrate`; verify table + unique index exist. (`mix ecto.rollback`
   round-trips cleanly.)
2. **Schema** — add `PlayerProfile` module. `iex -S mix`:
   `%PlayerProfile{} |> PlayerProfile.changeset(%{user_id: Ecto.UUID.generate()})`
   is valid; missing `user_id` is invalid.
3. **Context skeleton** — add `PidroServer.Profiles` with
   `get_or_create_profile/1` and `get_profile_for_screen/1` + the shared `win?/2`
   helper. Verifiable by the lazy-creation and fetch-for-screen tests.
4. **Profiles unit tests** — write `profiles_test.exs` for steps 3 and 5; run green.
5. **Incremental + rebuild** — add `apply_completed_game/2`,
   `rebuild_from_history/1`, `rebuild_all/0`. Verifiable by incremental + rebuild
   parity tests.
6. **Integration hook** — wrap `save_completed_game/4`'s new-row branch in a
   `Repo.transaction`, call `Profiles.apply_completed_game/2` after a successful
   stats insert; add `alias PidroServer.Profiles`. Verifiable by
   `profile_rollup_test.exs` (incl. idempotency + rollback).
7. **Rebuild mix task** — `mix pidro.rebuild_profiles` calling `Profiles.rebuild_all/0`
   (`lib/mix/tasks/pidro.rebuild_profiles.ex`, `Mix.Task` + `Mix.Task.run("app.start")`).
   Verifiable: corrupt a counter, run task, counter corrected.
8. **`mix precommit`** — format, compile (no warnings), full test suite, dialyzer,
   credo all green.

## Files to Create / Modify

**Create:**
- `apps/pidro_server/priv/repo/migrations/20260607000000_create_player_profiles.exs`
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex`
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex`
- `apps/pidro_server/lib/mix/tasks/pidro.rebuild_profiles.ex`
- `apps/pidro_server/test/pidro_server/profiles/profiles_test.exs`
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs`

**Modify:**
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — add `alias PidroServer.Profiles`;
  wrap the `nil ->` branch of `save_completed_game/4` in a transaction and call
  `Profiles.apply_completed_game(player_results, winner)` after a successful insert.

## Acceptance Criteria

- [ ] A `player_profiles` row exists or is created lazily for every user
      (`get_or_create_profile/1`, race-safe via unique index + `on_conflict`).
- [ ] Counters (`games_played`, `wins`, `losses`) update on game completion via the
      `save_completed_game/4` hook, atomically with the `game_stats` insert.
- [ ] Re-running completion for the same `room_code` does NOT double-increment.
- [ ] `rebuild_from_history/1` / `rebuild_all/0` reproduce the same counters from
      `game_stats` history (string-keyed JSONB tolerated) and are idempotent.
- [ ] `get_profile_for_screen/1` is a single cheap fetch (unique-index lookup, no
      array scan) returning stored + derived (`win_rate`, `avg_winning_bid`,
      `first_seen_at`).
- [ ] Bots produce no profiles; abandoned humans are counted (parity with
      `get_user_stats/1`).
- [ ] Progression columns (rating μ/σ + count, veteran level/xp, playstyle
      counters, avg-winning-bid accumulators, heritage flags) exist with defaults
      and are untouched by PID-44 logic.
- [ ] Mastery achievements are NOT stored on the profile (deferred to PID-50's
      separate table).

## Dependencies & Risks

- **Downstream owners:** PID-45/47 (rating), PID-48 (tiers, derived — no column),
  PID-49 (veteran/XP + heritage), PID-50 (achievements table), PID-51 (playstyle).
  Each fills columns this ticket seeds.
- **Risk — counter drift:** the whole reason for `rebuild_from_history/1`. Keeping
  the stats insert + profile bump in one transaction, and gating on the new-row
  branch, makes drift unlikely; the rebuild is the safety net.
- **Risk — JSONB key shape:** rebuild reads string-keyed `player_results`; the
  incremental path reads atom-keyed. The shared `win?/2` helper MUST handle both,
  and the parity test MUST exercise a real DB round-trip (not an in-memory map) to
  catch this. Reuse the proven `Stats.get_player_result/2` string/atom logic.
- **Risk — single-source-of-truth tension** (`apps/pidro_server/CLAUDE.md`): we are
  intentionally storing a rollup that duplicates derivable data. Mitigated by (a)
  never storing anything derivable cheaply at read time (win_rate, avg, tier,
  first_seen) and (b) the rebuild path keeping the rollup honest.

## Sources & References

### Internal References

- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-331` — `save_completed_game/4` (hook + idempotency boundary)
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:238-256,393-403` — `build_player_results/3` + `build_result/3` (per-user result, win/loss)
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:467-493` — `count_user_wins/2` + `get_player_result/2` (string/atom-tolerant win logic to reuse)
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:50-78` — `get_user_stats/1` (current live rollup; parity target)
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex` — `GameStats` schema (binary_id + changeset conventions)
- `apps/pidro_server/lib/pidro_server/accounts/user.ex:12-23` — `User` schema (`utc_datetime_usec`, no FK pattern)
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex:1755-1783` — `{:game_over, ...}` handler calling `save_completed_game/4`
- `apps/pidro_server/lib/pidro_server/repo.ex` — single Postgres Repo
- `apps/pidro_server/priv/repo/migrations/20251102100750_create_game_stats.exs` — binary_id + GIN migration pattern
- `apps/pidro_server/test/pidro_server/stats/score_protection_test.exs` — representative DataCase integration test (idempotency, JSONB string-key round-trip)

### Origin

- **Research:** [docs/ratings-player-profiles/research/PID-44-player-profile-store.md](../ratings-player-profiles/research/PID-44-player-profile-store.md)
- **Linear issue:** PID-44
