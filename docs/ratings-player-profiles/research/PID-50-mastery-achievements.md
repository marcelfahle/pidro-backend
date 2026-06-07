---
date: 2026-06-07
ticket: PID-50
status: complete
title: Mastery achievements — data availability for the curated Pidro 1 set + partnership
---

# PID-50 — Mastery achievements: research

## Summary

The central scoping fact: **the persisted `game_stats` row holds only end-of-game
aggregates plus exactly ONE bid number (`bid_amount`/`bid_team`) that represents
the LAST hand's winning bid, NOT a per-hand or per-player record.** There is **no
per-round, per-hand, or per-player bid/points data persisted anywhere**. The live
`Pidro.Core.Types.GameState` at completion is also mostly a *last-hand* snapshot:
at every new hand the engine resets `highest_bid`, `bids`, `tricks`, `hand_points`,
`trump_suit`, etc. (`engine.ex:667-684`). The ONE field that accumulates the whole
game is `state.events` (event-sourced log, appended `events ++ [event]` at
`engine.ex:381`, never reset across hands). So per-hand history (every bid, every
`hand_scored` delta, the forced bid, max-point rounds, round count) exists **live,
in `events`, only** — and is **NOT persisted**.

Consequently the 10 curated achievements split sharply:

- **(A) rebuildable from `game_stats` today:** Player (10 games), The Winner (5 wins),
  Winstreak (consecutive wins by `completed_at`), Ace (max-score game),
  The Loser (negative final score). Plus the partnership achievement (a 4-human
  rated game — same predicate ratings use).
- **(B) computable only from LIVE final state (would need new persistence/migration
  to be rebuildable):** Homerun (bid 14 made), Forcer (made the forced bid),
  Full House (a round at max points), Unstoppable (win in ≤N rounds). These need
  the `events` log or per-hand fields, which today are passed live into
  `save_completed_game/4` but thrown away.
- **(C) absent entirely:** none of the 10 are strictly (C) *if* the engine
  `events` log is read at completion — but several (B) items become (C) if you
  only look at the currently-persisted columns and don't add capture, because the
  live `GameState` snapshot alone (sans `events`) only knows the LAST hand.

No `player_achievements` table exists. The eval seam is `Profiles.apply_completed_game/4`
(live) + `Profiles.rebuild_from_history/1` (rebuild), exactly where counters/XP/rating
already hook. The data-driven-definition idiom to copy is `Progression`'s
`@defaults` map + `Application.get_env` `config/1` fallback.

---

## Persisted `game_stats` data

Schema: `apps/pidro_server/lib/pidro_server/stats/game_stats.ex:12-24`.
Migrations: `priv/repo/migrations/20251102100750_create_game_stats.exs` (+ `:player_results`
added by `20260308083652_add_player_results_to_game_stats.exs`). `binary_id` PK,
`@foreign_key_type :binary_id`.

| Column | Type | Shape / meaning |
|---|---|---|
| `id` | `binary_id` | PK, autogenerate |
| `room_code` | `string` | required |
| `winner` | `string` | `"north_south"` \| `"east_west"` (validated, `game_stats.ex:43`) |
| `final_scores` | `:map` (JSONB) | per-TEAM final cumulative score, e.g. `%{north_south: 62, east_west: 41}`. **CAN go negative** (`config.allow_negative_scores: true`; scorer subtracts a failed bid, `scorer.ex:318-321`). Winning target = **62** (`scorer.ex:360`, `gamestate.ex:118`). |
| `bid_amount` | `integer` | validated **6..14** (`game_stats.ex:47`). **This is ONE number for the whole game** = the `highest_bid` amount in the live `GameState` at completion, i.e. the **winning bid of the LAST hand only** (see below). NOT per-round, NOT per-player, NOT the forced-bid flag. |
| `bid_team` | `string` | team of that last-hand bidder (`stats.ex:456-470`). |
| `duration_seconds` | `integer` | wall-clock `now - room.created_at` (`stats.ex:306`). |
| `completed_at` | `utc_datetime` | required; ordering key for Winstreak/rerate cursor. |
| `player_ids` | `{:array, binary_id}` | `Map.keys(player_results)` — UNORDERED (`stats.ex:318`). |
| `player_results` | `:map` (JSONB) | `%{user_id => %{participation, result, team, position}}` where `result ∈ {:win,:loss}`, `participation ∈ {:played,:abandoned,:substitute}`, `team`, `position` (`stats.ex:406-416`). String-keyed after JSONB round-trip. |

