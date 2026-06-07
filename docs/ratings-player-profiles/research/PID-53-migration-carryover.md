---
date: 2026-06-07
ticket: PID-53
topic: "Pidro 1 → Pidro 2 progression carry-over (the PROGRESSION MAPPING only)"
status: complete
---
# Research: PID-53 Pidro 1 → Pidro 2 progression carry-over

> Scope: the **progression mapping** only — legacy XP/level → Veteran, legacy
> badges → Heritage, premium → entitlement, playstyle carry, provisional skill
> seed. The magic-link / `?migrate=TOKEN` auth/claim flow is a SEPARATE ticket
> and is NOT covered here.

## Summary

- **The mapping targets all exist and shipped (PID-44..PID-52).** Every Pidro 2
  column the carry-over writes to is present, cast, and surfaced on the profile
  screen. The Heritage module was **explicitly built for PID-53 to populate**
  (its `@moduledoc` says so) and PID-49 deliberately leaves `heritage_flags`
  empty (defaults only) for PID-53 to fill.
- **No import scaffolding exists — this is greenfield for the mapping.** There is
  NO `import_legacy_progression`, no classic-migration context/schema/module, no
  `migrated_at` column, no legacy-id link field. (The only "migration" hits in
  the worktree are Ecto schema migrations and an unrelated `EmailMigrationLive`
  dev tool.) The migration *project* is shelved per memory; PID-53 builds the
  pure mapping seam ahead of the auth/claim flow.
- **Pidro 2 does NOT model premium/subscription/entitlement at all.** The `users`
  schema has only `username/email/password_hash/guest`. No premium field, no
  purchases table, no IAP. The legacy side has `premium_until` + `premium_product`.
- **Legacy data is reachable** and field shapes are confirmed (see §4): `users.xp`
  (lifetime XP), `users.premium_until`/`premium_product`, `user_badges.AchievementData`
  (badges), and the per-round bidding data lives in **`game_play_data.RoomData`**
  (a JSON map blob), NOT in `round_scores` (which is per-team-per-round, no
  bidder/bid).
- **The legacy XP→level curve is the SAME curve Pidro 2's `Progression` already
  carries** (PID-49 lifted it verbatim from `pidro_api`). So mapping legacy XP →
  Veteran level is: write `veteran_xp = legacy_xp`, set `veteran_level =
  Progression.level_for_xp(legacy_xp)`. Old XP is **kept** (dedication), exactly
  as the ticket requires.

## 1. Migration model / context (from memory + docs)

From `classic-account-migration.md` (memory, 2 days old — verified against code):

- **Migration is SHELVED as a pre-launch project** (decided 2026-06-05): no live
  player base to migrate yet; build the game first. PID-53 builds the mapping seam
  forward-compat, but the end-to-end claim flow is later.
- **Two-phase build.** v1 = migration + free Casual track + tiered Veteran
  identity + Heritage badges + premium carry-over. The Ranked ladder (skill
  engine, seasons) is a decoupled follow-on.
- **Verification via the `pidro.online` website bridge** (`/Users/mf/code/pidro/pidro-site2`),
  which authenticates Classic players (`/api/portal/sign_in`) and reads stats via
  `/v3/self`. The bridge issues a one-time signed claim the new backend redeems —
  this keeps legacy auth (MD5/Argon2, FB/Apple) out of the clean new backend.
  **That redemption/claim flow is the SEPARATE ticket; PID-53 only consumes the
  resulting `legacy_data`.**
- **Separate dedication from skill.** Veteran (games played / XP) is dedication
  and never resets; skill is the 2v2 rating engine. PID-53 must keep these split:
  legacy strength may only seed a **high-uncertainty** rating, never an
  authoritative one.
- Memory note `classic-account-migration.md:19` says "new progression model
  deliberately replaces old lifetime-XP, never imports it." **This is superseded**
  by the PID-49 ticket + the shipped `Progression` module, which carry Pidro 1's
  1–100 level and reward-the-loser XP verbatim. The PID-49 research doc flags this
  contradiction (`PID-49-veteran-xp-heritage.md:341-347`). PID-53 follows the
  shipped engine: legacy XP is **kept and imported**.

