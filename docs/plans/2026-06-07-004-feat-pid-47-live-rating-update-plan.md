---
title: "feat: Update ratings on completed games + bot-seat policy"
type: feat
status: active
date: 2026-06-07
linear: PID-47
origin: docs/ratings-player-profiles/research/PID-47-live-rating-update.md
---

# feat: Update ratings on completed games + bot-seat policy

## Overview

PID-44 shipped the completion seam `Profiles.apply_completed_game/2` (lifetime
counters) wired into `Stats.save_completed_game/4`'s transaction. PID-45 shipped the
pure estimator `PidroServer.Rating`. PID-46 shipped the parity seam
`Profiles.rate_game/3` and the batch/replay job (`rerate_all/0`,
`rerate_incremental/0`) plus the `rating_state` cursor.

Today the live completion path moves only the three counters — it does NOT touch
`rating_mu`/`rating_sigma`/`rating_games_count`. Ratings move only when the rerating
job runs.

PID-47 wires the **live** rating update into the SAME completion transaction, reusing
`rate_game/3` so the per-game move is identical-by-construction to what `rerate_all/0`
replays. Concretely:

1. **Fold the rating move into the existing completion-update entry point**
   (`apply_completed_game`), so the `Stats` write path keeps ONE call. The completion
   update reads the four participants' live priors via `load_priors/1`, calls the
   shared `rate_game/3`, and on `{:rated, updated}` persists each participant's
   μ/σ + increments `rating_games_count` by 1; on `:unrated` it leaves ratings
   untouched (counters still bump as today). All inside the existing transaction.
2. **Authoritative v1 bot-seat policy:** rate ONLY games that started 4 distinct
   human seats. This falls out of `rate_game/3` returning `:unrated` (via the shared
   `rated_game?/1`) when fewer than 4 valid-UUID keys are present — no new flag.
3. **Cursor-coherence operational contract:** the live path does NOT advance the
   `rating_state` cursor (would serialize every game-over on one row lock — a global
   bottleneck). `rerate_incremental/0` becomes a backfill/repair tool that must not be
   run concurrently with live updates; `rerate_all/0` is the source-of-truth repair.

The parity acceptance (c) reduces to per-game MATH identity at the shared seam
(`rate_game/3` + `rated_game?/1`), which holds because both the live path and the
rebuild call the exact same function against the same priors-at-this-game.

## Non-Goals (owned by other tickets)

- **Tiers / matchmaking buckets (PID-48).** PID-47 only moves raw μ/σ + count.
- **Skill display / ordinal surfacing (PID-54).** No read-path or API changes here.
- **Veteran/XP, playstyle, heritage.** Untouched.
- **The estimator math (PID-45)** and **the batch job (PID-46).** Reused as-is; the
  only PID-46 file touched is a `@doc` clarification on `rerate_incremental/0`.
- **A DB unique constraint on `game_stats.room_code`.** Idempotency is already carried
  by the leading `get_by` short-circuit; adding a constraint is out of scope.

## The completion-update change (the wiring)

### Where it goes

The insertion point is the existing `nil ->` branch of
`Stats.save_completed_game/4`, inside the existing `Repo.transaction`, on the
`{:ok, stats}` arm — exactly where `Profiles.apply_completed_game/2` is called today
(`stats.ex:326`). `player_results` and `winner` are both in scope.

**Decision: keep ONE completion-update call from `Stats`.** Rather than add a second
`Profiles.*` call beside the counter call (two entry points to keep in sync), fold
the rating move INTO the completion-update function so `Stats` calls it once and the
counters + ratings move together atomically.

### Function shape

Add an arity-3 completion-update that does counters AND ratings, keeping the existing
arity-2 as a thin shim (so the PID-44 atomicity/idempotency rollup tests that call
`apply_completed_game/2` directly keep compiling):

