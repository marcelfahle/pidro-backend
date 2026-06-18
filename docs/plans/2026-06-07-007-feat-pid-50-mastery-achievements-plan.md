---
title: "feat: Mastery achievements — data-driven definitions + evaluation seam (PID-50)"
type: feat
status: active
date: 2026-06-07
linear: PID-50
origin: docs/ratings-player-profiles/research/PID-50-mastery-achievements.md
---

# feat: Mastery achievements (PID-50)

## Overview

Achievements are **data, not branches.** PID-50 ships a definition list
(`PidroServer.Achievements.Catalog`) where every achievement is a struct/map
declaring `key`, `name`, `description`, `tier`, an `evaluator` spec, a
`threshold`, and a `status` (`:active` | `:dormant`). A small set of **generic
evaluator functions** (cumulative-counter, win-streak, single-game-predicate)
covers every active achievement, so "add one" is a one-line edit to the catalog
list plus, at most, a threshold in config — never a new code branch or schema
change.

Achievements evaluate at game completion (live, inside the existing
`save_completed_game/4` transaction, right after counters/XP/rating) and are
re-derivable by `rebuild_from_history/1`. Awards persist to a new
`player_achievements` table as **permanent, idempotent** rows — once earned,
never removed or downgraded, even if a later game or a full rebuild "un-meets"
the threshold. The award path **returns the set of newly-earned keys** so PID-52
can build a post-game "achievement unlocked" payload without re-querying.

This rides the exact seam ratings (PID-47) and veteran XP (PID-49) already use:
`Profiles.apply_completed_game/4` (live) + `Profiles.rebuild_from_history/1`
(rebuild), with `Catalog` mirroring the `Progression` `@defaults` + `config/1`
tunable idiom. Per `apps/pidro_server/CLAUDE.md`: pure rules in a pure module,
single source of truth, thin wiring.

## The scope cut (6 active / 4 dormant) — decided + justified

The research A/B/C table (`PID-50-mastery-achievements.md`) is decisive: the
persisted `game_stats` row holds only **end-of-game aggregates** plus **one**
last-hand bid number. There is **no per-hand / per-player bid or points data
persisted anywhere.** The only whole-game record of per-hand facts is the live
engine `state.events` log, which is passed live into `save_completed_game/4` but
**thrown away** — never persisted.

Therefore:

- **SHIP NOW — the SIX rebuildable-from-`game_stats` achievements** (A-class).
  Every one is computable from columns that already exist (`player_results`,
  `winner`, `final_scores`, `completed_at`), so it evaluates live AND rebuilds
  exactly. These are the launch set.
- **DEFINE AS DORMANT — the FOUR live-only achievements** (B-class:
  `homerun`, `forcer`, `full_house`, `unstoppable`). They are **defined as data
  entries** in the catalog with `status: :dormant`, a `reason`, and a
  `followup` ticket reference, but are **NOT evaluated** — neither live nor in
  rebuild. They need persisted per-hand facts derived from `state.events`
  (bid-per-hand, forced-bid flag, per-team hand-points deltas, hand count).

**Explicit cut: this ticket does NOT add a `game_stats` per-hand/events column
and does NOT touch the engine.** Capturing per-hand facts (an `events` summary
column or a `game_hands` table + a writer change in `save_completed_game/4`) is
the separable follow-up that "unlocks" the dormant four — it is its own ticket
with its own migration + backfill story. Defining the four as dormant data now
means activating them later is a `status: :active` flip plus the capture work,
with **zero catalog/schema churn here.** We ship what is cleanly computable and
rebuildable today; we do not speculatively grow `game_stats` or instrument the
engine for four achievements.

## Non-Goals (explicit — owned elsewhere)

- **Per-hand fact capture for the dormant four** — separable follow-up ticket
  (persist an `events`-derived per-hand summary; then flip the four to
  `:active`). No engine change, no `game_stats` column in PID-50.
- **Post-game "what changed" / "achievement unlocked" payload** — **PID-52**.
  PID-50 does NOT build or broadcast the payload, but it DOES design the award
  path to **return the newly-earned keys this game** so PID-52 can consume them.
