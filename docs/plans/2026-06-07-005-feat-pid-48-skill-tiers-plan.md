---
title: "feat: Skill tiers + provisional status (pure (μ,σ)→tier mapping)"
type: feat
status: active
date: 2026-06-07
linear: PID-48
origin: docs/ratings-player-profiles/research/PID-48-skill-tiers.md
---

# feat: Skill tiers + provisional status

## Overview

PID-45 shipped `PidroServer.Rating` — the pure `{mu, sigma}` math with
`default/0`, `rate/2`, and `ordinal/1` (`mu - 3*sigma`). PID-44 added the
`player_profiles` rating columns (`rating_mu` 25.0, `rating_sigma` 8.333,
`rating_games_count` 0). PID-48 delivers the **pure mapping** from a rating to a
skill tier plus a provisional flag — and nothing else.

The deliverable is one small pure module `PidroServer.Rating.Tier` exposing
`classify/3` (and a profile-map convenience overload) that returns
`%{tier: tier_atom, provisional: boolean}`. Bands are
Provisional → Bronze → Silver → Gold → Platinum → Master. Band cutoffs are read
off `Rating.ordinal/1` (the conservative `μ − 3σ` scalar, **not** raw μ), so a
player's uncertainty is already baked into where they land. The provisional gate
and the band cutoffs are config-tunable via the project's idiomatic
`Application.get_env/3` + `@defaults` pattern (the `PidroServer.Games.Lifecycle`
precedent).

Follows `apps/pidro_server/CLAUDE.md`: pure function, deterministic, doctested;
no GenServer, no persistence, single source of truth (tier is **derived on read**,
never stored).

## Non-Goals (explicit — owned elsewhere or out of scope)

- **No DB column / no persistence.** Tier and provisional are *derived* from the
  existing `rating_mu` / `rating_sigma` / `rating_games_count` on read. No
  migration, no schema field, no `Repo`.
- **No API / serializer exposure.** Surfacing `tier` + `provisional` in a profile
  payload or channel response is **PID-54**. PID-48 only ships the pure function it
  will call.
- **No up/down delta, no "promoted/demoted" event** — **PID-52**.
- **No rating math.** Computing/updating `{mu, sigma}` is **PID-45** (done); this
  module only *reads* a rating and `Rating.ordinal/1`.
- **No tuning/calibration.** Default thresholds below are launch placeholders,
  labelled as such; calibrate later against the real ordinal distribution.

## Module API

`PidroServer.Rating.Tier` — `apps/pidro_server/lib/pidro_server/rating/tier.ex`

