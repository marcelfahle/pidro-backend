---
date: 2026-06-07
ticket: PID-48
topic: "Skill tiers + provisional status — pure mapping (μ,σ) → tier + provisional flag (codebase as-is)"
status: complete
---
# Research: PID-48 Skill tiers + provisional status

## Summary

The rating substrate PID-48 needs already exists and is purely functional.
`PidroServer.Rating` (`apps/pidro_server/lib/pidro_server/rating.ex`) exposes
`default/0`, `rate/2`, and `ordinal/1` (`mu - 3 * sigma`), all pure and library-
agnostic. `PidroServer.Profiles.PlayerProfile` persists `rating_mu`,
`rating_sigma`, and `rating_games_count` columns with defaults. No tier / band /
provisional / rank code exists anywhere in the app today (only "rank" as card
rank and "abandoned" as a participation state — unrelated), so a new
`PidroServer.Rating.Tier` pure module would not collide with anything.

The repo has a clear, idiomatic config-tunable pattern: declare keyword-list
defaults under `config :pidro_server, <Module>, ...` in `config/config.exs`,
override per-env in `config/test.exs`, and read at runtime via
`Application.get_env(:pidro_server, __MODULE__, [])` with a `Keyword.get/3`
fallback to a module-level `@defaults` map (see `PidroServer.Games.Lifecycle`).
This is the pattern to follow for `skill_tiers` thresholds — `get_env` (runtime,
tunable), not `compile_env`.

## Rating API + ordinal range

File: `apps/pidro_server/lib/pidro_server/rating.ex`

Public API (full surface):

- `@type rating :: {mu :: float(), sigma :: float()}` (line 17) — a rating is a
  `{mu, sigma}` tuple of floats.
- `default/0` (lines 31-35) → `{25.0, 8.333333333333334}` (μ=25, σ=25/3). Wraps
  `Openskill.rating()` and coerces both to floats. The σ here is the **exact**
  `25/3 ≈ 8.333333…`, not the rounded `8.333` literal stored as the schema
  default (see next section).
- `rate/2` (lines 61-66) → `%{winners: [...], losers: [...]}`, updated tuples in
  input order. Order-only (no score margin); winners' μ rises, losers' μ falls,
  every σ shrinks.
- `ordinal/1` (line 78) → `mu - 3 * sigma`, a float. Conservative scalar for
  display/sorting.

Ordinal range (the basis for tier cutoffs):

- At `default/0`: `25.0 - 3 * (25/3) = 25.0 - 25.0 = 0.0`. A brand-new player
  sits at ordinal **0.0** (maximum uncertainty fully cancels the mean).
- As a player wins, μ rises and σ falls, so ordinal rises (both terms push it
  up). The test suite (`rating_test.exs`) asserts the monotonic properties:
  higher μ at equal σ → higher ordinal; higher σ at equal μ → lower ordinal
  (uncertainty penalized); repeated wins shrink σ monotonically while μ
  increases with diminishing per-game gains.
- Plausible practical range: ordinal floors near 0 (and can go slightly negative
  for a player who only loses, since μ can dip below 3σ once σ has shrunk).
  As σ converges toward a small floor (a few points) and μ settles, ordinal for
  experienced players will plausibly land in the roughly **0 → ~40+** band, with
  μ being unbounded above in principle (Bayesian mean drifts with sustained
  results). There is **no hard cap** in the code — OpenSkill defaults are
  μ=25, σ=25/3, and nothing clamps μ or ordinal. Tier cutoffs should therefore
  be chosen against this open-ended scale (e.g. low single-digit ordinals for
  Bronze rising upward), and the provisional gate handled separately via σ /
  games-count rather than via the ordinal value.

Note: the ordinal doctest (lines 73-74) uses `ordinal({25.0, 8.0}) == 1.0`,
confirming the formula; the default-case 0.0 is implied by `default/0` returning
σ = 25/3 exactly.

## Profile rating columns

File: `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex`,
schema `"player_profiles"`:

- `field :rating_mu, :float, default: 25.0` (line 31)
- `field :rating_sigma, :float, default: 8.333` (line 32)
- `field :rating_games_count, :integer, default: 0` (line 33)

All three are in `@castable` (lines 51-66) and written by PID-45/47; PID-44 only
sets defaults. `rating_games_count` is the natural "enough games" counter for the
provisional gate.

Important nuance for the provisional flag: the schema default for `rating_sigma`
is the **rounded literal `8.333`**, whereas `Rating.default/0` returns the
**exact `25/3 = 8.333333333333334`**. These differ in the 4th decimal. A
never-rated user (still at the `8.333` schema default, `rating_games_count = 0`)
must still classify as **Provisional**. So any σ-threshold for clearing
provisional should be chosen well below `8.333` (and combined with / OR'd against
a games-count gate), so that both `8.333` (schema default) and
`8.333333333333334` (`Rating.default/0`) land on the Provisional side regardless
of the float-equality mismatch. Do not rely on `sigma == default_sigma` exact
equality to detect "unrated".

## Config conventions (verbatim declare + read)

The repo's idiomatic tunable pattern is keyword lists keyed by the owning module
under the `:pidro_server` app, declared in `config/config.exs`, overridden in
`config/test.exs` (and optionally via env vars in `config/runtime.exs`), and read
at **runtime** with `Application.get_env/3` + a `@defaults` fallback. The
canonical example is `PidroServer.Games.Lifecycle`.

DECLARE — `config/config.exs` lines 25-41 (excerpt):