**Writer:** `Stats.save_completed_game/4` (`stats.ex:298-344`). It is idempotent
(`Repo.get_by(GameStats, room_code:)` guard, `stats.ex:300`), derives `bid_info`
via `extract_bid_info(game_state)` from `game_state.highest_bid` (`stats.ex:456-472`),
builds `player_results` from `room.seats`, and inside one transaction inserts the
row then calls `Profiles.apply_completed_game(player_results, winner, scores)`
(`stats.ex:326`).

**Confirmed: there is NO per-round or per-player bid/points data persisted.** No
hand log, no per-player bid, no trick/round table. The only numeric "bid" stored is
the single last-hand `bid_amount`.

---

## Live final game-state data (the completion path)

Trace: `RoomManager.handle_info({:game_over, room_code, winner, scores}, …)`
(`room_manager.ex:1755-1783`) → fetches `GameAdapter.get_state(room_code)` →
`Stats.save_completed_game(finished_room, winner, scores, game_state)` (`room_manager.ex:1774`).
`scores`/`winner` originate in `GameAdapter.broadcast_game_over/2` (`game_adapter.ex:348-357`):
`winner = state.winner`, `scores = state.scores || state.cumulative_scores`. The
game-over fires when the engine reaches `phase: :complete` (`game_adapter.ex:332`,
`engine.ex:644-651`).

The `game_state` passed in is `Pidro.Core.Types.GameState`
(`apps/pidro_engine/lib/pidro/core/types.ex:236-331`). Relevant fields:

- `cumulative_scores :: %{team => integer}` — per-team final score (can be negative).
- `winner :: team | nil`.
- `highest_bid :: {position, 6..14} | nil`, `bidding_team`, `trump_suit`,
  `bids :: [%Bid{position, amount}]`, `tricks :: [%Trick{}]`,
  `hand_points :: %{team => non_neg_integer}`, `trick_number`, `hand_number`,
  `current_dealer`.
- `events :: [event()]` — the event-sourced log.

**CRITICAL: the snapshot is a LAST-HAND snapshot.** At `:hand_complete` →
new hand, the engine resets (`engine.ex:667-684`): `highest_bid → nil`,
`bidding_team → nil`, `trump_suit → nil`, `bids → []`, `tricks → []`,
`current_trick → nil`, `trick_number → 0`, `hand_points → %{…0…}`,
`discarded_cards`, `killed_cards`, etc., and per-player `tricks_won → 0`. So at
`:complete`, `highest_bid`/`bids`/`tricks`/`hand_points` describe ONLY the final
hand. `hand_number` does survive (incremented in `Dealing.rotate_dealer`,
`dealing.ex:168`) and equals the number of hands played.

**The only whole-game record is `state.events`** (appended via
`record_event` = `events ++ [event]`, `engine.ex:381`; NOT in the hand reset list).
Event types (`types.ex:172-187`) include `{:bid_made, pos, amt}`,
`{:bidding_complete, pos, amt}`, `{:hand_scored, team, points}`,
`{:game_won, team, score}`, `{:trick_won, pos, points}`, `{:player_went_cold,…}`.
**This log is the live source for every (B) achievement** — but it is **not persisted**
(no column stores `events`).

---

## Engine scoring model

Authoritative config (`gamestate.ex:114-122`, `types.ex:317-327`):
`min_bid: 6, max_bid: 14, winning_score: 62, initial_deal_count: 9,
final_hand_size: 6, allow_negative_scores: true`.

