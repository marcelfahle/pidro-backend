---
title: "feat: Pidro 1 → Pidro 2 progression carry-over — the pure mapping (PID-53)"
type: feat
status: active
date: 2026-06-07
linear: PID-53
origin: docs/ratings-player-profiles/research/PID-53-migration-carryover.md
---

# feat: Pidro 1 → Pidro 2 progression carry-over (PID-53)

## Overview

PID-53 is the **pure mapping** that turns a Pidro 1 player's progression into a
Pidro 2 `player_profiles` row, so a migrated user "lands already showing" their
Veteran level + title, Heritage badges, premium recognition, a Provisional skill
tier, and (where available) their playstyle needle + average winning bid.

Every write target already exists and ships with safe defaults (PID-44..PID-52):
the veteran/XP columns, the playstyle accumulators, `heritage_flags`, and the
rating columns. The `Heritage` module was **built explicitly for PID-53 to
populate** (its `@moduledoc`: "PID-53 (account migration) populates them on
import."). The legacy XP→level curve is the **same curve** `PidroServer.Progression`
already carries (PID-49 lifted it verbatim from `pidro_api`), so mapping legacy XP
onto a Pidro 2 level is exact: keep the XP, recompute the level.

This ticket is **one clean, idempotent function** — `Profiles.import_legacy_progression/2`
— that consumes a well-defined `legacy_data` contract supplied by the (separate)
bridge/claim flow, builds **one `PlayerProfile.changeset/2`**, and writes it in a
single transaction. It does NOT build an entitlement system, does NOT parse legacy
blobs, and does NOT touch auth. Per `apps/pidro_server/CLAUDE.md`: pure mapping,
single source of truth, minimal persistence, thin wiring.

## Non-Goals (explicit scope cuts — owned elsewhere)

- **The auth / claim / bridge flow.** The magic-link / `?migrate=TOKEN` /
  `pidro.online` website-bridge sign-in + one-time-signed-claim redemption is a
  **SEPARATE ticket**. PID-53 only consumes the resulting `legacy_data` map. No
  token, no HTTP, no `Accounts` change here.
- **Parsing legacy blobs.** The per-round bidder + bid amount needed for playstyle
  lives only inside the legacy `game_play_data.RoomData` JSON blob (research §4.4).
  **The bridge pre-aggregates that into the optional `playstyle` field**; PID-53
  takes the pre-aggregated counts and never opens `RoomData` / `round_scores` /
  `user_badges` blobs. (Open Question 1 in the research — `RoomData` internal shape
  — is the bridge's problem, not ours.)
- **A real premium / entitlement / subscription system.** Pidro 2 models **no**
  premium at all (the `users` schema is `username/email/password_hash/guest`; no
  purchases table, no IAP — research §3.4). PID-53 records legacy premium as a
  **display-only Heritage flag** and stops there. The real entitlement system
  (new-client IAP dependency) is a wholly separate concern. **Justification:** there
  is no entitlement column to write to, and inventing one now would be speculative
  scope an honest mapping must refuse. A Heritage flag satisfies "lands already
  showing premium" (recognition) without faking an entitlement the game can't honor.
- **Importing legacy per-game history into `game_stats`.** Skill is **re-earned** in
  Pidro 2, not replayed. We do NOT backfill `game_stats` rows, do NOT seed an
  authoritative rating, and do NOT touch the rerate cursor/jobs. (Veteran XP is kept
  as dedication; skill starts fresh + Provisional — research §1 "separate dedication
  from skill".)
- **A new schema column.** No `migrated_at` / `legacy_id` column. The idempotency
  marker is `heritage_flags["played_pidro_one"]` — no migration needed (research
  §6, Open Question 4). A dedicated audit column is a deferred option, not v1.

## The `legacy_data` Input Contract

Since the bridge is a separate ticket, PID-53 **defines** the contract it consumes.

**Decision: a small struct, `PidroServer.Profiles.LegacyProgression`**, not a bare
map. Justification: it documents the exact shape in one place, gives the mapping a
single typed input to pattern-match, defaults every optional field so "nil/missing
tolerated" is structural (not scattered `Map.get`s), and gives the future bridge a
named build target. It is a plain struct (no Ecto, no DB) — pure data.

```elixir
defmodule PidroServer.Profiles.LegacyProgression do
  @type playstyle :: %{
          bidding_attempts: non_neg_integer(),
          bidding_wins: non_neg_integer(),
          won_bid_sum: non_neg_integer()
        }

  @type t :: %__MODULE__{
          xp: non_neg_integer(),            # REQUIRED. legacy users.xp (lifetime).
          badges: [String.t()],             # legacy badge/accolade names. default [].
          premium: boolean(),               # active-premium decision. default false.
          founding_member: boolean(),       # pre-launch cohort. default false.
          playstyle: playstyle() | nil      # pre-aggregated by the bridge. default nil.
        }

  defstruct xp: 0, badges: [], premium: false, founding_member: false, playstyle: nil
end
```

**Field contract (types + required/optional):**

| Field | Type | Req? | Source (legacy) | Notes |
|---|---|---|---|---|
| `xp` | `non_neg_integer` | **Required** | `users.xp` (lifetime) | The only field needed for Veteran. Defaults to `0` if a caller omits it (→ level 1) but the bridge always supplies it. |
| `badges` | `[String.t()]` | Optional (`[]`) | `user_badges.AchievementData` names | Opaque legacy strings; routed to `legacy_accolades` (display-only, no catalog coupling). |
| `premium` | `boolean` | Optional (`false`) | `now < users.premium_until` | **Bridge computes the boolean** (it owns the `premium_until`/`premium_product` data). PID-53 receives the minimal decision, not a date. Justification: a boolean is all a display-only Heritage flag needs; no entitlement window to track. |
| `founding_member` | `boolean` | Optional (`false`) | bridge cohort rule | Display-only. |
| `playstyle` | `%{bidding_attempts, bidding_wins, won_bid_sum}` \| `nil` | Optional (`nil`) | bridge aggregation of `game_play_data.RoomData` | When `nil` → playstyle accumulators stay 0 (graceful degrade → `:insufficient` on screen). `won_bid_count == bidding_wins` (a winning bid == a won round), so no separate count field. |

**Tolerance rule:** `import_legacy_progression/2` accepts either a
`%LegacyProgression{}` **or** a plain map; a plain map is normalized into the struct
(`struct(LegacyProgression, map)`), so any missing/`nil` field falls to its struct
default. This keeps the bridge loosely coupled (it may hand us a map) while the
mapping body works against one typed shape.

## Field-by-field Mapping (legacy → Pidro 2)

All targets are in `PlayerProfile`'s `@castable` (already), so one `changeset/2`
writes them. **Every write is an ABSOLUTE set** (not an increment) — that is what
makes a forced re-run safe even past the guard.

| Legacy input | Pidro 2 target | Value written | Why |
|---|---|---|---|
| `xp` | `veteran_xp` | `legacy.xp` (kept verbatim) | Dedication never resets; XP is carried, not discarded (research §1, PID-49 curve parity). |
| `xp` | `veteran_level` | `Progression.level_for_xp(legacy.xp)` | Same curve as Pidro 1 → exact same level. (Cache; the screen recomputes it live too.) |
| — | `veteran_title` | *(derived on read)* | `Progression.title_for_level/1` at read time — not stored. |
| `badges` | `heritage_flags["legacy_accolades"]` | `legacy.badges` (list of strings) | **Routed to Heritage, NOT `player_achievements`.** Justification: Pidro 2 Mastery achievements are **re-earned** in-game and must match the live `Catalog`; legacy badge strings have no catalog keys (would silently not render — research §3.5). Heritage is the display-only origin surface built for exactly this. |
| `founding_member` | `heritage_flags["founding_member"]` | `legacy.founding_member` (bool) | Display-only Heritage badge (shows only when truthy). |
| `premium` | `heritage_flags["legacy_premium"]` | `legacy.premium` (bool) | **SCOPE CUT** — no entitlement system in Pidro 2; recorded as display-only recognition (see Non-Goals). |
| *(always)* | `heritage_flags["played_pidro_one"]` | `true` | The origin badge AND the idempotency marker. |
| `xp` | `heritage_flags["legacy_level"]` | `Progression.level_for_xp(legacy.xp)` | The "Legacy Level" display value (Heritage `:value` badge). Equals `veteran_level` by construction; carried for the dedicated badge. |
| `playstyle.bidding_wins` | `playstyle_bidding_wins` | absolute set (`0` if `playstyle == nil`) | Feeds the PID-51 needle. |
| `playstyle.bidding_attempts` | `playstyle_bidding_attempts` | absolute set (`0` if nil) | Needle denominator. |
| `playstyle.won_bid_sum` | `avg_winning_bid_sum` | absolute set (`0` if nil) | Avg-bid numerator. |
| `playstyle.bidding_wins` | `avg_winning_bid_count` | absolute set (= wins; `0` if nil) | `won_bid_count == wins` (PID-51 invariant). |
| — | `rating_mu` | `Rating.default/0` μ (`25.0`) | **No skill seed** (see below). |
| — | `rating_sigma` | `Rating.default/0` σ (`8.333`) | High uncertainty ⇒ Provisional. |
| — | `rating_games_count` | `0` | `< 10` ⇒ Provisional. |

**`heritage_flags` written (string keys — JSONB round-trips to strings, and
`Heritage.display/1` tolerates both):**

```elixir
%{
  "played_pidro_one" => true,
  "legacy_level"     => Progression.level_for_xp(legacy.xp),
  "legacy_accolades" => legacy.badges,           # [] when none
  "founding_member"  => legacy.founding_member,  # bool
  "legacy_premium"   => legacy.premium           # bool
}
```

`Heritage.display/1` renders these from its `@vocabulary`: `played_pidro_one`
("Played Pidro 1"), `founding_member` ("Founding Member"), `legacy_level` ("Legacy
Level"), `legacy_accolades` ("Legacy Accolades"). Boolean badges show only when
truthy; value badges show when non-nil. **Note:** `legacy_premium` has **no**
vocabulary entry today, so it is stored but not yet rendered by `display/1`.
**Tiny addition:** add `{:legacy_premium, "Pidro 1 Premium", :boolean}` to
`Heritage.@vocabulary` so the premium recognition badge actually shows. This is the
one small Heritage change PID-53 makes (keeps "lands already showing premium" true).

### Skill: no μ seed — `Rating.default/0` + count 0 (decided)

**Decision: v1 seeds NO skill from legacy strength.** Write `rating_mu`/`rating_sigma`
= `Rating.default/0` and `rating_games_count: 0`. Per `Tier.classify/1`, a player is
Provisional while `games_count < 10` OR `sigma >= 6.0`; defaults satisfy **both**
(`0 < 10` and `8.333 >= 6.0`), so the migrated user is **guaranteed Provisional on
arrival** — exactly the acceptance requirement.

**Justification for not seeding μ:** (a) it is the simplest, most honest mapping —
"provisional on arrival" with zero rated games is literally true; (b) legacy XP is
*dedication*, not 2v2 skill, and the legacy data has no clean 2v2-skill signal to
seed from (research §1, Open Question 3); (c) any μ nudge is a calibration risk that
must still keep σ ≥ 6.0 and count 0 to stay Provisional, so it changes nothing the
player sees at arrival (still Provisional) while adding tuning surface. A high-σ
legacy-strength μ seed is recorded as a **deferred tunable option**, not v1.

## The Seam — `Profiles.import_legacy_progression/2`

**Signature + return shape (decided):**

```elixir
@spec import_legacy_progression(Ecto.UUID.t() | User.t(), LegacyProgression.t() | map()) ::
        {:ok, PlayerProfile.t()} | {:ok, :already_migrated} | {:error, Ecto.Changeset.t()}
def import_legacy_progression(user_or_id, legacy_data)
```

- Accepts a `user_id` **or** a `%User{}` (resolve to `user_id`) — convenient for the
  future bridge call site, mirroring how the codebase passes ids around.
- `legacy_data` is a `%LegacyProgression{}` or a plain map (normalized via
  `struct/2`).
- Returns `{:ok, profile}` on a fresh import, `{:ok, :already_migrated}` when the
  idempotency guard short-circuits (distinct, explicit signal the caller can log),
  `{:error, changeset}` on a write failure.

**Mechanics (mirrors `rebuild_from_history/1` — single changeset write):**

1. Resolve `user_id`. `{:ok, profile} = get_or_create_profile(user_id)` (the
   race-safe lazy creator every writer uses).
2. **Idempotency guard:** if `profile.heritage_flags["played_pidro_one"] == true`,
   return `{:ok, :already_migrated}` without writing. The marker is set by the
   import itself, needs no new column, and protects post-migration gameplay (a
   re-run can never clobber XP the player earned *after* migrating).
3. Normalize `legacy_data` into a `%LegacyProgression{}`.
4. Build **one** `attrs` map (the full mapping table above) and write via
   `PlayerProfile.changeset(profile, attrs) |> Repo.update()`, **wrapped in
   `Repo.transaction/1`**. (One changeset = one statement; the transaction is the
   explicit single-write boundary and the seam for any future combined work.)
5. Return `{:ok, profile}` (the updated struct) or `{:error, changeset}`.

**Force option (decided): none in v1.** The guard is unconditional. Because every
write is an absolute set, a deliberate re-import would be safe value-wise, but it
would overwrite skill/playstyle a migrated user has since changed by playing — so we
do NOT expose a `force:` escape hatch. If a re-apply is ever needed it is a
deliberate, separate operational tool, out of scope here. (Documented in the
`@doc` as the rationale.)

**Why not `award_achievement/4`:** badges go to Heritage (`legacy_accolades`), so no
`player_achievements` upserts happen here — the transaction is just the one profile
changeset.

## "Lands already showing" — read confirmation

`get_profile_for_screen/1` (already shipped) surfaces everything a migrated user
must see on arrival, reading straight off the columns this import sets:

- **Veteran level + title + progress:** lines recompute live from `veteran_xp`
  (`veteran_level: Progression.level_for_xp(profile.veteran_xp)`,
  `veteran_title: Progression.title_for_level(...)`, `veteran_progress`). Setting
  `veteran_xp` is sufficient; the cached `veteran_level` we also write is belt-and-
  suspenders. ✅
- **Heritage badges:** `heritage: Heritage.display(profile.heritage_flags)` renders
  the badge list directly off our written flags. ✅ (after the one-line
  `legacy_premium` vocabulary addition so the premium badge shows).
- **Playstyle meter + avg bid:** `bidding_win_rate` / `aggression_needle` /
  `aggression_label` / `aggression_insufficient` / `avg_winning_bid` derive from the
  four accumulators we set (or `:insufficient` / `nil` when `playstyle` was nil). ✅
- **Provisional tier:** the screen exposes `rating_mu`/`rating_sigma`/
  `rating_games_count`; `Rating.Tier.classify/1` on those yields
  `%{tier: :provisional, provisional: true}` for our default+0 seed. ✅ (PID-54 owns
  surfacing the tier label from the API, but the inputs are correct on arrival.)

**Required additions to the read path:** only the `Heritage.@vocabulary`
`legacy_premium` entry. No change to `get_profile_for_screen/1` itself.

## Test Plan (ExUnit)

### `PidroServer.Profiles.LegacyProgression` (pure) — optional small file or inline
- `struct(LegacyProgression, %{xp: 100})` fills defaults (`badges: []`,
  `premium: false`, `founding_member: false`, `playstyle: nil`).

### `import_legacy_progression/2` — `profiles_test.exs` (or a focused
`legacy_import_test.exs`), `use PidroServer.DataCase, async: true`

Users created via `Accounts.Auth.register_user/1` (the existing `insert_user/0`
helper pattern).

- **Maps XP → level via the curve.** Import `xp: 174`; assert
  `veteran_xp == 174` and `veteran_level == Progression.level_for_xp(174)` (== 3).
  Boundary: `xp: 0` → level 1.
- **Heritage flags incl. badges.** Import with
  `badges: ["champion_2019", "marathon"]`, `founding_member: true`; assert
  `heritage_flags` contains `"played_pidro_one" => true`,
  `"legacy_accolades" => ["champion_2019", "marathon"]`,
  `"founding_member" => true`, and `"legacy_level"` equals the mapped level.
- **Premium → Heritage flag.** Import `premium: true`; assert
  `heritage_flags["legacy_premium"] == true` AND `Heritage.display(flags)` includes a
  premium badge (proves the vocabulary addition). `premium: false` → flag false, no
  premium badge.
- **Playstyle populated when present.** Import
  `playstyle: %{bidding_attempts: 40, bidding_wins: 12, won_bid_sum: 96}`; assert the
  four accumulators are set absolutely (`attempts 40`, `wins 12`,
  `avg_winning_bid_sum 96`, `avg_winning_bid_count 12`).
- **Playstyle skipped when nil.** Import `playstyle: nil`; assert all four
  accumulators stay `0` (no crash).
- **Skill stays default / Provisional.** After import assert
  `rating_mu == elem(Rating.default(), 0)`, `rating_sigma == elem(Rating.default(), 1)`,
  `rating_games_count == 0`, and `Tier.classify(profile) == %{tier: :provisional,
  provisional: true}`.
- **Idempotent re-run no-ops / no double-write.** Import once, snapshot the row,
  import again with *different* `legacy_data`; assert the second call returns
  `{:ok, :already_migrated}` and the row is **byte-identical** to the snapshot
  (marker short-circuits; nothing clobbered).
- **`get_profile_for_screen/1` shows everything for a migrated user.** After a full
  import (with playstyle), assert the screen map returns the carried `veteran_level`,
  a non-empty `veteran_title`, a `heritage` list containing the Played-Pidro-1 +
  Legacy-Level + accolade + premium badges, a numeric `avg_winning_bid` /
  `aggression_needle`, and that `Tier.classify` on the returned rating fields is
  `:provisional`.
- **Missing-optional-fields tolerated.** Import with only `%{xp: 500}` (plain map,
  not a struct); assert it succeeds, `legacy_accolades == []`,
  `founding_member`/`legacy_premium` false, playstyle accumulators 0, still
  Provisional. Also import a `%LegacyProgression{}` struct directly (both input
  forms accepted).
- **Accepts `%User{}` or id.** Both `import_legacy_progression(user, data)` and
  `import_legacy_progression(user.id, data)` produce the same row.

### `Heritage` — extend `heritage_test.exs`
- `display(%{"legacy_premium" => true})` yields the premium badge; `false`/absent →
  no premium badge (mirrors the existing boolean-badge tests).

## Implementation Checklist (ordered, each independently verifiable)

1. **`LegacyProgression` struct** — `profiles/legacy_progression.ex`: defstruct +
   typespecs + defaults. No DB.
2. **Heritage vocabulary** — add `{:legacy_premium, "Pidro 1 Premium", :boolean}` to
   `Heritage.@vocabulary`; extend `heritage_test.exs`. Run green.
3. **`import_legacy_progression/2`** in `profiles.ex`: resolve id, normalize input,
   `get_or_create_profile`, idempotency guard, build one `attrs` map, single
   `changeset/2 |> Repo.update` inside `Repo.transaction/1`; alias `LegacyProgression`.
4. **Write the import tests** (`profiles_test.exs` additions or
   `legacy_import_test.exs`) — XP→level, heritage incl. badges, premium flag,
   playstyle present + nil, skill default/Provisional, idempotent re-run,
   screen-shows-everything, missing-optionals, `%User{}`/id. Run green.
5. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer, credo
   all green.

## Files to Create / Modify

**Create:**
- `apps/pidro_server/lib/pidro_server/profiles/legacy_progression.ex` — the input
  contract struct.
- `apps/pidro_server/test/pidro_server/profiles/legacy_import_test.exs` — import
  tests (or fold into `profiles_test.exs`).

**Modify:**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `import_legacy_progression/2` + `alias …LegacyProgression`.
- `apps/pidro_server/lib/pidro_server/progression/heritage.ex` — one
  `legacy_premium` vocabulary entry (+ moduledoc key list).
- `apps/pidro_server/test/pidro_server/progression/heritage_test.exs` — premium
  badge test.

**Explicitly NOT modified:**
- `player_profile.ex` schema — all target columns + casts exist (PID-44).
- `get_profile_for_screen/1` — already surfaces every field (only Heritage
  vocabulary needed the one addition).
- `accounts/user.ex` — no premium/entitlement column (scope cut).
- `apps/pidro_engine/**`, rerate jobs / cursor, `game_stats` — skill is re-earned,
  not replayed.

## Acceptance Criteria

- [ ] A migrated user lands showing the correct **Veteran level + title** (mapped
      from legacy XP via the shared curve; XP kept verbatim).
- [ ] **Heritage badges** render: Played-Pidro-1, Legacy Level, Legacy Accolades
      (from `badges`), Founding Member, and **premium** (display-only flag).
- [ ] **Skill is Provisional on arrival** — `Rating.default/0` + `count 0`, no μ
      seed; `Tier.classify` → `:provisional`.
- [ ] **Playstyle / avg-bid populated** from `legacy.playstyle` when present; left at
      0 (`:insufficient`) when nil.
- [ ] `import_legacy_progression/2` is **idempotent** — re-run returns
      `{:ok, :already_migrated}`, no double-write; one changeset, one transaction.
- [ ] `get_profile_for_screen/1` returns all of the above for a migrated user with no
      change to its body (only the Heritage `legacy_premium` vocabulary added).
- [ ] No entitlement system, no legacy-blob parsing, no auth/claim flow, no
      `game_stats` backfill. `mix precommit` green.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` —
  `get_or_create_profile/1` (race-safe lazy create), `rebuild_from_history/1` (the
  single-changeset absolute-set write pattern to mirror), `get_profile_for_screen/1`
  (the read path that already surfaces veteran/heritage/playstyle/rating).
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:51-77` — `@castable`
  + `changeset/2` (all target columns castable, no blocking validations on
  veteran/rating/playstyle/heritage).
- `apps/pidro_server/lib/pidro_server/progression.ex` — `level_for_xp/1` (same
  curve as Pidro 1), `title_for_level/1`.
- `apps/pidro_server/lib/pidro_server/progression/heritage.ex` — `@vocabulary` +
  `display/1` (the Heritage surface, built for PID-53).
- `apps/pidro_server/lib/pidro_server/rating.ex:32` — `default/0` (`{25.0, 8.333}`).
- `apps/pidro_server/lib/pidro_server/rating/tier.ex:65-113` — `classify/1,3` +
  provisional rule (`count < 10` OR `sigma >= 6.0`).
- `apps/pidro_server/lib/pidro_server/accounts/user.ex` — confirms no
  premium/entitlement column (scope cut).

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-53-migration-carryover.md](../ratings-player-profiles/research/PID-53-migration-carryover.md)
- **Linear issue:** PID-53