```elixir
# Lifecycle timeouts for the disconnect cascade and room lifecycle.
# All values are in milliseconds. Override per-environment or via env vars in runtime.exs.
config :pidro_server, PidroServer.Games.Lifecycle,
  hiccup_timeout_ms: 20_000,
  grace_timeout_ms: 120_000,
  empty_room_ttl_ms: 30_000,
  # ...
  hand_transition_delay_ms: 3_000
```

Per-env override — `config/test.exs` lines 39-56 re-declare the same key with
short values for fast tests. A simpler one-line tunable also exists:
`config :pidro_server, PidroServer.Games.RoomManager, grace_period_ms: 120_000`
(config.exs line 21; test.exs line 36 overrides it to `200`).

READ — `apps/pidro_server/lib/pidro_server/games/lifecycle.ex` lines 33-69
(excerpt):

```elixir
@defaults %{
  hiccup_timeout_ms: 20_000,
  grace_timeout_ms: 120_000,
  # ...
}

@spec config(timeout_key()) :: non_neg_integer()
def config(key) when is_map_key(@defaults, key) do
  app_config = Application.get_env(:pidro_server, __MODULE__, [])
  Keyword.get(app_config, key, Map.fetch!(@defaults, key))
end
```

Read-style preference in this codebase:

- `Application.get_env/3` (runtime) is used for **tunable** values — Lifecycle
  timeouts (lifecycle.ex:67), the env-var overrides in runtime.exs (line 58),
  `pacing_settings.ex:126`, `dev_access.ex:19,22`, and `application.ex:13`.
- `Application.compile_env/2,3` is used only for **compile-fixed** flags —
  `router.ex:98` (`:dev_routes`), which must be known at compile time.

Idiomatic place to add `skill_tiers` thresholds: declare in `config/config.exs`
under `config :pidro_server, PidroServer.Rating.Tier, ...` (keyword list of
threshold values — band ordinal cutoffs, provisional σ ceiling, provisional
min-games), override in `config/test.exs` if tests need fixed values, and read
via `Application.get_env(:pidro_server, PidroServer.Rating.Tier, [])` with a
`@defaults` fallback — i.e. **`get_env`, not `compile_env`**, because thresholds
are explicitly "tunable" per the ticket. Optional env-var overrides can be added
to `config/runtime.exs` following the `lifecycle_overrides` reduce pattern
(runtime.exs lines 31-60) if prod tuning without redeploy is wanted.

## Pure module + test conventions

Precedent: `PidroServer.Rating` (`rating.ex`) + `PidroServer.RatingTest`
(`test/pidro_server/rating_test.exs`). A small pure mapping module like
`PidroServer.Rating.Tier` and its test would live at:

- Module: `apps/pidro_server/lib/pidro_server/rating/tier.ex`
  (a `rating/` subdir under `lib/pidro_server/` — currently `rating.ex` sits flat,
  but introducing `rating/tier.ex` namespaced as `PidroServer.Rating.Tier` is the
  standard Elixir layout and matches existing nesting like
  `lib/pidro_server/profiles/player_profile.ex` and
  `lib/pidro_server/games/lifecycle.ex`).
- Test: `apps/pidro_server/test/pidro_server/rating/tier_test.exs`.

Test style (from `rating_test.exs`):

- `use ExUnit.Case, async: true` (line 2) — pure modules run async.
- `alias PidroServer.Rating` then `doctest PidroServer.Rating` (lines 4-6) —
  doctests are run, so worked examples in `@doc`/`@moduledoc` are executable
  documentation (see the `## Examples` blocks in `rating.ex`).
- Behaviour-focused `describe`/`test` blocks asserting properties
  (monotonicity, boundary behaviour, determinism) with `assert_in_delta` for
  floats.

For `Tier`: expect doctests on the pure mapping (e.g. `tier({25.0, 8.333})` →
provisional band), plus `describe` blocks for each band boundary and the
provisional clear/stay logic, `async: true`.

## Existing tier-related code

None. A case-insensitive grep across `apps/**/*.ex(s)` for
`tier|band|provisional|rank` returns:

- `tier` / `band` / `provisional` — **zero matches** in source.
- `rank` — only `"rank"` as a **card rank** field in channel tests
  (`game_channel_test.exs:304,330,346`) and a hex dep version line in `mix.exs`.
  Unrelated to player ranking.
- `abandoned` — a game **participation** state (Stats / score-protection),
  unrelated.

So `PidroServer.Rating.Tier`, a `:tier`/`:provisional` field shape, and a
`skill_tiers` (or `PidroServer.Rating.Tier`) config key are all free of naming
collisions.

## Open Questions

1. **Band cutoffs on an open-ended scale.** Ordinal has no hard cap (μ unbounded
   above), so the Provisional→Bronze→Silver→Gold→Platinum→Master cutoffs need
   chosen against empirical ordinal distribution. Code does not constrain this;
   thresholds are a product/config decision.
2. **Provisional gate semantics.** Ticket says "after enough games / once σ drops
   below a threshold" — is this AND or OR? (e.g. clear provisional once
   `rating_games_count >= N` OR `sigma <= S`.) Needs to be specified; both inputs
   exist on the profile.
3. **σ default mismatch handling.** Confirm provisional logic treats both `8.333`
   (schema default) and `25/3` (`Rating.default/0`) as "still uncertain" — i.e.
   the σ ceiling for clearing provisional must sit strictly below `8.333`, and/or
   the games-count gate carries unrated users. (See Profile section.)
4. **Where does the tier get exposed?** PID-48 is the pure mapping only; which
   read path (profile serializer / channel payload) surfaces `tier` +
   `provisional` to clients is out of scope here and not yet present.
5. **Env-var overrides needed?** Lifecycle has runtime.exs env-var plumbing;
   unclear whether tiers need the same prod-tunable-without-redeploy treatment or
   whether config-file tuning suffices.