Note: `docs/PIDRO-MASTER-GUIDE.md` exists but has no migration/classic/import
section (grep returns nothing). The two brainstorm docs the memory references
(`docs/brainstorms/2026-06-05-classic-account-migration-requirements.md`,
`...progression-and-ranking-requirements.md`) are **absent from this worktree**.

## 2. Existing scaffolding (greenfield for the mapping)

Confirmed by grep (`apps/*/lib`, excluding `_build`):

- **No** `import_legacy_progression`, `ImportLegacy`, `ClassicMigration`,
  `migrate_account`, `claim_legacy` module/function anywhere.
- **No** `migrated_at` / `legacy_id` / account-link column on `users` or
  `player_profiles` (the forward-compat hook the memory mentions is NOT yet built).
- **No** premium/subscription/entitlement field (see §3.4).
- The only matches: Ecto schema migrations (`release.ex`, `priv/repo/migrations`)
  and `PidroServerWeb.Dev.EmailMigrationLive` (an unrelated email-export dev tool).

**Built FOR PID-53 to use** (already shipped):

- `apps/pidro_server/lib/pidro_server/progression/heritage.ex` — `@moduledoc`
  line 8: *"PID-53 (account migration) populates them on import."* Defines the
  known key vocabulary and the display projection.
- All `player_profiles` progression columns ship with safe defaults (PID-44).

## 3. Pidro 2 mapping targets

### 3.1 `player_profiles` columns — `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex`

All columns below are in `@castable` (`:51-66`) and cast by the single
`changeset/2` (`:69-77`), so a one-shot changeset can write them all:

```elixir
field :rating_mu, :float, default: 25.0           # :31  (skill seed)
field :rating_sigma, :float, default: 8.333        # :32  (skill uncertainty)
field :rating_games_count, :integer, default: 0    # :33
field :veteran_level, :integer, default: 0         # :36  (Veteran)
field :veteran_xp, :integer, default: 0            # :37  (legacy XP carried)
field :playstyle_bidding_wins, :integer, default: 0       # :40
field :playstyle_bidding_attempts, :integer, default: 0   # :41
field :avg_winning_bid_sum, :integer, default: 0          # :42
field :avg_winning_bid_count, :integer, default: 0        # :43
field :heritage_flags, :map, default: %{}          # :46  (Heritage)
```

The only `changeset/2` validations are `validate_required([:user_id])`,
`validate_number(:games_played|:wins|:losses, >= 0)`, and the `:user_id` unique
constraint — none on the veteran/rating/playstyle/heritage columns, so a write of
arbitrary seed values passes.

### 3.2 Writer helpers + `get_or_create_profile/1` — `profiles.ex`

- **`get_or_create_profile/1`** (`profiles.ex:45-67`): `Repo.get_by` then race-safe
  `Repo.insert(on_conflict: :nothing, conflict_target: :user_id)` with a re-fetch.
  Returns `{:ok, %PlayerProfile{}}`. This is the entry point every writer calls.
- **`get_profile_for_screen/1`** (`profiles.ex:77-128`): the acceptance-criteria
  read path. It surfaces `veteran_level` (recomputed live from `veteran_xp` via
  `Progression.level_for_xp/1`, line 104), `veteran_title`, `veteran_progress`,
  `rating_*`, the playstyle derivations, and crucially:
  - `heritage_flags: profile.heritage_flags` (line 117) — raw bag
  - `heritage: Heritage.display(profile.heritage_flags)` (line 118) — the rendered
    badge list. **A migrated user lands showing Heritage immediately** because the
    screen reads straight off the column.