- **Game target:** first team to **≥ 62** cumulative points wins
  (`scorer.ex:359-361 game_over?`, `state_machine.ex:384-388`). Ties at 62+ →
  bidding team wins (`scorer.ex:392-403`).
- **Max points per round (hand):** **14** total available
  (`scorer.ex:18`, `total_available_points/1 scorer.ex:437-468` returns 14, less any
  non-top killed point cards). So a "max-points round" / Full House = a team taking
  the full **14** in one hand.
- **Bids:** range **6..14** (`types.ex:117 bid_amount :: 6..14`). One winning bid
  per HAND, by the highest bidder; that hand's bidding team must make ≥ bid points.
- **Forced bid rule ("Forcer"):** if the 3 players before the dealer all pass,
  **the dealer MUST bid 6 (cannot pass)** (`bidding.ex:29, 133-139 :dealer_must_bid`,
  `bidding.ex:386 all_passed? → dealer forced to min 6`). Detectable LIVE from
  `events`/bid sequence (dealer's bid == 6 following three passes), or via the
  `bidding.ex` predicates — **not** from the persisted single `bid_amount`.
- **Negative scores:** when the bidding team takes fewer points than its bid, the
  scorer does `old - bid_amount` (`scorer.ex:316-322`); `allow_negative_scores: true`
  lets cumulative go below zero. So "The Loser = lose with negative final score" is
  read directly from `final_scores` (persisted).
- **Number of rounds (hands):** not fixed; a game runs until a team hits 62.
  `hand_number` (live, survives resets) = hands played. For Pidro-2 calibration: max
  14 pts/hand toward 62 means a fast game is roughly 5+ hands; "Unstoppable = win in
  few rounds" should be re-derived against 62 (e.g. ≤ N hands where N reflects an
  unusually efficient run, candidate ~5–6), NOT a Pidro-1 number. `hand_number` is
  the round counter but is **only live**, not persisted.

---

## Per-achievement data-availability table

Pidro-2 calibration basis: game to **62**, **14** max pts/hand, bids **6..14**,
negative scores allowed, forced bid = dealer stuck at **6**.

| # | Achievement | Class | Exact field(s) / source | Proposed Pidro-2 threshold (tier I) |
|---|---|---|---|---|
| 1 | **Player** — finish N games | **A** | `profile.games_played`, or count `game_stats` where `user_id ∈ player_ids` | finish **10** games (count includes all participation) |
| 2 | **The Winner** — win N games | **A** | `profile.wins`, or count `won_game?(game,user)` over history | win **5** games |
| 3 | **Winstreak** — consecutive wins (tiered x3/x5/x10) | **A** | per-user `game_stats` ordered by `completed_at` (asc), run-length of `result == :win` (`Profiles.won_game?/2`) | tier I only at launch: **3** consecutive wins (x5/x10 deferred) |
| 4 | **Ace** — max-score game | **A** | `final_scores[user_team]` from persisted `final_scores` | reach the winning target — final team score **≥ 62** (every win qualifies → may want a higher bar, e.g. **≥ 62 while opponent ≤ small**; with current data only "≥62" is cleanly computable) |
| 5 | **The Loser** — lose with negative points | **A** | `final_scores[user_team] < 0` (negative allowed, `scorer.ex:318`) | finish a game with own team's final score **< 0** |
| 6 | **Partnership** (the one PARTNERSHIP achievement) | **A** | `player_results` 2+2 split = the rated-game predicate `Profiles.rated_game?/1`; partner = same `team`, win together | win a **4-human** game (2v2 of distinct UUIDs) with your fixed partner — reuses the existing `rated_game?` shape; tier I = **1** such partnered win |
| 7 | **Homerun** — bid 14 and make it | **B** | LIVE: `events` `{:bidding_complete, pos, 14}` for the user's team in a hand where that team's `hand_scored` delta ≥ 14 (made it). Persisted `bid_amount` is only the LAST hand's bid, so **not** reliably derivable; NOT rebuildable without capture. | bid **14** in a hand and make the bid (take ≥14). Needs live `events` capture + new persistence to be rebuildable. |
| 8 | **Forcer** — make the forced bid | **B** | LIVE: `events`/bid sequence where dealer was forced to **6** (3 prior passes) AND that hand's bidding team made it (`hand_scored` ≥ 6). Not in persisted columns. | as dealer, be forced to bid **6** and still make it. Live-only today. |
| 9 | **Full House** — win a round at max points | **B** | LIVE: a hand where the user's team `hand_scored` delta == **14** (all 14 captured). Per-hand deltas exist ONLY in `events` (and the last hand's `hand_points`); not persisted. | take all **14** points in a single hand. Live-only today. |
| 10 | **Unstoppable** — win in few rounds | **B** | LIVE: `hand_number` at `:complete` (survives resets) = hands played; win with `hand_number ≤ N`. Not persisted. | win a game in **≤ ~5–6 hands** (re-derive vs 62; exact N a tuning decision). Live-only today. |