```elixir
# Profiles
@spec apply_completed_game(map(), atom() | String.t()) :: :ok
def apply_completed_game(player_results, winner),
  do: apply_completed_game(player_results, winner, [])

@doc """
Applies one completed game to the participating users' profiles, inside the
caller's transaction (Stats.save_completed_game/4).

Counters: increments games_played + wins/losses per human participant (every
valid-UUID key), unchanged from PID-44 — counters count ALL human participation.

Ratings (v1 bot-seat policy): rates ONLY a game that started 4 distinct human
seats. Reads the participants' CURRENT stored {mu, sigma} as priors via
load_priors/1, calls the shared rate_game/3, and on {:rated, updated} overwrites
each participant's rating_mu/rating_sigma and increments rating_games_count by 1;
on :unrated leaves all rating columns untouched. This is identical-by-construction
to one rerate replay step (same rate_game/3, same priors-at-this-game).

Does NOT advance the rating_state cursor — see the cursor-coherence contract in
rerate_incremental/0's @doc.
"""
@spec apply_completed_game(map(), atom() | String.t(), keyword()) :: :ok
def apply_completed_game(player_results, winner, _opts) when is_map(player_results) do
  # 1. counters (unchanged PID-44 loop over every valid-UUID key)
  # 2. ratings:
  #    priors = load_priors(valid_uuid_keys(player_results))
  #    case rate_game(player_results, winner, priors) do
  #      {:rated, updated} -> persist_live_ratings(updated, participant ids of THIS game)
  #      :unrated -> :ok
  #    end
  :ok
end

def apply_completed_game(_player_results, _winner, _opts), do: :ok
```

(The `_opts` keyword is a forward seam only; pass `[]`. No options are read in v1 —
do not add any. Drop it if dialyzer/credo prefers a clean arity-3 over an unused arg;
either is fine.)

### Persisting the live ratings — reuse the increment-semantics path

The live per-game write is exactly one `rerate_incremental/0`-shaped step: priors =
current stored ratings, μ/σ overwritten, count **incremented** by 1. Reuse the
existing private `persist_ratings/3` with `:increment_count`:

- Build a `counts` map of `%{id => 1}` for the four participant ids of THIS game
  (the rated participants — `members_a ++ members_b`), and an `acc` containing only
  those four entries from `updated`.
- Call `persist_ratings(acc, counts, :increment_count)` — which `get_or_create_profile`
  (lazy, race-safe), `set: [rating_mu:, rating_sigma:]`, `inc: [rating_games_count: 1]`.
- Restrict `acc` to the four participants so non-participant priors (which
  `rate_game/3` carries through untouched) are not re-written. `load_priors/1` only
  loads the four ids anyway, so `updated` already contains just those four — no extra
  filtering needed, but assert/limit to the rated set to be explicit.

**`load_priors/1` must become callable from the completion path.** It is private
today. Decision: **make `load_priors/1` public** (smallest change; it is a pure read
helper already used by the incremental job, and the live path needs the identical
read so priors match the rebuild). Add a one-line `@doc`.

**`rated_game?/1` stays PRIVATE.** Per research, the live path gets the identical
rated/unrated decision by calling `rate_game/3` and matching `:rated`/`:unrated` —
it does not need to branch on the predicate outside `rate_game/3`. The only place
the live path needs the four participant ids is AFTER a `{:rated, updated}`, where it
already has `updated`'s keys (the four rated ids) — or it can reuse the existing
private `participant_ids/1`. Exposing `rated_game?/1` would add public surface for no
behavioral gain, so keep it private. (If `participant_ids/1` is the cleanest way to
get the four ids for `counts`, it stays private and is called from within `Profiles`.)

### Atomicity & ordering within the transaction

- The rating write sits on the `{:ok, stats}` arm, so a stats-insert failure
  (`{:error, changeset}` → `Repo.rollback`) rolls back the rating move too. PID-44's
  `profile_rollup_test.exs:83` already proves counter writes roll back; the rating
  write inherits this.
- Counters bump for every valid-UUID key (including `:abandoned` reserved-for ids);
  ratings move only on the rated 4-human set. These are intentionally different sets
  and both live in the one completion-update call.

## Bot-seat policy (authoritative, v1)

> **v1 rates ONLY games that started 4 distinct human seats** (a full 2v2 of real
> users). Single-player / bots-only, 3-human + bot-fill, and any game with fewer than
> 4 distinct valid-UUID `player_results` keys are **unrated**: ratings and
> `rating_games_count` are left untouched (lifetime counters still update).

This is enforced by the single shared `rated_game?/1` (exactly 4 distinct valid-UUID
keys, split 2 per team) reached via `rate_game/3`. Pure bots never appear in
`player_results` (`classify_seat/1 -> :skip`), so a bot-filled seat drops the key
count below 4 → `:unrated`. Non-UUID/guest ids (e.g. `"dev_host"`) are dropped by
`Ecto.UUID.cast` → also below 4 → `:unrated`.