- **API / channel exposure of achievements** — **PID-54**.
  `get_profile_for_screen/1` gains an in-process `achievements` list; wiring it
  to a channel/controller is PID-54.
- **Tiers beyond tier I** — `winstreak` x5 / x10 ship as dormant tier rows
  (defined, not evaluated). Tier I (`x3`) is the only tier awarded at launch.

## Decisions (decided + justified)

### 1. Data-driven definition model — pure data + generic evaluators

**Decision: a definition LIST of plain structs, evaluated by a small set of
generic evaluator functions keyed by an `evaluator` tag — NOT a behaviour module
per achievement.** Rationale: every active achievement reduces to one of three
shapes already present in the codebase's data (cumulative counter, consecutive-
win run, single-game predicate). A behaviour-per-achievement adds a module and
boilerplate per def; the ticket's bar is "adding one is a data edit." Three
generic evaluators + a data list meet that bar with the least surface.

`PidroServer.Achievements.Catalog` (`apps/pidro_server/lib/pidro_server/achievements/catalog.ex`)
exposes `all/0` (the full list) and `active/0` (the launch subset). Each entry:

```
%Achievement.Def{
  key:         :winner,            # stable identifier (stored in player_achievements)
  name:        "The Winner",       # display (launch placeholder copy, tunable)
  description: "Win 5 games.",
  tier:        1,                  # 1 at launch; tiered defs carry distinct rows per tier
  evaluator:   :cumulative_wins,   # tag routing to a generic evaluator
  threshold:   5,                  # the Pidro-2 number (config-overridable)
  status:      :active,            # :active | :dormant
  reason:      nil,                # dormant-only: why deferred
  followup:    nil                 # dormant-only: unlock ticket
}
```

**Thresholds live in the def data, config-overridable** via the `Progression`
idiom: `Catalog.threshold(key)` reads `Application.get_env(:pidro_server,
PidroServer.Achievements.Catalog, [])[:thresholds][key]` and falls back to the
def's compile-time `threshold`. This mirrors `Progression.config/1` exactly, so
launch numbers are tunable without a deploy-shaped code change, but the canonical
value is visible in the catalog list.

The **three generic evaluators** (pure functions, no DB):

- `:cumulative_count` / `:cumulative_wins` — earns when a profile aggregate
  (`games_played` / `wins`) ≥ threshold. Reads the just-updated profile (live)
  or the rebuilt count (rebuild). Order-agnostic.
- `:win_streak` — earns when the longest run of consecutive wins (by the
  canonical total order `[asc: completed_at, asc: inserted_at, asc: id]`) ≥
  threshold. Needs the user's ordered game history (both paths read it the same
  way).
- `:single_game_predicate` — earns when ANY single completed game satisfies a
  pure predicate `(game_view, user_id) -> bool`. The predicate is named by a
  second tag (`:final_score_at_least`, `:final_score_negative`,
  `:partnered_win`). Live: evaluate against THIS game. Rebuild: `Enum.any?` over
  history. Because awards are permanent, "any historical game satisfied it" is
  the correct rebuild semantics and matches "the live game that first satisfied
  it" exactly.

A dormant entry's `evaluator` may name a B-class tag (`:hand_bid_made`, etc.)
that has **no evaluator function wired** — the evaluation router simply skips
`status: :dormant` entries, so naming a not-yet-implemented evaluator is safe and
self-documents the follow-up.

### 2. `player_achievements` table + schema

One row per `(user_id, achievement_key)` (per tier: tiered achievements store
the tier in the key-shaped row; see below). Permanent + idempotent.

**Decision on tiers:** the unique key is `(user_id, achievement_key)`. For the
tiered `winstreak`, each tier is a **distinct catalog entry with a distinct
`key`** (`:winstreak` for tier I; future `:winstreak_ii`, `:winstreak_iii`), so
the unique index stays simple and "earned tier II" is just another permanent row.
The `tier` column is stored for display/ordering. This avoids an upsert that
mutates `tier` upward (which would risk a downgrade on a stale rebuild) — every
tier is its own write-once row.

