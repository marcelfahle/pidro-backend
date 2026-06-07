---
title: "feat: Post-game progression summary — per-player \"what changed\" payload (PID-52)"
type: feat
status: active
date: 2026-06-07
linear: PID-52
origin: docs/ratings-player-profiles/research/PID-52-post-game-summary.md
---

# feat: Post-game progression summary (PID-52)

## Overview

When a game ends today, one room-wide `game_over` broadcast carries only
`%{winner, scores}` — there is **no per-player "what changed" signal** anywhere on
the path. Every progression side-effect (XP/level, rating/tier, achievements,
playstyle) is already applied server-side inside `Profiles.apply_completed_game/5`
during `Stats.save_completed_game/4`, but that function returns only
`{:ok, %{user_id => [newly_earned_keys]}}` and the caller discards it.

PID-52 composes the layers that PID-47/48/49/50/51 already shipped into **one
clean per-player summary map** and delivers it **per-socket**. It adds no new
estimator math, no new DB columns, and no persistence — the summary is **ephemeral**
(computed at completion, pushed, gone). The work is three thin seams:

1. **A pure builder** (`PidroServer.Profiles.PostGameSummary.build/3`) — given a
   player's BEFORE snapshot + the game's computed deltas, returns the summary map.
   No DB, fully doctested.
2. **Capture before/after in the existing loop.** `apply_completed_game/5` reads a
   BEFORE snapshot per participant, assembles the summary from the deltas it
   already computes, and **changes its return** from `%{user_id => [keys]}` to
   `%{user_id => summary_map}` (achievements become a field of the summary). Still
   inside the existing transaction.
3. **Propagate + per-player push.** `save_completed_game/4` returns the summaries
   map; the RoomManager `:game_over` handler fires a **new post-commit** PubSub
   broadcast `{:progression_summary, room_code, summaries}`; `GameChannel` pushes
   each socket only ITS slice as a `"progression_summary"` event.

The design honors the acceptance contract: the XP/level/title block is
**unconditional** (the guaranteed fallback — every game, win or lose, rated or
casual), casual **leads with Veteran/Mastery** and **omits** any tier/skill number,
and the tier move is **gated on `rated?`**. The existing `%{winner, scores}`
`game_over` push stays exactly as the always-present base skeleton; the summary
layers on top.