**`:abandoned` / `:substitute` seats:** a seat where the original human disconnected
and a bot played surfaces under the human's UUID (`:abandoned`); a substitute human
surfaces under their UUID (`:substitute`). v1 keeps these RATED — they still represent
4 distinct human UUIDs that started the game ("started 4 distinct human seats").
Tightening the predicate to exclude `:abandoned`/`:substitute` is explicitly deferred;
if ever wanted, it is a one-line change in the single shared `rated_game?/1` and both
the live and rebuild paths track it automatically. State this policy as a `@doc`/code
comment on the completion-update function (and it already lives in `rated_game?/1`'s
existing comment).

Record this in `docs/ratings-player-profiles/00-PROGRESS.md`'s decisions log
(**finalizer's job — do NOT edit 00-PROGRESS in this ticket**).

## Cursor-coherence operational contract (the crux for acceptance c)

**Decision: the live completion path does NOT advance the `rating_state` singleton
cursor.** Advancing one shared row per game-over would serialize every realtime game
completion on a single row lock — a global hot-path bottleneck. The live path writes
only the four participants' profile rows (no contention between disjoint games).

Operational contract (document in the plan, in `rerate_incremental/0`'s `@doc`, and —
**by the finalizer** — in `00-PROGRESS.md`):

- Once live updates are active, `rating_state`'s cursor reflects the last **BATCH**
  rerate, NOT live progress. The cursor will lag behind live game completions.
- `rerate_incremental/0` is a **backfill / repair tool**, not a steady-state job. It
  MUST NOT be run concurrently with (or after, against the same games as) live
  updates — it would re-apply games the live path already applied, double-moving μ/σ
  and double-counting `rating_games_count`. Running it after live updates re-rates the
  post-cursor games on TOP of the live result (double-apply). This is operationally
  fenced, not code-enforced (v1).
- **`rerate_all/0` is the source-of-truth repair** once live updates are active: it
  wipes to `Rating.default/0` and replays the full history in total order, producing
  the canonical μ/σ/count regardless of any live/incremental drift. Run `--all` (not
  `--incremental`) to repair.

**Parity (acceptance c) is unaffected by the cursor decision.** Parity is about
per-game MATH identity at the shared `rate_game/3` seam — the live path and a fresh
`rerate_all/0` apply the identical function to the identical games in the identical
(completed_at, inserted_at, id) order from the identical default seed, so μ/σ/count
match. The cursor is purely a batch-resumption watermark and plays no role in the
live math or in a from-scratch `rerate_all/0`.

## Idempotency

Already carried by `save_completed_game/4`'s leading
`Repo.get_by(GameStats, room_code: ...)` short-circuit: a re-fired `:game_over` for a
room that already has a `GameStats` row returns `:ok` WITHOUT re-entering the
transaction. Since the rating move lives inside that transaction, **a re-fired
game-over never re-applies the rating move** — μ/σ never double-shift and
`rating_games_count` never double-increments per room. `room_code` is the de-facto
idempotency key. PID-44's `profile_rollup_test.exs:56` already proves the
double-fire-no-double-count behavior for counters; the rating columns inherit it, and
a new test asserts it for ratings explicitly.

## Test Plan (ExUnit)

### Extend `apps/pidro_server/test/pidro_server/profiles/rerate_test.exs` — real-path parity (acceptance c)

Add a `describe "live completion path == rerate_all/0 (acceptance c)"`. Use
`async: false` for the live-path tests (they drive `Stats.save_completed_game/4`,
which writes profiles) — either a new `async: false` test module or move the
live-path tests into the rollup file (preferred: put real-path tests in
`profile_rollup_test.exs`, keep `rerate_test.exs` for the existing simulated parity).
Decision below is to put real-path parity in the rollup test file.

### `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` (extend, `async: false`)

Reuse the existing harness (`RoomManager.create_room` + 3× `join_room` + `send {:game_over}`
+ `wait_until` for the `GameStats` row), and reuse `snapshot/0` +
`assert_profiles_match/2` (copy these two helpers from `rerate_test.exs`, or extract
to a shared support module — copy is fine for two helpers).

- **Real completion path == `rerate_all/0` (acceptance c).** Drive N (≥ 4) completed
  4-human games through the real path (via `Stats.save_completed_game/4` with seeded
  4-human seats, or the `:game_over` lifecycle). Snapshot all profiles
  (`{rating_mu, rating_sigma, rating_games_count}`). Run a fresh `Profiles.rerate_all/0`.
  Assert `assert_profiles_match(live_snapshot, snapshot())` (μ/σ within `1.0e-9`, exact
  count). **This is acceptance (c).**

  Note: driving via the `RoomManager :game_over` lifecycle gives `completed_at` values
  in wall-clock completion order, matching the rebuild's total order. If using
  `save_completed_game/4` directly with controlled `created_at`, ensure distinct
  `completed_at`/insertion order so the rebuild replays in the same order.

- **A 4-human game moves all four ratings.** After one rated game: each of the four
  participants has `rating_mu`/`rating_sigma` != default and `rating_games_count == 1`;
  winners' μ ↑ vs default, losers' μ ↓ vs default, all four σ shrink (< default σ).

- **A single-player / bots-only game leaves ratings at default.** Complete a game with
  ≤ 1 human seat (rest pure bots). The human's profile (lazily fetched) holds the
  schema default μ/σ and `rating_games_count == 0`; counters (`games_played`) still
  bump for the human.

- **A 3-human game leaves ratings untouched.** Complete a game with 3 humans + 1 bot
  (only 3 valid-UUID keys): all three humans have default μ/σ and
  `rating_games_count == 0`; `games_played == 1` each (counters still move).

- **Idempotent re-fire does not double-move ratings.** Fire `:game_over` twice for the
  same room (as the existing counter test does). Assert `Repo.aggregate(GameStats, :count) == 1`,
  each participant's `rating_games_count == 1`, and μ/σ equal a single application
  (snapshot after first fire == snapshot after second fire).

- **Atomicity (rating columns).** Extend the existing forced-rollback test: inside a
  transaction call the completion-update (counters + ratings), then `Repo.rollback` —
  assert zero profiles persisted (no μ/σ/count written). Reuses the PID-44 pattern.

- **Counters move on unrated games (regression).** Confirm the bot/3-human cases above
  still bump `games_played`/`wins`/`losses` — i.e. the rating policy did not
  accidentally gate the counters.

### `rate_game/3` pure tests

No new pure-seam tests needed — PID-46's `describe "rate_game/3 (pure)"` already covers
4-human rated, 3-human/bot/non-UUID/nil unrated, missing-prior default, string/atom
tolerance, and determinism. The live behavior is these cases reached through the
write path; do not duplicate the pure assertions.

## Implementation Checklist (ordered, each independently verifiable)

1. **Make `load_priors/1` public** in `Profiles` with a one-line `@doc`. Verifiable:
   `iex` call returns `%{user_id => {mu, sigma}}` for existing rows.
2. **Add `apply_completed_game/3`** (counters loop unchanged + rating block) and turn
   `apply_completed_game/2` into a shim delegating to `/3` with `[]`. Add the
   policy/cursor `@doc`. Verifiable by the 4-human / bot / 3-human / idempotency tests.
3. **Wire the rating persist** via `persist_ratings(acc_of_four, %{id => 1}, :increment_count)`,
   restricting `acc` to the four rated participant ids. Reuse `participant_ids/1`
   (private) for the id set. Verifiable: `rating_games_count == 1` and μ/σ moved.
4. **Confirm `Stats.save_completed_game/4` is unchanged** except that its single
   `Profiles.apply_completed_game(player_results, winner)` call now also moves ratings
   (no signature change at the call site — the /2 shim still exists). Verifiable: the
   call site compiles untouched; ratings move in the rollup test.
5. **Document the cursor-coherence contract** in `rerate_incremental/0`'s `@doc`
   (backfill/repair only, must not run concurrently with live updates, `rerate_all/0`
   is the repair). Verifiable: doc text present; no behavior change to the job.
6. **Tests** — extend `profile_rollup_test.exs` with the real-path parity + 4-human +
   bot + 3-human + idempotency + atomicity + counter-regression tests above.
7. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer, credo
   all green.

## Files to Create / Modify

**Modify:**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` — make `load_priors/1`
  public (`@doc`); add `apply_completed_game/3` (counters + rating block) and the
  `apply_completed_game/2` shim; reuse `persist_ratings/3` (`:increment_count`) and
  private `participant_ids/1`; add the cursor-coherence note to `rerate_incremental/0`'s
  `@doc`.
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` — add the
  real-path parity (acceptance c), 4-human-moves-all-four, single-player/bots-only,
  3-human, idempotent-re-fire, atomicity, and counter-regression tests; copy
  `snapshot/0` + `assert_profiles_match/2` helpers (or extract to support).

**Create:**
- None required. (No migration, no new module, no mix task — PID-46 shipped the
  cursor/job; PID-47 is pure wiring + tests.)

**Explicitly NOT modified:**
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — the call site stays
  `Profiles.apply_completed_game(player_results, winner)`; the new behavior rides the
  /2 → /3 shim. (If preferred, the call may be changed to the /3 form passing `[]` —
  cosmetic; either is acceptable.)
- `docs/ratings-player-profiles/00-PROGRESS.md` — decisions log update (bot policy +
  cursor contract) is the **finalizer's** job.

## Acceptance Criteria

- [ ] Finishing a rated 4-human multiplayer game updates all four human participants'
      `rating_mu`/`rating_sigma` and increments each `rating_games_count` by 1, inside
      the existing completion transaction (acceptance a).
- [ ] Bot / single-player / 3-human games leave `rating_mu`/`rating_sigma` at default
      and `rating_games_count == 0`; lifetime counters still update (acceptance b).
- [ ] The live per-game move is identical to `rerate_all/0`'s replay — proven by a
      real-completion-path snapshot == fresh `rerate_all/0` snapshot test (acceptance c).
- [ ] A re-fired `:game_over` for the same room does not double-move ratings (μ/σ
      unchanged, `rating_games_count` stays 1) — inherits the `room_code` short-circuit.
- [ ] A forced stats-insert failure rolls back the rating move (atomicity).
- [ ] The live path does NOT advance the `rating_state` cursor; `rerate_incremental/0`'s
      `@doc` carries the backfill/repair + no-concurrent-run + `rerate_all/0`-is-repair
      contract.
- [ ] `rated_game?/1` remains private; `load_priors/1` is public; bot policy lives in
      the single shared `rated_game?/1` + a completion-update `@doc`.
- [ ] `mix precommit` green.

## Dependencies & Risks

- **Upstream:** PID-44 (completion seam + counters + rollup test harness), PID-45
  (`Rating`), PID-46 (`rate_game/3`, `rated_game?/1`, `load_priors/1`,
  `persist_ratings/3`, `participant_ids/1`, the cursor/job).
- **Risk — live/incremental double-apply.** `rerate_incremental/0` after live updates
  double-applies post-cursor games. Mitigated by the documented operational contract
  (incremental is backfill-only; `rerate_all/0` repairs) — fenced operationally, not
  in code, for v1. Acceptable: the only correct steady-state repair is `--all`.
- **Risk — ordering drift in the parity test.** The rebuild replays in
  `[asc: completed_at, asc: inserted_at, asc: id]`; the live path applies in arrival
  order. For the parity test, drive games so arrival order == that total order
  (distinct/monotonic `completed_at`), matching how production completes games. Same
  drift-then-rebuild contract PID-46 documents; not a bug.
- **Risk — non-participant rewrite.** Guard that the live persist only writes the four
  rated ids (restrict `acc`), so `rate_game/3`'s carried-through non-participant priors
  are never re-persisted.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-344` — `save_completed_game/4`
  transaction and the `apply_completed_game/2` call site (insertion point).
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex:105-120` —
  `apply_completed_game/2` (counters); `:170-218` `rate_game/3`; `:277-303`
  `rerate_incremental/0` (`@doc` to extend); `:391-396` `participant_ids/1`; `:398-405`
  `load_priors/1` (to make public); `:409-427` `persist_ratings/3`.
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` — real-path
  harness (create_room/join/`:game_over`/`wait_until`) + idempotency + atomicity tests
  to extend.
- `apps/pidro_server/test/pidro_server/profiles/rerate_test.exs:56-72` — `snapshot/0`
  + `assert_profiles_match/2` (`@delta = 1.0e-9`) to reuse.

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-47-live-rating-update.md](../ratings-player-profiles/research/PID-47-live-rating-update.md)
- **Linear issue:** PID-47