Notes:
- (A) items are rebuildable by `rebuild_from_history/1` from existing columns,
  mirroring how counters/XP already rebuild.
- (B) items (7–10) are evaluable at completion from the live `game_state`
  (`events` log + `hand_number`) but are **lost once the game is saved**. To make
  them rebuildable from history you would need to persist either the `events` log
  (or a derived per-hand summary: each hand's bidding team, bid amount, forced flag,
  per-team hand points) into a new column/table — a migration + writer change. None
  is strictly (C) as long as the engine `events` are read in the completion seam;
  they only become impossible if neither persisted nor read live.
- No achievement requires brand-new engine instrumentation (true (C)) — the `events`
  log already records bids, forced minimum, per-hand scores, trick wins, and game-won
  score. The gap is purely *persistence/capture*, not *engine knowledge*.

---

## Achievement persistence + eval seam + rebuild

**No `player_achievements` table exists.** Migrations present:
`create_users`, `create_game_stats`, `add_player_results_to_game_stats`,
`create_abandonment_events`, `create_email_templates`, `add_key_to_email_templates`,
`create_player_profiles` (`20260607000000`), `create_rating_state` (`20260607010000`).
PID-44 deferred the separate achievements table to PID-50; that table still needs
to be created.

**Conventions to match** (`player_profiles.ex`, `create_player_profiles.exs`):
`@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`,
`field :user_id, :binary_id` (loose, **no FK** — deliberately mirrors
`game_stats.player_ids`), `timestamps(type: :utc_datetime_usec)`, lazy
`get_or_create` with `on_conflict: :nothing` + unique index on the natural key.
A `player_achievements` table would most idiomatically be one row per
(user_id, achievement_key) with `earned_at`, `tier` (1 for launch), maybe a
binary_id PK + unique index on `[:user_id, :achievement_key]`, and `:map` for any
captured evidence/metadata.

**Completion seam (live):** `Profiles.apply_completed_game/4`
(`profiles.ex:159-181`) runs inside the `save_completed_game/4` transaction
(`stats.ex:323-332`). Today it does (1) per-participant counters + veteran XP and
(2) `apply_live_rating/2`. Achievement evaluation hooks here — it has
`player_results`, `winner`, `scores` in scope. **To evaluate the (B) achievements it
would additionally need the live `game_state`/`events`**, which `save_completed_game/4`
already receives as its 4th arg but does NOT forward to `apply_completed_game` (it
currently passes only `player_results, winner, scores`, `stats.ex:326`). Forwarding
`game_state` (or a derived per-hand summary) is the seam change required for (B).

**Rebuild seam:** `Profiles.rebuild_from_history/1` (`profiles.ex:194-219`) and
`rebuild_all/0` (`profiles.ex:228-238`), driven by
`mix pidro.rebuild_profiles` (`lib/mix/tasks/pidro.rebuild_profiles.ex:19`). It
scans `from(gs in GameStats, where: ^user_id in gs.player_ids)` and recomputes
counters/XP. (A)-class achievements drop straight into this scan. **Winstreak**
specifically needs the per-user games **ordered by `completed_at`** (the rebuild
query is currently unordered — `won_game?/2` + an `order_by: [asc: :completed_at]`
gives consecutive-win runs; `ordered_games_query/0` at `profiles.ex:443` shows the
canonical `[asc: completed_at, asc: inserted_at, asc: id]` total order). (B)-class
achievements are **not** rebuildable from current history (their evidence isn't
persisted) unless the events/per-hand summary is added to `game_stats`.