- **No existing combined writer** persists all progression columns in one
  changeset. The incremental writers each do a scoped `Repo.update_all(inc:/set:)`:
  - `apply_one/2` (`:982`) — counters
  - `apply_xp/3` (`:1003`) — `inc: [veteran_xp: delta]` then
    `set: [veteran_level: Progression.level_for_xp(new_xp)]`
  - `apply_playstyle/2` (`:1027`) — `inc:` the 4 playstyle accumulators
  - `award_achievement/4` (`:481`) — idempotent `insert_all ... on_conflict:
    :nothing` (returns `:awarded`/`:already`)
  - rating is written by `apply_live_rating/2` (PID-47).
  PID-53's `import_legacy_progression` should instead write everything through a
  **single `PlayerProfile.changeset(profile, attrs)` + `Repo.update`** (the shape
  `rebuild_from_history/1` uses, `profiles.ex:365+`), since the import sets
  absolute values, not increments.

### 3.3 Pure mapping modules

- **`PidroServer.Progression`** (`progression.ex`):
  - `level_for_xp/1` (`:146`) — `level = count(thresholds <= xp) + 1`, capped at
    `max_level`; `level_for_xp(0) == 1`. The thresholds are the **legacy
    `pidro_api` 199-entry curve lifted verbatim** (PID-49). So legacy XP maps onto
    the same level it had in Pidro 1: `veteran_level = level_for_xp(legacy_xp)`.
  - `title_for_level/1` (`:168`) — milestone title ("Rookie"/"Veteran"/...). Note
    these titles are NEW Pidro 2 vocabulary; legacy had numeric levels only.
  - `xp_for_game/3`, `next_level_at/1`, `level_progress/1`, `thresholds/0`,
    `defaults/0` also present.
- **`PidroServer.Rating.Tier`** (`rating/tier.ex`) — provisional rule
  (`classify/3`, `:65`): a player is **PROVISIONAL while
  `games_count < provisional_min_games (10)` OR `sigma >= provisional_max_sigma
  (6.0)`**; provisional clears only when BOTH are satisfied. So to keep a migrated
  user provisional with a high-uncertainty seed, set `rating_games_count = 0`
  (below 10) and/or `rating_sigma >= 6.0`. The default σ already satisfies this.
- **`PidroServer.Rating.default/0`** (`rating.ex:32`) — `{25.0, 8.333}` (μ=25,
  σ=25/3). `sigma = 8.333 >= 6.0` AND `games_count = 0 < 10` ⇒ **a profile left at
  defaults is Provisional**. The safest "provisional seed" is literally
  `Rating.default()` with `rating_games_count: 0` — guaranteed provisional, no
  authoritative skill imported. Any legacy-strength nudge to μ must keep σ high
  (≥ 6.0) and count 0 to stay provisional, per the ticket.

### 3.4 Premium / entitlement — ABSENT in Pidro 2

- `apps/pidro_server/lib/pidro_server/accounts/user.ex` schema (`:15-23`) has ONLY:
  `username, email, password (virtual), password_hash, guest`. **No premium,
  subscription, entitlement, paid_until, or IAP field anywhere** (grep of
  `apps/*/lib` for `premium|subscription|entitlement|iap|paid_until` returns only
  PubSub "subscribe" noise). No purchases table.
- **Legacy DOES model premium**: `pidro_api` `users.premium_until :utc_datetime`,
  `users.premium_product :string`, `User.is_premium?/1` (`= now < premium_until`),
  a `purchases` table (`purchase.ex` with `expires_at`), and `rooms.premium`
  (premium-gated league tables).
- **Implication for PID-53:** Pidro 2 has no entitlement system to write to. The
  ticket's "active premium → entitlement" must be scoped minimally. The available
  surfaces are: (a) a **Heritage flag** (e.g. add a `premium_legacy`/`founding`
  key to the `heritage_flags` bag — display-only), or (b) introduce a new minimal
  entitlement field/column (out of scope of the shipped work; would be NEW). The
  real IAP/entitlement system is out of scope per the migration plan (new-client
  IAP is a separate dependency for premium).

### 3.5 Heritage flags vs `player_achievements` rows (badges)

Two distinct surfaces exist; the ticket and Heritage `@moduledoc` point to **(A)**:

- **(A) Heritage flags** — `heritage_flags` JSONB on the profile, rendered by
  `Heritage.display/1`. Vocabulary (`heritage.ex:34-39`):
  - `played_pidro_one :: boolean` — "Played Pidro 1"
  - `founding_member :: boolean` — "Founding Member"
  - `legacy_level :: integer` — "Legacy Level" (display-only; carried Pidro 1 level)
  - `legacy_accolades :: [string]` — "Legacy Accolades" (named legacy awards/titles)
  Boolean badges show only when truthy; value badges show when non-nil. **This is
  where re-awarded legacy badges belong** (`legacy_accolades` ← the list derived
  from `user_badges.AchievementData`). Display-only, no catalog coupling.
- **(B) `player_achievements` rows** — `Profiles.Achievement` schema (one row per
  `(user_id, achievement_key)`, unique-indexed), written via
  `award_achievement/4`. Keys must exist in `PidroServer.Achievements.Catalog`
  (`catalog.ex`; `Catalog.all/0`, `Catalog.active/0`, `Catalog.fetch!/1`) to render
  on the screen (`screen_achievements/1` drops unknown keys, `profiles.ex:132-158`).
  Legacy badges have **no matching catalog keys**, so routing them here would
  require new catalog entries and they'd silently not display until then.
- **Recommendation surface (per ticket "re-award old badges as Heritage"):** use
  **(A)** — put the legacy accolade names into `heritage_flags.legacy_accolades`.
  This is the path Heritage was built for and needs no Catalog changes.

## 4. Legacy Pidro 1 data shape (the mapping's input contract)

Source: `/Users/mf/code/pidro/pidro_api`.

### 4.1 XP / level — `lib/pidro_api/users/user.ex`

- `field :xp, :integer, default: 0` (`user.ex:68`) — **lifetime XP** (per-game XP
  also stored as `x_point` rows, `x_point.ex` `xp :integer`).
- **There is no stored level column** — level is computed from XP at read time by
  `PidroApiWeb.UserView.user_level/1` (`user_view.ex:378-403`) using the 199-entry
  `all_levels/0` threshold array (`level = count(thresholds <= xp) + 1`,
  `user_level(nil) = 1`). PID-49 lifted this exact curve into Pidro 2's
  `Progression`. **So the only field PID-53 needs is `xp`; the Pidro 2 level is
  recomputed identically.** (XP award rule, for reference: winner = team final
  score + 50, loser = team final score — `game_results.ex:185-211`.)

### 4.2 Badges / achievements — `lib/pidro_api/users/user_badge.ex`

- `user_badges` table, schema (`user_badge.ex:1-10`):
  - `field :AchievementData, :string` — the badge payload/identifier (string;
    likely a code or JSON-ish string), `belongs_to :user`.
  - `field :created_date, :naive_datetime`
- A user has many `user_badges` rows → the legacy "badges/achievements list". For
  PID-53 these become `heritage_flags.legacy_accolades` (a `[string]`).

### 4.3 Premium / subscription — `lib/pidro_api/users/user.ex` + `purchase.ex`

- `field :premium_until, :utc_datetime` (`user.ex:64`)
- `field :premium_product, :string` (`user.ex:65`)
- `field :transaction_device`/`:transaction_id` (`user.ex:66-67`)
- `User.is_premium?/1` (`user.ex:103-105`): `premium_until && now < premium_until`.
- `field :star, :integer` (`user.ex:55`) — donor flag (`is_donor?/1`, `:107-112`).
- `PidroApi.Purchase` (`purchase.ex`) has `expires_at :utc_datetime` (per-purchase).
- **Input the mapping needs:** `premium_until` (+ optionally `premium_product`) to
  decide "active premium" via the same `now < premium_until` test.

### 4.4 Per-round bidding data — `round_scores` vs `game_play_data`