Migration `priv/repo/migrations/20260607020000_create_player_achievements.exs`,
matching `create_player_profiles.exs` conventions exactly:

```elixir
defmodule PidroServer.Repo.Migrations.CreatePlayerAchievements do
  use Ecto.Migration

  def change do
    create table(:player_achievements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Loose binary_id, NO FK — mirrors player_profiles / game_stats.player_ids.
      add :user_id, :binary_id, null: false
      add :achievement_key, :string, null: false
      add :tier, :integer, null: false, default: 1
      add :awarded_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}   # optional evidence

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:player_achievements, [:user_id, :achievement_key])
    create index(:player_achievements, [:user_id])
  end
end
```

Schema `PidroServer.Profiles.Achievement`
(`apps/pidro_server/lib/pidro_server/profiles/achievement.ex`), mirroring
`PlayerProfile`: `@primary_key {:id, :binary_id, autogenerate: true}`,
`@foreign_key_type :binary_id`, fields `user_id`, `achievement_key`, `tier`,
`awarded_at`, `metadata`, `timestamps(type: :utc_datetime_usec)`;
`changeset/2` casting those, `validate_required([:user_id, :achievement_key,
:awarded_at])`, `unique_constraint([:user_id, :achievement_key])`.

**Context functions** (in `Profiles`, alongside the existing context):

- `list_achievements(user_id) :: [Achievement.t()]` — earned rows for a user.
- `award_achievement(user_id, key, tier, metadata \\ %{}) :: :awarded | :already`
  — idempotent upsert: `Repo.insert(..., on_conflict: :nothing,
  conflict_target: [:user_id, :achievement_key])`. Returns `:awarded` when a row
  was actually inserted (new this call), `:already` when the conflict absorbed it
  (already earned). This return is what feeds the newly-earned-keys set.
- `ensure_achievements(user_id, [{key, tier, metadata}]) :: [key]` — awards a
  batch, returns the list of keys that were **newly** awarded (the `:awarded`
  subset). Used by both the live seam and rebuild.

Permanence: there is **no delete/downgrade path.** `on_conflict: :nothing` makes
re-evaluation (a later game, or a full rebuild) a no-op on already-earned rows.

### 3. Evaluation seam (live + rebuild) — per-achievement, both paths

A pure module `PidroServer.Achievements`
(`apps/pidro_server/lib/pidro_server/achievements/achievements.ex`) holds the
evaluators and the router:

- `evaluate_active(ctx) :: [{key, tier, metadata}]` — runs every `Catalog.active/0`
  entry against a context and returns the entries the user qualifies for. Pure,
  no DB. The same function is called by both paths; only the `ctx` source
  differs, and both contexts carry the same shape, which is what guarantees
  parity.

The context `ctx`:
```
%{
  user_id:    binary_id,
  aggregates: %{games_played: int, wins: int},   # post-update (live) / recomputed (rebuild)
  this_game:  game_view | nil,                    # live: this game; rebuild: nil
  history:    [game_view]                         # ordered; live: user's full history incl. this game
}
```
`game_view` is a normalized read of one `game_stats`-equivalent row
(`final_scores`, `winner`, `player_results`, `completed_at`) — built from the
live in-scope data on the live path, and from a `GameStats` row on rebuild,
using the **same** tolerant team/result/score helpers already in `profiles.ex`
(`won_game?/2`, `team_for_user/2`, `score_for_team/2`, `rated_game?/1`).

**Live path** — extend `apply_completed_game/4` after counters/XP/rating:

1. The per-participant loop already runs counters + XP. After the loop (so the
   profile aggregates are already incremented), for each valid-UUID participant:
   build `ctx` from (a) the just-updated profile aggregates (re-read
   `games_played`/`wins` — they are written above in the same txn), (b)
   `this_game` = a `game_view` built from the in-scope `player_results` /
   `winner` / `scores`, (c) `history` = the user's ordered games from
   `game_stats` **including this game** (the row was inserted earlier in this
   same transaction by `save_game_result/1`, so it is visible to this query).