Permanence ("permanent once earned") fits an insert-once table with
`on_conflict: :nothing` — re-running rebuild never revokes an earned row.

---

## Data-driven definition options

The ticket requires definitions as DATA, not hardcoded branches. Idioms already in
the repo:

1. **`@defaults` map + `Application.get_env` fallback (`config/1`)** —
   `PidroServer.Progression` (`progression.ex:40-58`, `config/1` at `:259-262`:
   `Application.get_env(:pidro_server, __MODULE__, [])` then `Keyword.get(…, key,
   Map.fetch!(@defaults, key))`). This is the established pattern for tunable
   thresholds (XP bonuses, curve params, level titles). Achievement thresholds
   (10 games, 5 wins, streak length, "few rounds" N, score targets) would live here.
2. **Tier/band lookup tables** — `PidroServer.Rating.Tier` and
   `Progression`'s `titles` map (level → title) show the repo's pattern for
   data-as-config band tables; achievement tiers (I/II/III) map the same way.
3. **A definitions list** — the most natural model: a module exposing a list of
   `%{key, name, tier, class: :A|:B, predicate}` (or a behaviour with one
   `evaluate(ctx) :: boolean` callback per def) so "adding more is cheap." Each def
   declares what context it reads (history aggregate vs live events), letting the
   evaluator route (A) defs through `rebuild_from_history` and (B) defs through the
   live seam. No such module exists yet; `Progression`/`Heritage` are the closest
   "pure rules as data/functions" precedents to imitate.

---

## Existing achievement/badge/mastery code

**None.** Grepping `achievement|badge|mastery` across the codebase returns only:
- `stats.ex:266` doc comment ("profile badges in a future phase") — aspirational, no code.
- `progression.ex` "milestone" titles — that's veteran levels (PID-49), not achievements.
- web `card_components.ex` / dev LiveViews — UI card rendering, unrelated.

There is no achievement schema, context, evaluator, definition list, or migration.
PID-50 is greenfield on top of the PID-44 profile store + completion seam.

---

## Open questions

1. **Should (B) achievements (Homerun, Forcer, Full House, Unstoppable) be
   launch-scope?** They are evaluable LIVE but **not rebuildable** from current
   history. Either (a) ship them live-only (no backfill for games before PID-50),
   or (b) add a persisted per-hand summary / `events` column to `game_stats` (new
   migration + writer change in `save_completed_game/4`) so they rebuild like (A).
2. **Forward `game_state` into `apply_completed_game`?** Required for (B) eval. The
   4th arg already reaches `save_completed_game/4`; needs threading into the
   profiles seam (and a derived per-hand summary, since the raw `GameState` snapshot
   is last-hand-only — the `events` log is the real source).
3. **"Ace" / max-score definition.** With only `final_scores`, every win is ≥62, so
   "max-score game" needs a sharper bar (e.g. opponent held low, or won by a margin)
   — decide what "max-score" means under the 62 target.
4. **"Unstoppable" N (few rounds).** `hand_number` is live-only; pick N against the
   62 target (candidate ≤5–6) and decide whether to persist `hand_number` to make it
   rebuildable.
5. **Partnership identity.** `player_results` records `team`+`position` but not a
   stable partner pairing across games; "with the same partner" (if intended) needs
   pairing both users' UUIDs — derivable per game from `player_results` (same team),
   but cross-game "same partner" tracking is not modeled.
6. **Achievement table shape** — confirm one-row-per-(user, key) with `tier` +
   `earned_at` + optional `:map` evidence, binary_id, no FK (matching
   `player_profiles`), unique `[:user_id, :achievement_key]`.