- **`round_scores` (`lib/pidro_api/games/round_score.ex`) is per-team-per-round,
  NOT per-bidder.** Fields: `SenderId, RoomId, Score, RoundIndex, Team
  (:A|:B|:N), TeamUsers (comma-joined user-id string), Result ("W"|"R"|"D"),
  created_at`. Two rows per round (TeamA + TeamB). It carries the **team score and
  W/R/D result per round**, but **no bidder identity and no bid amount**
  (`prepare_round_scores_optimized/1`, `game_results.ex:628+`). Useful for
  *games-played / wins* style data, not for the bidding-win-rate needle.
- **`final_scores` (`final_score.ex`)** — per-game-per-team final: `SenderId,
  RoomId, Result, Players (string), Score, CreatedOn/CreatedAt`.
- **The per-round bidder + bid lives in `game_play_data.RoomData`**
  (`gameplay_data.ex:6-8`): `RoomId :integer`, `RoomData :map` — a JSON blob of the
  whole room/game state, upserted per room (`persist_game_play_data/2`,
  `game_controller.ex:259-279`). This is the legacy equivalent of Pidro 2's
  event log / "round JSON" — it is where per-round bidder + winning-bid amounts
  would be reconstructed from. The exact internal `RoomData` key shape was not
  fully decoded in this pass (it is a free-form map blob) and is an Open Question.

## 5. Playstyle-from-legacy mapping

Pidro 2 profile accumulators (PID-51) the import must populate:
`playstyle_bidding_attempts`, `playstyle_bidding_wins`, `avg_winning_bid_sum`,
`avg_winning_bid_count`. Per the PID-51 hint and `apply_playstyle/2`
(`profiles.ex:1027-1048`):

- `attempts` = number of bidding rounds the player participated in
- `wins` = number of rounds where the player was the winning bidder
- `won_bid_sum` = Σ of the winning bid amounts (for those wins)
- `avg_winning_bid_count` is fed from `wins` (won-bid count == wins), so the screen
  derives `avg_winning_bid = avg_winning_bid_sum / avg_winning_bid_count`.

**Legacy source:** these require **per-round bidder + bid amount**, which exist
ONLY inside `game_play_data.RoomData` (the JSON game-state blob, §4.4) — NOT in
`round_scores`/`final_scores` (no bidder/bid there). So the legacy-input contract
for playstyle is: parse each historical game's `RoomData`, count the player's
bidding rounds (attempts), the rounds they won the bid (wins), and the sum of those
winning bids (won_bid_sum). Where `RoomData` is unavailable/undecodable, the
accumulators stay at 0 and the screen reports `avg_winning_bid`/needle as
insufficient — degrade gracefully ("populated where available", per acceptance).

## 6. Proposed import seam + idempotency

A new pure-ish context function on `Profiles` (greenfield):

```elixir
# Profiles.import_legacy_progression(user_or_id, legacy_data) :: {:ok, profile} | {:error, _}
```

where `legacy_data` is the bridge-supplied contract built from §4, e.g.:

```elixir
%{
  xp: 12_345,                       # users.xp  -> veteran_xp (kept as-is)
  premium_active?: true,            # now < users.premium_until
  accolades: ["badge_a", "badge_b"],# user_badges.AchievementData list
  playstyle: %{attempts: 40, wins: 12, won_bid_sum: 96},  # from game_play_data.RoomData
  legacy_level: 73                  # optional display value (Progression.level_for_xp(xp) is canonical)
}
```

Mechanics (mirror `rebuild_from_history/1`, single changeset write):

1. `{:ok, profile} = get_or_create_profile(user_id)`.
2. **Idempotency guard:** if `profile.heritage_flags["played_pidro_one"] == true`
   (the import marker), return `{:ok, profile}` unchanged — re-running never
   double-applies. (The values are absolute sets, not increments, so even without
   the guard a second run is mostly safe; the guard makes it explicit and also
   protects against clobbering post-import gameplay XP. Recommended marker:
   `heritage_flags.played_pidro_one`, set by the import itself. An alternative is a
   new `migrated_at` column — NOT present today; would be a NEW migration.)