2. `evaluate_active(ctx)` → list of `{key, tier, metadata}`.
3. `ensure_achievements(user_id, awards)` → newly-earned keys for that user.
4. Accumulate all participants' newly-earned keys into a map
   `%{user_id => [key]}` and **return it from `apply_completed_game/4`** (new
   return value; see Decision 5).

**Rebuild path** — extend `rebuild_from_history/1`:

1. It already loads `games = from(gs in GameStats, where: ^user_id in
   gs.player_ids)`. Add an `order_by:` for the canonical total order (needed by
   the streak evaluator; the existing query is unordered — add
   `[asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]`).
2. Build `ctx` from the recomputed `games_played`/`wins`, `this_game: nil`,
   `history: ordered games`.
3. `evaluate_active(ctx)` then `ensure_achievements(user_id, awards)` — idempotent
   (already-earned rows are no-ops; never removes a row even if some def now
   evaluates false, satisfying permanence).

**Per-achievement evaluation in BOTH paths (the 6 active):**

| Key | Live (this completion) | Rebuild (history) | Parity argument |
|---|---|---|---|
| `player` (`:cumulative_count` games, **10**) | `aggregates.games_played >= 10` (post-inc) | recomputed `games_played >= 10` | Same counter; rebuild reproduces the live count exactly (PID-44 invariant). |
| `winner` (`:cumulative_wins`, **5**) | `aggregates.wins >= 5` (post-inc) | recomputed `wins >= 5` | Same counter. |
| `winstreak` tier I (`:win_streak`, **3**) | longest consecutive-win run over `history` (incl. this game) ≥ 3 | longest run over ordered `history` ≥ 3 | Both sort by the canonical total order and run-length `won_game?/2`; the live `history` includes the just-inserted row, so both see the identical ordered sequence. |
| `ace` (`:single_game_predicate :final_score_at_least`, **threshold = `opponent_score <= 0` margin rule**, see Decision 4) | predicate on `this_game` | `Enum.any?` predicate over `history` | Predicate is pure on a `game_view`; "any game" (rebuild) ⊇ "this game" (live), and once earned it's permanent — identical award. |
| `the_loser` (`:single_game_predicate :final_score_negative`) | own team's `final_scores < 0` on `this_game` | `Enum.any?` over `history` | Same predicate, same permanence. |
| `partnership` (`:single_game_predicate :partnered_win`, **1**) | `this_game` is a 4-distinct-human 2v2 (`rated_game?/1` shape) AND the user's team won | `Enum.any?` over `history` | Reuses the existing shared `rated_game?/1` predicate; live & rebuild use the identical function. |

The **dormant four** appear in `Catalog.all/0` with `status: :dormant` and are
**filtered out by `Catalog.active/0`**, so `evaluate_active/1` never touches them
in either path. They can never auto-award. (A test asserts this.)

### 4. "Ace" threshold + "partnership" definition (re-derived for Pidro 2)

**Ace — re-derived, NOT "win with ≥62".** Under Pidro 2 every win reaches the
62 target, so "score ≥ 62" qualifies every winner and is meaningless. We need a
**dominance** bar that is cleanly computable from `final_scores` alone.

**Decision: `ace` = win a game while the OPPONENT team's final score is `≤ 0`**
(i.e. the opponent finished at or below zero — possible because
`allow_negative_scores: true`). This is a genuine blowout, reads purely from the
persisted `final_scores`, needs no per-hand data, and is rare enough to feel like
mastery. (Config-tunable: the predicate compares `opponent_final <= threshold`
with `threshold: 0`; raising it to, say, `10` widens the bar later without a code
change.) Rejected alternatives: "margin ≥ N" (also fine, but a fixed opponent
ceiling is sharper copy — "shut them out"); "win with own score ≥ 62" (every
win — rejected).