```elixir
defmodule PidroServer.Rating.Tier do
  @moduledoc """
  Pure mapping from a rating to a skill tier + provisional flag.

  Bands (ascending): Bronze → Silver → Gold → Platinum → Master, gated by a
  Provisional state. Bands are read off `Rating.ordinal/1` (mu - 3*sigma), NOT
  raw mu, so uncertainty is already priced in.

  A player is PROVISIONAL while they have too few rated games OR their sigma is
  still too high; the band is suppressed and `tier: :provisional` is returned.
  Provisional clears only once BOTH conditions are satisfied
  (games_count >= min_games AND sigma < max_sigma).

  Thresholds are config-tunable (see `config :pidro_server, #{inspect(__MODULE__)}`);
  launch defaults are placeholders, not finely calibrated.
  """

  @type tier ::
          :provisional | :bronze | :silver | :gold | :platinum | :master

  @typedoc "Result of classifying a rating."
  @type result :: %{tier: tier(), provisional: boolean()}

  @doc "Classify from raw `mu`, `sigma`, and rated `games_count`."
  @spec classify(float(), float(), non_neg_integer()) :: result()
  def classify(mu, sigma, games_count)

  @doc """
  Convenience overload reading a profile-shaped map with
  `:rating_mu`, `:rating_sigma`, `:rating_games_count` keys (PID-54 call site).
  """
  @spec classify(%{
          required(:rating_mu) => float(),
          required(:rating_sigma) => float(),
          required(:rating_games_count) => non_neg_integer()
        }) :: result()
  def classify(profile)

  @doc "Full map of default thresholds (band cutoffs + provisional gate)."
  @spec defaults() :: map()
  def defaults()
end
```

Design notes:

- **`classify/3` is the core.** `classify(mu, sigma, games_count)`. `mu` is
  accepted (not just the ordinal) so the contract reads naturally at the call site
  and the module owns the `Rating.ordinal/1` call — callers pass the three stored
  values verbatim.
- **`classify/1` profile overload** reads the three `rating_*` keys and delegates
  to `classify/3`. This is the shape PID-54 has on hand (a `PlayerProfile` /
  profile map). Keys are required map keys — pattern-match, no `Map.get` defaults
  (an unrated profile already carries the column defaults).
- **Returns a map** `%{tier:, provisional:}`, mirroring `Rating.rate/2`'s map
  return style — callers destructure, never re-derive.
- **Pure, deterministic, doctested.** No DB, no process, no randomness.

## Algorithm

```
ord = Rating.ordinal({mu, sigma})            # mu - 3*sigma

provisional? = games_count < min_games OR sigma >= max_sigma

if provisional? -> %{tier: :provisional, provisional: true}
else            -> %{tier: band_for(ord), provisional: false}

band_for(ord):
  ord >= master_min   -> :master
  ord >= platinum_min -> :platinum
  ord >= gold_min     -> :gold
  ord >= silver_min   -> :silver
  _                    -> :bronze        # bronze is the floor / catch-all
```

### Provisional logic — conservative AND-clear (decided)

Provisional is **TRUE** while `games_count < min_games` **OR** `sigma >= max_sigma`.
It clears **only when** `games_count >= min_games` **AND** `sigma < max_sigma`.

Justification: the ticket phrases the clear condition as "enough games / once σ
below threshold". Read as OR-to-clear, a brand-new profile at the very first
rated game could already be tiered if σ dipped (or could be tiered on games alone
while still wildly uncertain) — both undermine the point of a provisional period,
which is to *not* show a confident band until the estimate is trustworthy. The
conservative reading — provisional persists until the player has both played
enough AND the model is confident (low σ) — is the only one that guarantees we
never advertise a misleading band early. `min_games` and `max_sigma` are
independent dials, so product can later relax one without code changes.

Crucially, `max_sigma` is **strictly below** the rounded schema default `8.333`
(and below the exact `Rating.default/0` σ of `25/3 = 8.3333…`). A never-rated user
sits at `(25.0, 8.333, 0)`: `games_count 0 < 10` AND `8.333 >= 6.0`, so they stay
**provisional** regardless of the `8.333` vs `25/3` float mismatch. We do not rely
on float-equality to detect "unrated" — the `>=`/`<` band around `6.0` carries it.

### Default thresholds (launch placeholders, tunable — NOT finely calibrated)

Ordinal starts at **0.0** for a new player (`25 − 3·(25/3) = 0`), rises with wins
(μ up, σ down both push it up), can dip slightly negative for a player who only
loses. There is no hard cap. Cutoffs below are chosen against that open scale; a
cleared-provisional player (σ < 6.0) has ordinal `μ − 18`, so meaningful spread
shows up a few points above 0 and the upper bands sit progressively higher. These
are round placeholders to be recalibrated against the real distribution.

| Key                     | Default | Meaning                                                  |
|-------------------------|---------|----------------------------------------------------------|
| `provisional_min_games` | `10`    | rated games required before a band can show              |
| `provisional_max_sigma` | `6.0`   | σ must be **strictly below** this to clear (< 8.333)     |
| `bronze_min`            | `0.0`   | ordinal floor for Bronze (also the catch-all below it)   |
| `silver_min`            | `10.0`  | ordinal ≥ 10 → Silver                                    |
| `gold_min`              | `18.0`  | ordinal ≥ 18 → Gold                                      |
| `platinum_min`          | `26.0`  | ordinal ≥ 26 → Platinum                                  |
| `master_min`            | `34.0`  | ordinal ≥ 34 → Master                                    |

Bands use `>=` lower bounds; Bronze is the catch-all for any non-provisional
ordinal below `silver_min` (including slightly negative ordinals), so
`bronze_min` is informational/documentation only and not a gate the code can fall
through (every non-provisional rating resolves to at least Bronze).

## Config

DECLARE — append to `config/config.exs` (after the `Lifecycle` block, ~line 41):

```elixir
# Skill-tier thresholds (PID-48). Bands are read off Rating.ordinal/1 (mu - 3*sigma).
# Launch defaults, tunable — NOT finely calibrated; recalibrate against the real
# ordinal distribution. provisional_max_sigma MUST stay strictly below the 8.333
# schema default so never-rated users remain provisional.
config :pidro_server, PidroServer.Rating.Tier,
  provisional_min_games: 10,
  provisional_max_sigma: 6.0,
  bronze_min: 0.0,
  silver_min: 10.0,
  gold_min: 18.0,
  platinum_min: 26.0,
  master_min: 34.0
```

READ — in `tier.ex`, matching the `Lifecycle` precedent (runtime `get_env`, NOT
`compile_env`, because thresholds are explicitly tunable):

```elixir
@defaults %{
  provisional_min_games: 10,
  provisional_max_sigma: 6.0,
  bronze_min: 0.0,
  silver_min: 10.0,
  gold_min: 18.0,
  platinum_min: 26.0,
  master_min: 34.0
}

@spec defaults() :: map()
def defaults, do: @defaults

defp config(key) when is_map_key(@defaults, key) do
  app_config = Application.get_env(:pidro_server, __MODULE__, [])
  Keyword.get(app_config, key, Map.fetch!(@defaults, key))
end
```

`config/test.exs` override: **not required.** The launch defaults are themselves
testable fixed values and tests assert against them directly. Add a
`config :pidro_server, PidroServer.Rating.Tier, ...` block to `config/test.exs`
**only** if a config-override test needs a distinct value at runtime — see the
"config override respected" test below, which uses `Application.put_env/3` +
`on_exit` to avoid coupling to a global test override. Decision: **no
`config/test.exs` change**; the override test is self-contained.

## Test Plan (ExUnit)

`PidroServer.Rating.TierTest` — `apps/pidro_server/test/pidro_server/rating/tier_test.exs`

Pure module: `use ExUnit.Case, async: true` (NO `DataCase` — no DB).
`doctest PidroServer.Rating.Tier`. Style mirrors `rating_test.exs`:
`describe`/`test` blocks on the returned map. Build ratings with explicit
`{mu, sigma}` chosen so `mu - 3*sigma` lands at a known ordinal.

Helper convention: pick `sigma` below `provisional_max_sigma` (e.g. `5.0`) and
solve `mu` for a target ordinal (`mu = ord + 3*sigma = ord + 15`) so band tests
are not also fighting the provisional gate.

### `describe "defaults / new player"`
- Unrated profile `classify(25.0, 8.333, 0)` ⇒ `%{tier: :provisional, provisional: true}`.
- `classify(25.0, 25/3, 0)` (exact `Rating.default/0` σ) ⇒ also `:provisional`
  (proves the `8.333` vs `25/3` float mismatch is harmless).
- `defaults/0` returns the documented map.

### `describe "provisional gate"`
- **σ above ceiling, games sufficient:** `classify(40.0, 6.0, 50)` (σ == max_sigma,
  i.e. `>=`) ⇒ provisional true (band suppressed).
- **σ just below ceiling, games sufficient:** `classify(40.0, 5.999, 50)` ⇒ NOT
  provisional (clears) — boundary exactness of `sigma < max_sigma`.
- **games below min, σ low:** `classify(40.0, 3.0, 9)` ⇒ provisional true.
- **games at min, σ low:** `classify(40.0, 3.0, 10)` ⇒ NOT provisional (clears) —
  boundary exactness of `games_count >= min_games`.
- **AND-clear:** only `games_count >= 10 AND sigma < 6.0` clears; assert each of the
  three failing corners (low games+low σ, high games+high σ, low games+high σ)
  stays provisional and the passing corner clears.

### `describe "band classification (cleared provisional)"`
For each, σ = 5.0, games = 50 (cleared), μ solved for the target ordinal:
- ordinal `0.0` (μ=15.0) ⇒ `:bronze`.
- ordinal `-2.0` (μ=13.0, slightly negative) ⇒ `:bronze` (catch-all floor).
- ordinal `9.999` (just below silver_min) ⇒ `:bronze`.
- ordinal `10.0` (silver_min) ⇒ `:silver` (`>=` boundary exact).
- ordinal `15.0` ⇒ `:silver`.
- ordinal `18.0` (gold_min) ⇒ `:gold` (boundary exact).
- ordinal `26.0` (platinum_min) ⇒ `:platinum` (boundary exact).
- ordinal `34.0` (master_min) ⇒ `:master` (boundary exact).
- ordinal `100.0` (well above) ⇒ `:master`.

### `describe "ordinal is mu - 3*sigma, not raw mu"`
- Two ratings with the **same μ** but different σ land in different bands once
  cleared: e.g. high-μ/high-but-cleared-σ has lower ordinal than high-μ/low-σ.
  Asserts band tracks `ordinal`, not μ. (Pick both σ < 6.0 so both are cleared.)

### `describe "classify/1 profile overload"`
- `classify(%{rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50})`
  equals `classify(40.0, 5.0, 50)`.
- Unrated profile map ⇒ `:provisional`.

### `describe "config override respected"`
- `Application.put_env(:pidro_server, PidroServer.Rating.Tier, master_min: 12.0)`
  with `on_exit` restoring prior env; assert a rating at ordinal `12.0` now
  classifies `:master` (was `:silver` under defaults). Proves runtime `get_env`
  read (not compile-baked).
- Same pattern for `provisional_max_sigma`: lower it to `2.0` and assert a rating
  with σ `5.0` (cleared under defaults) is now provisional.

### Doctests
- `classify(25.0, 8.333, 0)` ⇒ `%{tier: :provisional, provisional: true}` in the
  `@doc`/`@moduledoc`.
- A cleared example, e.g. `classify(40.0, 5.0, 50)` ⇒ a concrete band map.

## Implementation Checklist (ordered, each independently verifiable)

1. **Add config block** to `config/config.exs` (the `PidroServer.Rating.Tier`
   keyword list above).
2. **Create the module** `apps/pidro_server/lib/pidro_server/rating/tier.ex`:
   `@type tier`, `@type result`, `@defaults`, `defaults/0`, private `config/1`,
   `classify/3`, `classify/1`, with `@moduledoc`/`@doc`/`@spec` + doctests. Bands
   off `Rating.ordinal/1`; provisional = `games < min OR sigma >= max`.
3. **Write tests** `apps/pidro_server/test/pidro_server/rating/tier_test.exs` per
   the Test Plan; run green
   (`mix test apps/pidro_server/test/pidro_server/rating/tier_test.exs`).
4. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer,
   credo all green (dialyzer happy with `tier`/`result` types and the map specs).

## Files to Create / Modify

**Create:**
- `apps/pidro_server/lib/pidro_server/rating/tier.ex` — `PidroServer.Rating.Tier`
  pure module.
- `apps/pidro_server/test/pidro_server/rating/tier_test.exs` — ExUnit + doctest.

**Modify:**
- `config/config.exs` — add the `config :pidro_server, PidroServer.Rating.Tier`
  block (after the `Lifecycle` block, ~line 41).

**Not modified:**
- `config/test.exs` — no change; the config-override test is self-contained via
  `Application.put_env` + `on_exit`.

## Acceptance Criteria

- [ ] `PidroServer.Rating.Tier.classify(mu, sigma, games_count)` returns
      `%{tier:, provisional:}`, pure and deterministic.
- [ ] `classify/1` profile overload reads `rating_mu`/`rating_sigma`/
      `rating_games_count` and matches `classify/3`.
- [ ] Bands derived from `Rating.ordinal/1` (`μ − 3σ`), not raw μ.
- [ ] Provisional TRUE while `games < min_games OR sigma >= max_sigma`; clears only
      when BOTH satisfied. Never-rated `(25.0, 8.333, 0)` is provisional.
- [ ] `provisional_max_sigma` default is strictly below `8.333`.
- [ ] Thresholds read via `Application.get_env/3` + `@defaults` (runtime tunable);
      a config override changes classification.
- [ ] No DB column, no persistence, no API exposure, no delta logic in this ticket.
- [ ] `mix precommit` green.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/rating.ex` — `Rating.ordinal/1` (`μ − 3σ`),
  `default/0` (σ = 25/3) this module consumes.
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:30-33` — rating
  columns + defaults (25.0 / 8.333 / 0) the inputs come from.
- `apps/pidro_server/lib/pidro_server/games/lifecycle.ex:33-69` — the
  `@defaults` + `Application.get_env/3` + private `config/1` tunable pattern copied
  here.
- `config/config.exs:25-41`, `config/test.exs:39-56` — config declare/override
  precedent.
- `apps/pidro_server/test/pidro_server/rating_test.exs` — pure-module test style
  (`async: true`, `doctest`, `describe`/`test`).

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-48-skill-tiers.md](../ratings-player-profiles/research/PID-48-skill-tiers.md)
- **Linear issue:** PID-48