3. Build one `attrs` map and write via
   `PlayerProfile.changeset(profile, attrs) |> Repo.update()`:
   - `veteran_xp: legacy_xp` (kept — dedication)
   - `veteran_level: Progression.level_for_xp(legacy_xp)`
   - `rating_mu/sigma/games_count`: a **provisional, high-uncertainty seed** —
     simplest is `Rating.default()` with `rating_games_count: 0` (guaranteed
     Provisional via Tier rule); any μ nudge must keep σ ≥ 6.0 and count 0.
   - `playstyle_*` + `avg_winning_bid_*` from `legacy_data.playstyle`
   - `heritage_flags`: `%{played_pidro_one: true, legacy_level: legacy_level,
     legacy_accolades: accolades, founding_member: ...}` (premium handled here as a
     heritage flag too, since Pidro 2 has no entitlement system — §3.4).
4. Achievements via `award_achievement/4` are already idempotent
   (`on_conflict: :nothing`) — but the chosen surface is Heritage (§3.5), so this
   is only relevant if some legacy badges are routed to catalog rows.

Because all writes go through one changeset (or are individually idempotent), and
the heritage marker short-circuits re-runs, the import is idempotent and
single-transaction-friendly (wrap in `Repo.transaction/1` if combined with
achievement upserts).

## 7. Test conventions

- **`use PidroServer.DataCase, async: true`** (e.g.
  `apps/pidro_server/test/pidro_server/profiles/profiles_test.exs:2`). The
  established profile-test file. Users are created via
  `PidroServer.Accounts.Auth.register_user(%{username:, password:})` (helper
  `insert_user/0` at `profiles_test.exs:9+`).
- Pure-mapping tests for any new pure logic mirror `rating/tier_test.exs` /
  `progression_test.exs`: doctests + boundary tests; `async: false` only when the
  test mutates `Application.put_env` for config overrides.
- For `import_legacy_progression/2`: a DataCase test asserting (a) a fresh import
  sets `veteran_xp`/`veteran_level`/heritage/playstyle and leaves the profile
  **Provisional** (`Tier.classify(profile)` → `%{provisional: true}`); (b) a second
  call is a no-op (idempotency — values unchanged, heritage marker present);
  (c) `get_profile_for_screen/1` returns the carried Veteran level + Heritage badge
  list + populated `avg_winning_bid`.

## Open Questions

1. **`game_play_data.RoomData` internal shape.** The per-round bidder + bid amount
   needed for playstyle live in this free-form JSON map (`gameplay_data.ex:8`). Its
   exact key structure (how a round, its bidder seat, and the winning bid are keyed)
   was not decoded here — needs a sample dump from the production blob to define the
   playstyle parse. If undecodable for a given user, playstyle degrades to 0/insufficient.
2. **Premium target.** Pidro 2 has no entitlement field. Does PID-53 stash premium
   purely as a `heritage_flags` key (display-only, recommended/in-scope), or does
   the plan introduce a minimal new entitlement column (NEW migration, broader
   scope)? The ticket says premium maps to "entitlement" but the real system is out
   of scope.
3. **Skill seed policy.** Pure `Rating.default()` (no info) vs a μ nudge from legacy
   strength. The ticket allows "at most a high-uncertainty seed, never authoritative."
   What legacy signal (XP? win rate from `round_scores` results?) feeds μ, and what
   σ/count keeps it Provisional (must satisfy σ ≥ 6.0 AND count < 10)? Simplest
   compliant answer: `default()` + count 0.
4. **Idempotency marker.** Use `heritage_flags.played_pidro_one` (no schema change,
   recommended) vs a new `migrated_at` column (clearer audit, needs a migration +
   the forward-compat legacy-id link the memory mentions but that does not exist yet).
5. **Accolade vocabulary.** `user_badges.AchievementData` is an opaque string. What
   is its value space, and how does it map to displayable `legacy_accolades`
   labels (raw passthrough vs a legacy-badge→label lookup table)?
6. **Heritage memory contradiction.** Memory says "never import old XP"; the shipped
   `Progression` engine + this ticket say "keep/import legacy XP as dedication."
   PID-53 follows the shipped engine + ticket (import), but the memory note should
   be reconciled.