Per `apps/pidro_server/CLAUDE.md`: pure logic in a pure module, single source of
truth (derive, don't store), thin GenServer wiring.

## Non-Goals (explicit — owned elsewhere)

- **The full profile-screen endpoint — PID-54.** `get_profile_for_screen/1` and any
  controller/channel exposure of the durable profile is PID-54. PID-52 only emits
  the ephemeral *delta* at game end.
- **Persistence / rebuild of the summary.** The summary is ephemeral — built, pushed,
  discarded. There is **no rebuild concern**: nothing is stored, so `rebuild_*`
  paths are untouched. (Contrast PID-51's accumulators, which must rebuild.)
- **New DB columns / schema changes.** Everything the summary needs is already
  written by the existing writers; we only *read it before* and compute *pure*
  classifications on top.
- **Changing the existing `game_over` push.** `%{winner, scores}` stays as-is — the
  always-present base. The summary is a separate, additive push.
- **Engine changes.** No `apps/pidro_engine/**` edits.

## The summary map shape (snake_case, Jason-friendly)

One map per human participant, keyed by `user_id` (UUID string). All keys are
snake_case atoms; Jason emits them as JSON string keys, and atom *values*
(titles, tiers) serialize to strings (research §7). Tuples are not Jason-friendly,
so `veteran_progress` is emitted as a `%{into, span, max}` map, never the raw
`{into, span}` / `:max` that `Progression.level_progress/1` returns.

### Always present (the guaranteed fallback — every game)

| Key | Type | Source |
|---|---|---|
| `rated` | boolean | `match?({:ok, _}, rated_game?(player_results))` |
| `xp_earned` | non_neg_integer | `Progression.xp_for_game(team_score, won?)` (the `apply_xp` delta) |
| `veteran_xp` | non_neg_integer | after value |
| `veteran_level_before` | pos_integer | `Progression.level_for_xp(xp_before)` |
| `veteran_level` | pos_integer | `Progression.level_for_xp(xp_after)` |
| `leveled_up` | boolean | `veteran_level > veteran_level_before` |
| `veteran_title_before` | string | `Progression.title_for_level(level_before)` |
| `veteran_title` | string | `Progression.title_for_level(level_after)` |
| `title_changed` | boolean | `veteran_title != veteran_title_before` |
| `veteran_progress` | `%{into, span, max}` | `Progression.level_progress(xp_after)` normalized (`:max` → `%{into: 0, span: 0, max: true}`) |
| `achievements_unlocked` | list of maps | newly-earned keys joined to `Catalog` |

`achievements_unlocked` entries: `%{key: string, name: string, tier: integer}`
(e.g. `%{key: "winner", name: "The Winner", tier: 1}`). Empty list when nothing new.

### Rated only (`nil` when casual)

| Key | Type | Notes |
|---|---|---|
| `rating` | map or `nil` | `nil` for casual games (omit the loud skill number) |

When `rated?`, `rating` is:

```
%{
  tier_before:        "provisional" | "bronze" | ... | "master",
  tier_after:         <same domain>,
  provisional_before: boolean,
  provisional_after:  boolean,
  direction:          "up" | "down" | "none"
}
```

`tier_*` / `provisional_*` from `Tier.classify(mu, sigma, count)` on the
before/after `{mu, sigma, count}`. `direction` from the **ordinal** delta
(`Rating.ordinal({mu_after, sigma_after}) - Rating.ordinal({mu_before, sigma_before})`):
`> 0 → "up"`, `< 0 → "down"`, `== 0 → "none"`. (Ordinal, not raw μ, so the band
input and the direction agree.)

### Example — rated win (winner crosses Silver→Gold, no new achievement)

```json
{
  "rated": true,
  "xp_earned": 112,
  "veteran_xp": 540,
  "veteran_level_before": 4,
  "veteran_level": 4,
  "leveled_up": false,
  "veteran_title_before": "Rookie",
  "veteran_title": "Rookie",
  "title_changed": false,
  "veteran_progress": {"into": 152, "span": 112, "max": false},
  "achievements_unlocked": [],
  "rating": {
    "tier_before": "silver",
    "tier_after": "gold",
    "provisional_before": false,
    "provisional_after": false,
    "direction": "up"
  }
}
```

### Example — casual loss (single-player / bot-filled; leads with Veteran, no tier)

```json
{
  "rated": false,
  "xp_earned": 45,
  "veteran_xp": 45,
  "veteran_level_before": 1,
  "veteran_level": 1,
  "leveled_up": false,
  "veteran_title_before": "Rookie",
  "veteran_title": "Rookie",
  "title_changed": false,
  "veteran_progress": {"into": 45, "span": 83, "max": false},
  "achievements_unlocked": [],
  "rating": null
}
```

### Example — level-up (casual win that crosses a level AND unlocks `:player`)

```json
{
  "rated": false,
  "xp_earned": 112,
  "veteran_xp": 180,
  "veteran_level_before": 1,
  "veteran_level": 3,
  "leveled_up": true,
  "veteran_title_before": "Rookie",
  "veteran_title": "Rookie",
  "title_changed": false,
  "veteran_progress": {"into": 6, "span": 102, "max": false},
  "achievements_unlocked": [{"key": "player", "name": "Player", "tier": 1}],
  "rating": null
}
```

(XP/level/achievements always populate; `rating` is `null` for both casual examples.
A rated game that also crosses a level would carry both `leveled_up: true` and a
populated `rating`.)

## Decisions (decided + justified)

### 1. The pure builder — `PidroServer.Profiles.PostGameSummary.build/3`

`apps/pidro_server/lib/pidro_server/profiles/post_game_summary.ex`. Pure, no DB,
doctested. Composes `Progression`, `Tier`, `Rating`, and `Catalog`; takes only
plain data so it is trivially unit-testable.

```
@spec build(before :: map(), deltas :: map(), opts :: keyword()) :: map()
```

- `before` — the BEFORE snapshot read at the top of the loop body:
  `%{veteran_xp, rating_mu, rating_sigma, rating_games_count}` (the profile columns
  before any writer ran).
- `deltas` — the per-game computed values the loop already has in hand:
  `%{xp_earned, veteran_xp_after, rated?, rating_after: {mu, sigma} | nil,
  rating_count_after: integer | nil, newly_earned_keys: [atom]}`.
- `opts` — forward seam, `[]` in v1.

The builder:
- **Always** computes the XP/level/title/progress block from `before.veteran_xp`
  and `deltas.veteran_xp_after` via `Progression` (level/title/progress are pure
  functions of XP — no extra reads).
- Normalizes `veteran_progress` (`{into, span}` → `%{into, span, max: false}`;
  `:max` → `%{into: 0, span: 0, max: true}`).
- Maps `newly_earned_keys` to `achievements_unlocked` via `Catalog.all/0`
  (`%{key, name, tier}`; unknown keys dropped, same defensive pattern as
  `screen_achievements/1`).
- When `deltas.rated?`, builds `rating` from `Tier.classify` before/after +
  ordinal-delta direction; when casual, sets `rating: nil`.

**Justification.** The XP/level block is **unconditional** because PID-49 awards XP
to every valid-UUID participant regardless of rated status (the existing loop step
1 runs `apply_xp` for everyone). That is exactly the always-present fallback the
acceptance demands — even a casual loss with `xp_earned: 0` still carries a
complete Veteran block. Tier is the **only** rated-gated field: on a casual game
the rating columns are never written (`apply_live_rating` returns `:ok` with no
writes on `:unrated`), so emitting a tier would be meaningless *and* violate "casual
leads with Veteran/Mastery, not a loud skill number" — hence `rating: nil`.

### 2. Capture before/after in the `apply_completed_game/5` loop

Today the per-participant loop (`profiles.ex:263-273`) runs `apply_one` / `apply_xp`
/ `apply_playstyle` as blind increments — no before-value is captured. Refactor:

- **One BEFORE read at the top of each participant's loop body.** Call
  `get_or_create_profile(valid_id)` once before the writers and keep
  `%{veteran_xp, rating_mu, rating_sigma, rating_games_count}` as the snapshot. The
  writers already each call `get_or_create_profile` internally; the up-front read is
  cheap and gives a single coherent before-snapshot. Accumulate
  `%{user_id => before_snapshot}` across the loop.
- **Compute the xp delta where it's known.** `apply_xp` already computes
  `delta = Progression.xp_for_game(team_score, won?)` and reads `new_xp` after the
  inc. Surface both (return `{:ok, %{xp_earned: delta, veteran_xp_after: new_xp}}`
  from `apply_xp` instead of `:ok`) so the loop has the XP deltas without re-reading.
- **Rating before/after from `apply_live_rating`.** `priors` (the before μ/σ for the
  four rated ids) and `updated` (the after μ/σ) already exist locally in
  `apply_live_rating`. Have it **return** a `%{user_id => %{before: {mu,sigma},
  after: {mu,sigma}, count_before, count_after}}` map (empty on `:unrated`) instead
  of `:ok`. `count_before` comes from the BEFORE snapshot; `count_after = before + 1`.
- **Achievements** already return `%{user_id => [keys]}` from
  `apply_live_achievements`.
- **Assemble** at the end of `apply_completed_game/5`: for each valid-UUID
  participant, call `PostGameSummary.build(before_snapshot, deltas, [])` where
  `deltas` merges the xp deltas, the rating map slice (or `rated?: false`), and the
  newly-earned keys, and build `%{user_id => summary_map}`.

**New return:**

```
# BEFORE: {:ok, %{user_id => [newly_earned_key]}}
# AFTER:  {:ok, %{user_id => summary_map}}
```

Achievements stop being the top-level value and become the `achievements_unlocked`
field of each summary. All work stays inside the existing `Repo.transaction` — the
summary is built from in-transaction reads, but **not persisted**. The arity-2 shim
and the non-map fallback clause (`{:ok, %{}}`) keep their shapes (empty map).

**Justification — no rebuild concern.** The summary is ephemeral; nothing is
written, so `rebuild_from_history/1` / `rebuild_all/0` are untouched. The
live/rebuild parity contract the other tickets rely on is unaffected — we only
*read before* and compute pure classifications.

### 3. Propagate out of `save_completed_game/4` + post-commit broadcast

`Stats.save_completed_game/4` currently asserts `{:ok, _newly_earned}` and discards
it (`stats.ex:410`), then returns `:ok`. Change it to capture the summaries map out
of the transaction and **return it** to the caller:

```
# BEFORE: @spec save_completed_game(...) :: :ok
# AFTER:  @spec save_completed_game(...) :: {:ok, summaries :: map()} | :ok
```

On the idempotent short-circuit (`%GameStats{}` already saved → `:ok`) and on a
failed/rolled-back transaction, return `:ok` (no summaries) — so no summary is ever
pushed for a re-fire or a rollback. On success, return `{:ok, summaries}` where
`summaries` is the `%{user_id => summary_map}` from `apply_completed_game`.

The **RoomManager** `:game_over` handler (`room_manager.ex:1774`) currently does
`:ok = Stats.save_completed_game(...)`. Change it to match on the new return and,
on `{:ok, summaries}` with a non-empty map, fire a **new** PubSub broadcast on the
same topic **after** the DB commit:

```
Phoenix.PubSub.broadcast(
  PidroServer.PubSub,
  "game:#{room_code}",
  {:progression_summary, room_code, summaries}
)
```

**Justification — a SEPARATE post-commit broadcast.** The existing
`{:game_over, room_code, winner, scores}` is emitted by **GameAdapter**
(`game_adapter.ex:333`) the instant the engine reaches `:complete` — *before*
RoomManager runs `save_completed_game`. At that moment the summary does not exist
yet (the profile writes haven't happened). Folding the summary into the existing
`game_over` would mean deferring that broadcast until after persistence, delaying
the always-present `%{winner, scores}` skeleton behind a DB transaction and coupling
two concerns. A second, additive broadcast fired from RoomManager **after the commit
succeeds** keeps the base `game_over` instant and unchanged, and guarantees the
summary only ships once the data is durably committed (rollback → no `{:ok,
summaries}` → no broadcast).

### 4. Channel push — per-player slice

`GameChannel` adds a `handle_info` for the new message that pushes each socket only
ITS own slice (research confirmed `socket.assigns.user_id` is available —
`game_channel.ex:85, 545, 620`):

```
def handle_info(
      {:progression_summary, room_code, summaries},
      %{assigns: %{room_code: room_code, user_id: user_id}} = socket
    ) do
  push(socket, "progression_summary", Map.get(summaries, user_id, %{}))
  {:noreply, socket}
end
```

**Event name:** `"progression_summary"`. **Decisions:** per-socket privacy (each
client gets only their own deltas — the broadcast carries the full keyed map but the
channel slices it; clients never see opponents' skill movements), and an **empty map
fallback** when a socket's `user_id` isn't a participant (spectator / bot-only seat)
so the handler never crashes. The `{:close_room, ...}` timer stays owned by the
existing `game_over` handler — `progression_summary` does no scheduling.

### 5. Rated-vs-casual at completion

Reuse the single shared predicate: `rated? = match?({:ok, _}, rated_game?(player_results))`
(`profiles.ex:618`), computed once in `apply_completed_game`. It threads into each
summary's `deltas.rated?`. Casual ⇒ `rating: nil` (and the rating columns were never
written), XP/level/achievements still populate. No new flag.

## ExUnit test list

### Pure builder — `PostGameSummary` (`test/pidro_server/profiles/post_game_summary_test.exs`)

1. **always-xp fallback** — a casual loss with `xp_earned: 0` still returns a
   complete `xp_earned`/`veteran_level*`/`veteran_title*`/`veteran_progress` block and
   `rating: nil`.
2. **leveled-up** — `veteran_xp_after` crossing a threshold ⇒ `leveled_up: true`,
   `veteran_level` > `veteran_level_before`; a same-level game ⇒ `leveled_up: false`.
3. **title change** — crossing a title boundary (e.g. level 20) sets
   `title_changed: true` and the new `veteran_title`; otherwise `false`.
4. **rated tier move up** — winner whose ordinal rises across a band cut ⇒
   `rating.direction == "up"`, `tier_after` > `tier_before`.
5. **rated tier move down** — loser whose ordinal falls ⇒ `direction == "down"`.
6. **rated no tier move** — μ/σ change but same band ⇒ `direction` per ordinal sign,
   `tier_before == tier_after`.
7. **provisional clear** — before provisional, after clears (count crosses
   `min_games`, σ below `max_sigma`) ⇒ `provisional_before: true`,
   `provisional_after: false`.
8. **casual omits tier** — `rated?: false` ⇒ `rating == nil`, all Veteran fields
   present.
9. **achievements included** — `newly_earned_keys: [:player, :winner]` ⇒
   `achievements_unlocked` has both with `name`/`tier` from `Catalog`; unknown key
   dropped.
10. **empty achievements** — `newly_earned_keys: []` ⇒ `achievements_unlocked: []`.
11. **veteran_progress normalization** — `:max` from `level_progress` ⇒
    `%{into: 0, span: 0, max: true}`; finite ⇒ `%{into, span, max: false}`.
12. **Jason-encodable** — `Jason.encode!(build(...))` succeeds (no tuples leak;
    atom values serialize to strings).

### Integration — completion produces summaries (`profile_rollup_test.exs`)

13. **completion returns `%{user_id => summary_map}`** — a 4-human rated game:
    `apply_completed_game` returns a summary per participant with `rated: true`, a
    populated `rating`, and the correct `xp_earned` (winners 112, losers 45).
14. **achievements live in the summary** — the 10th-game case (currently the
    `newly` assertion at `profile_rollup_test.exs:483`) ⇒ `:player` appears in the
    user's `achievements_unlocked` field, not as the top-level value; a later game
    does not re-report it.
15. **casual vs rated** — a single-player / bot-filled game ⇒ summary has
    `rated: false`, `rating: nil`, and a full Veteran block; a 4-human game ⇒
    `rated: true`, populated `rating`.
16. **rollback ⇒ no summaries** — forced rollback (the existing atomicity test
    pattern) leaves no profile changes; `save_completed_game` returns `:ok` (not
    `{:ok, _}`); the new broadcast is not fired.
17. **idempotent re-fire ⇒ no second broadcast** — re-sending `:game_over` hits the
    `%GameStats{}` short-circuit ⇒ `save_completed_game` returns `:ok` ⇒ no
    `progression_summary` broadcast the second time.

### Channel — per-user push (`game_channel_test.exs`)

18. **pushes per-user `progression_summary`** — broadcast
    `{:progression_summary, room_code, %{user_id => summary}}` on `"game:#{code}"`;
    `assert_push "progression_summary", ^summary` where `^summary` is exactly the
    socket's own slice.
19. **only THEIR slice** — a summaries map with two users pushes only this socket's
    `user_id` slice, never the other player's deltas.
20. **non-participant socket ⇒ empty map** — a `user_id` absent from `summaries`
    pushes `%{}` and does not crash.
21. **base `game_over` unchanged** — `{:game_over, ...}` still pushes
    `%{winner, scores}` (regression guard; currently no such assertion exists).

## Ordered checklist

1. Add the pure module `PidroServer.Profiles.PostGameSummary` with `build/3` +
   doctests (XP block, `veteran_progress` normalization, rating block via
   `Tier`/`Rating.ordinal`, `achievements_unlocked` via `Catalog`).
2. Write `post_game_summary_test.exs` (tests 1–12); green.
3. Refactor `apply_xp/3` to return `%{xp_earned, veteran_xp_after}`; refactor
   `apply_live_rating/2` to return `%{user_id => %{before, after, count_before,
   count_after}}` (empty on `:unrated`).
4. Refactor `apply_completed_game/5`: read the BEFORE snapshot per participant,
   thread the xp/rating/achievement deltas, assemble `%{user_id => summary_map}` via
   `PostGameSummary.build/3`; change the return. Keep the arity-2 shim + non-map
   fallback returning `{:ok, %{}}`. Update the `@spec` and `@doc`.
5. Update `save_completed_game/4` to capture the summaries out of the transaction
   and return `{:ok, summaries}` on success, `:ok` on short-circuit/rollback. Update
   `@spec`.
6. Update RoomManager `:game_over` handler to match the new return and fire the
   post-commit `{:progression_summary, room_code, summaries}` broadcast (only on
   `{:ok, summaries}` with a non-empty map).
7. Add the `GameChannel` `handle_info({:progression_summary, ...})` that pushes the
   per-user slice as `"progression_summary"`.
8. Extend `profile_rollup_test.exs` (tests 13–17) — adapt the existing achievement
   return-value assertions to the new summary shape.
9. Add channel push tests (tests 18–21) to `game_channel_test.exs`.
10. `mix precommit` (format, compile, test, dialyzer, credo) green.

## Files to create / modify

**Create**
- `apps/pidro_server/lib/pidro_server/profiles/post_game_summary.ex` — the pure builder.
- `apps/pidro_server/test/pidro_server/profiles/post_game_summary_test.exs` — builder tests.

**Modify**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` — BEFORE snapshot in the
  loop; `apply_xp`/`apply_live_rating` return deltas; `apply_completed_game/5`
  assembles + returns `%{user_id => summary_map}`; updated `@spec`/`@doc`.
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — `save_completed_game/4`
  returns `{:ok, summaries}` on success.
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex` — `:game_over` handler
  fires the post-commit `{:progression_summary, ...}` broadcast.
- `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex` — new
  `handle_info` pushing the per-user `"progression_summary"`.
- `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs` — summary
  return assertions.
- `apps/pidro_server/test/pidro_server_web/channels/game_channel_test.exs` —
  per-user push tests.