**Partnership — re-derived for Pidro 2.** `player_results` records each user's
`team`; a 4-human 2v2 is exactly the `rated_game?/1` shape (4 distinct valid
UUIDs, 2 per team). **Decision: `partnership` = win a 4-human 2v2 game with your
partner** (you + your same-team teammate both human, your team won). Tier I
threshold = **1** such partnered win. Rationale: it is cleanly computable today
(reuses the shared `rated_game?/1`), is meaningful (a "real" full-table win, not
a bot-filled one), and keeps the cut tight. We explicitly do **not** attempt
"N wins with the SAME partner across games" — cross-game stable-pairing identity
is not modeled in `game_stats` (research Open Q5), so that variant would need new
tracking and is out of scope; "win partnered in a full 2v2" needs nothing new.

### 5. Award path returns newly-earned keys (for PID-52)

`apply_completed_game/4` currently returns `:ok`. **Decision: it now returns
`{:ok, %{user_id => [newly_earned_key]}}`** (empty map when nothing newly
earned). The `stats.ex` call site ignores the map for now (PID-50 does not build
the payload — that's PID-52), but the data is produced and returned at the seam,
so PID-52 wires it to the post-game event with no re-query. The arity-2 shim and
`/4` default-args shape are preserved; only the return value is enriched.

Because the surrounding `save_completed_game/4` transaction matches on `{:ok,
stats}` from the inner `Repo.transaction`, the new richer return from
`apply_completed_game` is captured into a local (e.g. `newly_earned`) inside the
transaction fn and discarded for PID-50 (documented as the PID-52 seam).

### 6. `get_profile_for_screen/1` additions

Add an `achievements` key: the user's **earned** list, each as
`%{key, name, description, tier, awarded_at}` (joining the stored rows to
`Catalog` for display copy). This is the requirement.

**Decision on a locked catalog:** keep minimal — expose earned only as the
required field, plus an OPTIONAL `achievements_catalog` of `active/0` defs
annotated `earned: bool` (so a UI can show "locked" achievements) **behind a
plain helper, not computed eagerly in the hot path** if it adds a query. Since
`list_achievements/1` is a single indexed read and `Catalog.active/0` is
in-memory data, including a `locked`/`earned` split is cheap; ship the earned
list as the contract and the active-catalog-with-earned-flag as a thin extra.
Dormant defs are NOT surfaced (they're internal scope-cut bookkeeping).

## Catalog — the full def list with chosen Pidro-2 thresholds

`Catalog.all/0` (verbatim intent; copy is launch placeholder, tunable):

```elixir
# ACTIVE (shipped, A-class, rebuildable from game_stats) -----------------------
%Def{key: :player,      name: "Player",      tier: 1, status: :active,
     description: "Finish 10 games.",
     evaluator: {:cumulative_count, :games_played}, threshold: 10},

%Def{key: :winner,      name: "The Winner",  tier: 1, status: :active,
     description: "Win 5 games.",
     evaluator: {:cumulative_count, :wins},          threshold: 5},

%Def{key: :winstreak,   name: "Win Streak",  tier: 1, status: :active,
     description: "Win 3 games in a row.",
     evaluator: :win_streak,                         threshold: 3},

%Def{key: :ace,         name: "Ace",         tier: 1, status: :active,
     description: "Win a game while the opposing team finishes at 0 or below.",
     evaluator: {:single_game_predicate, :opponent_at_or_below},
     threshold: 0},   # opponent_final <= 0

%Def{key: :the_loser,   name: "The Loser",   tier: 1, status: :active,
     description: "Finish a game with your team in negative points.",
     evaluator: {:single_game_predicate, :final_score_negative},
     threshold: 0},   # own_final < 0

%Def{key: :partnership, name: "Partnership", tier: 1, status: :active,
     description: "Win a full 4-player game alongside your partner.",
     evaluator: {:single_game_predicate, :partnered_win}, threshold: 1},

# DORMANT (defined as data, NOT evaluated — needs per-hand event capture) ------
%Def{key: :homerun,     name: "Homerun",     tier: 1, status: :dormant,
     description: "Bid 14 and make it.",
     evaluator: {:hand_event, :max_bid_made}, threshold: 14,
     reason: "Needs per-hand bid+made facts from state.events; not persisted.",
     followup: "per-hand fact capture (separable ticket)"},

%Def{key: :forcer,      name: "Forcer",      tier: 1, status: :dormant,
     description: "As dealer, be forced to bid 6 and still make it.",
     evaluator: {:hand_event, :forced_bid_made}, threshold: 6,
     reason: "Needs forced-bid flag + hand outcome from state.events.",
     followup: "per-hand fact capture (separable ticket)"},

%Def{key: :full_house,  name: "Full House",  tier: 1, status: :dormant,
     description: "Take all 14 points in a single hand.",
     evaluator: {:hand_event, :hand_points_at_least}, threshold: 14,
     reason: "Needs per-hand per-team points deltas from state.events.",
     followup: "per-hand fact capture (separable ticket)"},

%Def{key: :unstoppable, name: "Unstoppable", tier: 1, status: :dormant,
     description: "Win a game in 5 hands or fewer.",
     evaluator: {:game_meta, :hands_at_most}, threshold: 5,
     reason: "Needs hand_number at completion; live-only, not persisted.",
     followup: "per-hand fact capture (separable ticket)"}
```

Threshold derivation (Pidro 2: game to 62, 14 max pts/hand, bids 6..14, negative
scores allowed): `player` 10 and `winner` 5 carry sensible entry-level counts;
`winstreak` tier I = 3 (x5/x10 deferred as future tiered defs); `ace` opponent
`≤ 0` (a true shutout, not "≥62" which every winner has); `the_loser` own team
`< 0`; `partnership` = 1 full-table partnered win. Dormant thresholds
(`homerun` 14, `forcer` 6, `full_house` 14, `unstoppable` 5) are documented for
the follow-up but unused now. None copied from Pidro 1 numerics — they are
re-derived against the 62-point / 14-per-hand model.

## Test Plan (ExUnit)

### `PidroServer.Achievements.CatalogTest` — `.../achievements/catalog_test.exs`
`async: true`.
- `active/0` returns exactly the 6 active keys; `all/0` returns 10; the 4 dormant
  keys carry `status: :dormant`, a non-nil `reason`, and a `followup`.
- `threshold/1` returns the def default; with `Application.put_env` override
  (+ `on_exit`) returns the overridden value (proves config-tunable).
- **Data-driven add-one is trivial:** a test injects a synthetic active def into
  a catalog list and asserts `evaluate_active/1` evaluates it with no other code
  change (or: documents that adding a `%Def{}` line + reusing an existing
  evaluator tag is the entire change — assert the evaluator router dispatches a
  new entry purely by its tag).

### `PidroServer.AchievementsTest` (pure evaluators) — `.../achievements/achievements_test.exs`
`async: true`. Drives `evaluate_active/1` with hand-built `ctx` (no DB):
- `player`: earns at `games_played == 10`, NOT at 9.
- `winner`: earns at `wins == 5`, NOT at 4.
- `winstreak`: earns when history has a run of ≥3 consecutive wins; NOT at a
  run of 2; a loss BREAKS the run (W,W,L,W,W → not earned; W,W,W → earned);
  non-consecutive wins separated by losses do not earn. Edge: exactly 3 in a row
  at the END of history earns; 3 in a row in the MIDDLE earns.
- `ace`: earns when `this_game` opponent final `≤ 0`; NOT when opponent final
  `> 0` (even on a win); the user must be on the WINNING team.
- `the_loser`: earns when own team final `< 0`; NOT at `0`; NOT at positive.
- `partnership`: earns on a 4-distinct-human 2v2 win; NOT on a bot-filled game
  (fails `rated_game?/1` shape); NOT on a 2v2 LOSS; tolerant of string-keyed
  `player_results`.
- **Dormant never auto-award:** a `ctx` that would trivially satisfy a dormant
  def's nominal intent yields no dormant keys from `evaluate_active/1` (they are
  filtered before evaluation; their evaluator tags are never dispatched).

### Award/permanence — `PidroServer.ProfilesTest` (or a new achievements rollup)
Uses `DataCase`.
- `award_achievement/4` inserts a row and returns `:awarded`; a second identical
  call returns `:already` and does NOT duplicate (unique index holds).
- `ensure_achievements/2` returns only the newly-inserted keys; re-running with
  the same set returns `[]`.
- **Permanence:** award `winstreak`, then run a context where the streak is now
  broken / `rebuild_from_history/1` recomputes a sub-threshold count — the row
  remains; nothing is removed or downgraded.

### Live + rebuild parity — extend `profile_rollup_test.exs`
Drives real `save_completed_game/4` (`DataCase`).
- Completing the 10th game awards `player`; the 5th win awards `winner`; 3
  straight wins award `winstreak`; an opponent-shutout win awards `ace`; a
  negative-finish game awards `the_loser`; a 4-human 2v2 win awards
  `partnership`.
- **Live == rebuild award parity (headline guard):** run a scripted sequence of
  completions, snapshot each user's earned-key set, run `rebuild_all/0`, assert
  the earned-key sets are **identical** (same keys, no extras, none removed).
- **Newly-earned-keys return:** `apply_completed_game/4` returns
  `{:ok, %{user_id => [keys]}}`; the game that crosses a threshold reports that
  key as newly-earned; a subsequent game does NOT re-report it (idempotent).
- **Rebuild idempotency:** running `rebuild_from_history/1` twice yields the same
  rows and awards nothing the second time.
- **Dormant never appear** in earned lists after any number of completions or a
  full rebuild.

### `get_profile_for_screen/1` — extend `profiles_test.exs`
- Returns an `achievements` list of earned defs with `name`/`description`/`tier`/
  `awarded_at`; empty for a fresh profile.
- Optional `achievements_catalog` (if shipped) shows the 6 active defs with an
  `earned` flag; dormant defs are NOT present.

## Implementation Checklist (ordered, each independently verifiable)

1. **Migration** `20260607020000_create_player_achievements.exs` (binary_id PK,
   loose `user_id`, `achievement_key`, `tier`, `awarded_at`, `metadata`, unique
   `[:user_id, :achievement_key]` + `[:user_id]` index). `mix ecto.migrate`.
2. **Schema** `profiles/achievement.ex` (`Achievement`) + `changeset/2`.
3. **Catalog** `achievements/catalog.ex` — `Def` struct, `all/0`, `active/0`,
   `threshold/1` (`@defaults` + `config/1` idiom), the full 10-entry list, with
   moduledoc documenting the 6/4 cut + the dormant follow-up. Doctests for
   `active/0`/`threshold/1`.
4. **Evaluators** `achievements/achievements.ex` — `evaluate_active/1`, the
   `:cumulative_count` / `:win_streak` / `:single_game_predicate` evaluators, the
   `game_view` normalizer reusing `profiles.ex` helpers, dormant filter. Pure,
   doctested where practical.
5. **Context fns** in `profiles.ex` — `list_achievements/1`,
   `award_achievement/4`, `ensure_achievements/2` (idempotent upsert).
6. **Write Catalog + Achievements + award tests**; run green (pure first).
7. **Live seam** — extend `apply_completed_game/4`: after counters/XP/rating,
   per participant build `ctx`, `evaluate_active/1`, `ensure_achievements/2`,
   accumulate newly-earned keys; **return `{:ok, %{user_id => [key]}}`**. Keep
   arity-2 shim. Update the `stats.ex` call site to capture (and discard) the
   richer return inside the transaction.
8. **Rebuild seam** — extend `rebuild_from_history/1`: add canonical `order_by`,
   build `ctx` (history-based), `ensure_achievements/2`. `rebuild_all/0` rides
   along.
9. **`get_profile_for_screen/1`** — add `achievements` (earned) + optional
   `achievements_catalog` with `earned` flags.
10. **Extend `profile_rollup_test.exs` + `profiles_test.exs`** — live awards,
    live==rebuild parity, newly-earned return, dormant-never-award, screen
    additions. Run green.
11. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer,
    credo all green.

## Files to Create / Modify

**Create:**
- `apps/pidro_server/priv/repo/migrations/20260607020000_create_player_achievements.exs`
- `apps/pidro_server/lib/pidro_server/profiles/achievement.ex` — schema.
- `apps/pidro_server/lib/pidro_server/achievements/catalog.ex` — def list + config.
- `apps/pidro_server/lib/pidro_server/achievements/achievements.ex` — evaluators + router.
- `apps/pidro_server/test/pidro_server/achievements/catalog_test.exs`
- `apps/pidro_server/test/pidro_server/achievements/achievements_test.exs`

**Modify:**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `list_achievements/1`, `award_achievement/4`, `ensure_achievements/2`;
  `apply_completed_game/4` (evaluate + return newly-earned map);
  `rebuild_from_history/1` (ordered query + evaluate); `get_profile_for_screen/1`
  (achievements list); aliases for `Achievement`, `Achievements`, `Catalog`.
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — call site captures the
  richer `apply_completed_game/4` return (discarded for PID-50; PID-52 seam).
- `config/config.exs` — optional `config :pidro_server,
  PidroServer.Achievements.Catalog, thresholds: %{...}` block (tunable; defaults
  live in the catalog so this is optional).
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` — live +
  parity + newly-earned tests.
- `apps/pidro_server/test/pidro_server/profiles_test.exs` — screen additions.

**Explicitly NOT modified (the scope cut):**
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex` + its migration — **no
  per-hand/events column added.** The dormant four wait on the separable capture
  ticket.
- The engine (`apps/pidro_engine/**`) — untouched. No new instrumentation; the
  `events` log already records the needed facts, the gap is purely persistence.

## Acceptance Criteria

- [ ] Achievement definitions are DATA (a catalog list of `%Def{}`), evaluated by
      generic evaluators; adding one is a data edit (no new branch/schema).
- [ ] The 6 active achievements evaluate from completed-game data and persist to
      `player_achievements`; tier I only (`winstreak` x3; x5/x10 dormant).
- [ ] `ace` uses a re-derived Pidro-2 bar (opponent ≤ 0), NOT "win with ≥62".
- [ ] `partnership` (new) awards on a 4-human 2v2 win, reusing `rated_game?/1`.
- [ ] The 4 dormant achievements are defined as `status: :dormant` data with a
      `reason` + `followup` and are NEVER auto-awarded (live or rebuild).
- [ ] Awards are permanent + idempotent (unique `[:user_id, :achievement_key]`,
      `on_conflict: :nothing`); rebuild never removes/downgrades.
- [ ] Live award set == rebuild award set (parity test green).
- [ ] `apply_completed_game/4` returns the per-user newly-earned keys (PID-52 seam).
- [ ] `get_profile_for_screen/1` returns an earned `achievements` list.
- [ ] NO `game_stats` per-hand column; NO engine change. `mix precommit` green.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `apply_completed_game/4` seam, `rebuild_from_history/1`, `rebuild_all/0`,
  `get_profile_for_screen/1`, `won_game?/2`, `team_for_user/2`,
  `score_for_team/2`, `rated_game?/1`, `get_or_create_profile/1`.
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex` +
  `priv/repo/migrations/20260607000000_create_player_profiles.exs` — table /
  schema conventions (binary_id, loose user_id, unique index, on_conflict).
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-345` —
  `save_completed_game/4` transaction + the `apply_completed_game` call site;
  `game_state` (4th arg) already received but not forwarded.
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex` — persisted columns
  (only last-hand `bid_amount`; no per-hand data).
- `apps/pidro_server/lib/pidro_server/progression.ex` — the `@defaults` +
  `config/1` (`Application.get_env/3`) tunable-data idiom mirrored by `Catalog`.

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-50-mastery-achievements.md](../ratings-player-profiles/research/PID-50-mastery-achievements.md)
- **Linear issue:** PID-50
