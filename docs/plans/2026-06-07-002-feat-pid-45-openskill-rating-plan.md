---
title: "feat: Integrate OpenSkill team rating (μ + σ)"
type: feat
status: active
date: 2026-06-07
linear: PID-45
origin: docs/ratings-player-profiles/research/PID-45-openskill-rating.md
---

# feat: Integrate OpenSkill team rating (μ + σ)

## Overview

PID-44 shipped the `player_profiles` rating columns (`rating_mu` default 25.0,
`rating_sigma` default 8.333, `rating_games_count` default 0) and the completion
seam `PidroServer.Profiles.apply_completed_game/2`. PID-45 delivers the **pure
math** that turns "two partnerships + which one won" into updated `{mu, sigma}`
per player — and nothing else.

The deliverable is a single pure module `PidroServer.Rating` exposing a stable,
library-agnostic API (`default/0`, `rate/2`, `ordinal/1`) plus its ExUnit tests.
The estimator behind that API is the OpenSkill (Weng-Lin Bayesian) model. We add
the `openskill` hex package as the **primary** implementation, wrapped behind our
module so it stays swappable; if the package fails a compile/smoke gate on this
toolchain we **fall back** to an in-house pure Weng-Lin implementation in the same
module. The public API is identical either way, so downstream (PID-46 rerating
job, PID-47 completion wiring) is unaffected by which path wins.

This follows the project principle (`apps/pidro_server/CLAUDE.md`): pure functions
over GenServer logic; the estimator is one pure module so swapping it is a local
change, not a behaviour/protocol abstraction (YAGNI — we do NOT introduce one).

## Problem Statement / Motivation

- The rating columns exist but nothing computes them. Every completed game should
  nudge the four players' `{mu, sigma}` per a published, license-free skill model.
- The math must be **pure and deterministic** so PID-46 can replay history to
  re-rate and PID-47 can call it from the completion transaction.
- We want correct, published math (Weng-Lin), not a hand-rolled rating curve — but
  the only Elixir package is 6 years unmaintained, so we must not adopt it blindly.

## Non-Goals (owned by later tickets)

PID-45 is the pure module + its tests. Explicitly OUT of scope:

- **No DB reads or writes.** No `Repo`, no `PlayerProfile` changeset, no migration.
  `PidroServer.Rating` takes and returns plain `{mu, sigma}` tuples only.
- **No game-completion wiring.** Mapping `player_results`/`winner` into the two
  team lists, loading/persisting profiles, and calling `Rating.rate/2` from
  `Profiles.apply_completed_game/2` is **PID-47**. This plan documents the mapping
  (see "Input mapping (for PID-47)") but does not implement it.
- **No rerating / backfill job** — PID-46.
- **No tiers/divisions** (PID-48 derives those from `ordinal/1`).
- **No bot/guest/abandoned policy.** Deciding whether a partnership with a missing
  or bot player is rated, skipped, or padded is PID-47's filtering decision. The
  pure module just rates whatever two non-empty teams it is given.
- **No tuning.** Library defaults (μ=25, σ=25/3, β=25/6, default κ) — the ticket
  says defaults are fine. No score-margin input (see "Blowout vs close").

## Stable Public API (the contract PID-46/47 depend on)

`PidroServer.Rating` — `apps/pidro_server/lib/pidro_server/rating.ex`

```elixir
defmodule PidroServer.Rating do
  @moduledoc """
  Pure OpenSkill (Weng-Lin Bayesian) team rating: two partnerships + outcome →
  updated (mu, sigma) per player. Library-agnostic facade — the estimator behind
  it is swappable without touching callers (PID-46 rerating, PID-47 completion).

  A rating is a `{mu, sigma}` tuple of floats. New players init to `default/0`
  (mu = 25.0, sigma = 25/3 ≈ 8.333). The model is *order-only*: it consumes who
  won, NOT by how much, so a blowout and a nail-biter produce identical updates.
  """

  @type rating :: {mu :: float(), sigma :: float()}

  @doc "New-player initial rating: `{25.0, 8.333333333333334}` (μ=25, σ=25/3)."
  @spec default() :: rating()
  def default()

  @doc """
  Updates ratings given a result. `winning_team` and `losing_team` are each a
  non-empty list of `{mu, sigma}`. Returns `%{winners: [...], losers: [...]}`
  with updated tuples in the SAME order as the inputs. Pure & deterministic.
  Winners' μ rises, losers' μ falls, every σ shrinks.
  """
  @spec rate([rating()], [rating()]) :: %{winners: [rating()], losers: [rating()]}
  def rate(winning_team, losing_team)

  @doc "Conservative scalar for display/sorting: `mu - 3 * sigma`."
  @spec ordinal(rating()) :: float()
  def ordinal({mu, sigma})
end
```

Design notes:

- **`rate/2` takes winner + loser explicitly** (not a generic ranked list of
  teams). The game is always exactly two partnerships with exactly one winner and
  no draws, so an explicit `(winners, losers)` signature is the honest contract and
  removes any "first team is the winner" convention footgun at the call site.
- **Returns a map `%{winners:, losers:}`**, not a flat list, so callers never have
  to re-split. Order within each list is preserved so PID-47 can zip results back
  to the user ids it passed in.
- **No ids in the API.** PID-47 keeps its own `[user_id]` ↔ `[rating]` ordering;
  the pure module stays about numbers only. (This is simpler than `rate_with_ids`
  and keeps the module DB/identity-free.)
- **Tuples, not a struct.** Matches the columns (`rating_mu`/`rating_sigma`), the
  package's own shape, and the engine's "plain values in/out" style.

## Primary vs Fallback + Decision Gate

### Primary — wrap the `openskill` hex package

Add the dependency to `apps/pidro_server/mix.exs` (the rating consumer is
server-side; the umbrella shares one `mix.lock`):

```elixir
{:open_api_spex, "~> 3.22.2"},
{:openskill, "~> 1.0"}        # <-- add this line (after open_api_spex)
```

Implement `PidroServer.Rating` as a thin facade over `Openskill`:

- `default/0` → `Openskill.rating()` (returns `{25, 8.333333333333334}`; coerce mu
  to float so the contract is always `{float, float}`).
- `rate/2` → call `Openskill.rate([winning_team, losing_team])` (first team is the
  winner in the package's convention), then return
  `%{winners: hd(result), losers: hd(tl(result))}`.
- `ordinal/1` → `Openskill.ordinal(rating)` (it already computes `mu - 3*sigma`).

### Decision Gate (run during implementation, before committing to primary)

The primary path is adopted ONLY if ALL of these pass on this toolchain
(Elixir 1.19 / OTP 28, the umbrella `mix.lock`):

1. **Resolves & compiles:** `mix deps.get` then `mix deps.compile openskill`
   succeed — `openskill` and its runtime deps `math ~> 0.7.0` + `statistics
   ~> 0.6.3` resolve against the existing lock and compile with no errors.
2. **Smoke test produces sane output** in `iex -S mix` (see commands). Concretely,
   for a balanced 2v2 with the winners listed first, the result must show:
   winners' μ **strictly increased**, losers' μ **strictly decreased**, and every
   player's σ **strictly decreased** vs the `25/8.333` inputs.

Exact gate commands:

```bash
# from apps/pidro_server (or repo root with `mix cmd --app pidro_server`)
mix deps.get
mix deps.compile openskill
mix compile

# smoke test (paste into `iex -S mix`):
#   r = Openskill.rating()                 # => {25, 8.333333333333334}
#   [[w1, w2], [l1, l2]] = Openskill.rate([[r, r], [r, r]])
#   {wmu, wsig} = w1; {lmu, lsig} = l1
#   true = wmu > 25.0 and lmu < 25.0 and wsig < 8.333 and lsig < 8.333
#   Openskill.ordinal(w1)                  # => mu - 3*sigma (a float)
```

If any gate step fails (won't resolve, won't compile under 1.19/OTP 28, or output
is not monotonic), **switch to the fallback** and back out the dep (below).

### Fallback — in-house pure Weng-Lin (same module, same API)

If the gate fails, implement the numerics directly in `PidroServer.Rating`
(deleting the package usage; the public API is unchanged). Use the Weng-Lin
**Thurstone-Mosteller full-pairing** update for the 2-team case, with OpenSkill
defaults: **μ₀=25**, **σ₀=25/3 ≈ 8.333**, **β=25/6 ≈ 4.1667**, default **κ=0.0001**
(variance floor to keep σ² positive). Sketch (winner = team A):

- Per team: `mu_team = Σ player_mu`, `sigma_sq_team = Σ player_sigma²`.
- `c = sqrt(sigma_sq_A + sigma_sq_B + 2*β²)`; `t = (mu_A − mu_B) / c`.
- `v(t) = pdf(t) / cdf(t)`, `w(t) = v(t) * (v(t) + t)` (standard normal pdf/cdf,
  via a `:math.erf`-based approximation — a handful of lines, no external dep).
- For each winner player: `mu' = mu + (sigma²/c) * v`,
  `sigma'² = sigma² * max(1 − (sigma²/c²)*w, κ)`; losers use `−v` for μ and the
  same shrink for σ. `sigma' = sqrt(sigma'²)`.

Note the published Weng-Lin uses the team σ² as the per-player weighting numerator
divided by `c`; implement exactly per the paper
(https://www.csie.ntu.edu.tw/~cjlin/papers/online_ranking/online_journal.pdf) so a
cross-check against any reference port matches. This path owns its numerics, so the
test suite (below) is what validates it; it is identical to the primary's tests
because the API and qualitative behavior are identical.

### Backing out the dependency (primary → fallback)

1. Remove the `{:openskill, "~> 1.0"}` line from `apps/pidro_server/mix.exs`.
2. `mix deps.unlock openskill math statistics` then `mix deps.get` to drop them
   from `mix.lock` (only if no other dep pulls `math`/`statistics`).
3. Replace the facade body in `PidroServer.Rating` with the in-house numerics.
   No caller changes — `default/0`, `rate/2`, `ordinal/1` keep their signatures.

## Input mapping (for PID-47 — documented, not implemented here)

At the `Profiles.apply_completed_game(player_results, winner)` seam, PID-47 will:

- Group the (up to four) `player_results` entries by `team` via `position`
  (`:north`/`:south` → `:north_south`; `:east`/`:west` → `:east_west`).
- Load each user's `{rating_mu, rating_sigma}` from their `PlayerProfile`.
- Build `winners`/`losers` lists ordered to match a kept `[user_id]` list, calling
  `Rating.rate(winners, losers)` where `winner` selects which group is `winners`.
- Write the updated tuples back per user and bump `rating_games_count`.

Edge cases (missing/bot players, abandoned/substitute, guests, write-race) are
PID-47's to resolve and are listed as open questions in the research doc. PID-45
only guarantees: give it two non-empty equal-or-unequal-length teams of `{mu,
sigma}` and it returns sane updates.

## Blowout vs Close (explicit, so the reviewer isn't surprised)

The Weng-Lin / OpenSkill model is **order-only**: `rate/2` consumes *who won*, not
the score margin. There is no score input in the public API. Therefore a 62–0
blowout and a 62–61 nail-biter between the same four ratings produce **identical**
updated tuples. This is correct and intended (the ticket says don't over-tune;
defaults fine). The "blowout vs close behaving sensibly" acceptance is satisfied by:

- A test asserting blowout `==` close (equality — same inputs, same output,
  because margin is not an input). This documents the property in code.
- Sane *monotonic* behavior tests: winner μ up, loser μ down, σ shrinks, an upset
  (low-rated team beats high-rated team) moves μ **more** than an expected result,
  and repeated wins raise μ with **diminishing** per-game change while σ shrinks.

"Sensible" here means the magnitude of change scales with the surprise of the
result (the μ gap), not with the score margin — which falls straight out of the
model with zero tuning.

## Test Plan (ExUnit)

`PidroServer.RatingTest` — `apps/pidro_server/test/pidro_server/rating_test.exs`

Pure module: `use ExUnit.Case, async: true` (NO `DataCase` — no DB). Follows the
engine style (`scorer_test.exs`): `doctest PidroServer.Rating`, `describe`/`test`
blocks asserting on returned tuples. Use a small `assert_in_delta`/comparison
helper for floats. Tests are model-agnostic — they pass for either primary or
fallback.

### `describe "default/0"`
- returns `{25.0, sigma}` with `mu == 25.0` and `sigma` within delta of `25/3`
  (≈ 8.3333). Both elements are floats.

### `describe "ordinal/1"`
- `ordinal({25.0, 8.333}) == 25.0 - 3*8.333` (within delta).
- higher μ at equal σ ⇒ higher ordinal; higher σ at equal μ ⇒ lower ordinal
  (uncertainty penalized).

### `describe "rate/2 — single win monotonicity"`
- 2v2 of all-default ratings, team A wins: every winner μ **>** 25.0, every loser
  μ **<** 25.0, every σ (all four) **<** 8.333.
- result map has `winners`/`losers` keys, each length 2.
- order preserved: distinguish the two winners by giving them different μ and
  assert the output keeps that positional order.
- works for 1v1 (single-element teams) and asymmetric sizes (1 vs 2) without error.

### `describe "rate/2 — blowout == close"`
- Same four ratings, "blowout" and "close" are the SAME call (no margin input):
  assert `rate(w, l) == rate(w, l)` and document that margin is not consumed, so
  the two scenarios are identical by construction. (Explicit equality assertion to
  freeze the order-only property.)

### `describe "rate/2 — upset vs expected"`
- Strong team (high μ) beats weak team (low μ): winners' μ gain is **small**.
- Weak team beats strong team (upset): winners' μ gain is **larger** than the
  expected-result case. Asserts magnitude scales with surprise, not margin.

### `describe "rate/2 — σ shrink over repeated games"`
- Feed the same matchup repeatedly (winner keeps winning), threading each output
  back as the next input: σ decreases monotonically across games, μ increases
  monotonically, and the per-game μ change **diminishes** (game N+1's gain <
  game N's gain). Confirms convergence behavior.

### `describe "rate/2 — symmetry"`
- Swapping which side is `winners` vs `losers` mirrors the deltas: if A-beats-B
  gives winner +Δμ / loser −Δμ', then B-beats-A from the same starting ratings
  gives the symmetric result (sign-flipped μ moves), σ shrink identical.

### `describe "rate/2 — determinism"`
- Calling `rate/2` twice with identical inputs returns byte-identical tuples
  (`==`). No randomness, no global state.

## Implementation Checklist (ordered, each independently verifiable)

1. **Add dep (primary).** Add `{:openskill, "~> 1.0"}` to
   `apps/pidro_server/mix.exs` deps. Run `mix deps.get`.
2. **Run the Decision Gate.** `mix deps.compile openskill`, `mix compile`, and the
   `iex` smoke test above. Record pass/fail.
   - **Pass →** proceed with the facade (step 3a).
   - **Fail →** back out the dep (see "Backing out"), proceed with the in-house
     numerics (step 3b).
3a. **Implement facade** `PidroServer.Rating` over `Openskill` (default/rate/ordinal),
    with `@moduledoc`/`@doc`/`@spec` and doctest examples. Coerce μ to float in
    `default/0`.
3b. **(Fallback) Implement in-house Weng-Lin** numerics in the same module, same
    public API, with a private normal pdf/cdf helper.
4. **Write tests** `rating_test.exs` per the Test Plan; run green
   (`mix test apps/pidro_server/test/pidro_server/rating_test.exs`).
5. **`mix precommit`** — format, compile (no warnings), full suite, dialyzer,
   credo all green. (Dialyzer must be happy with the `rating` type and specs.)

## Files to Create / Modify

**Create:**
- `apps/pidro_server/lib/pidro_server/rating.ex` — `PidroServer.Rating` pure module.
- `apps/pidro_server/test/pidro_server/rating_test.exs` — ExUnit tests + doctest.

**Modify (primary path only):**
- `apps/pidro_server/mix.exs` — add `{:openskill, "~> 1.0"}` to `deps/0`
  (after `{:open_api_spex, "~> 3.22.2"}`, ~line 129). Reverted if the gate fails.
- `mix.lock` (umbrella root) — populated by `mix deps.get` with `openskill`,
  `math`, `statistics`. Reverted via `mix deps.unlock` if the gate fails.

## Acceptance Criteria

- [ ] `PidroServer.Rating.default/0` returns `{25.0, ~8.333}` (μ=25, σ=25/3), floats.
- [ ] `rate/2` is pure, deterministic, order-preserving; returns
      `%{winners:, losers:}` with updated `{mu, sigma}`.
- [ ] Single win: winners' μ up, losers' μ down, all σ shrink.
- [ ] Blowout == close (order-only model; margin not consumed) — asserted in a test.
- [ ] Repeated wins: σ shrinks and μ rises with diminishing per-game change.
- [ ] `ordinal/1` returns `mu − 3σ`.
- [ ] No DB access and no completion wiring in this ticket (PID-47 owns those).
- [ ] Estimator is behind the single pure module so it stays swappable (no
      behaviour/protocol). Primary uses `openskill`; fallback is in-house Weng-Lin
      with the identical API.
- [ ] `mix precommit` green.

## Dependencies & Risks

- **Risk — unmaintained package (primary).** `openskill` last released 2020-04-22,
  declares `elixir ~> 1.14`, unverified on 1.19/OTP 28, pulls old `math` +
  `statistics`. Mitigated by the Decision Gate (must resolve/compile/smoke-pass) and
  the in-house fallback with the identical API — adopting the package is reversible
  with no caller impact.
- **Risk — numerics correctness (fallback).** Hand-rolled Weng-Lin must match the
  published update. Mitigated by implementing straight from the paper with
  OpenSkill defaults and by the monotonicity/symmetry/convergence test suite.
- **Downstream:** PID-46 (rerating job) and PID-47 (completion wiring + profile
  persistence + bot/guest/abandoned policy) consume this module's API unchanged
  regardless of which path won.

## Sources & References

### Internal
- `apps/pidro_server/lib/pidro_server/profiles/player_profile.ex:30-33` — rating
  columns + defaults (25.0 / 8.333 / 0) this module's outputs feed.
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex:100-115` —
  `apply_completed_game/2` seam (PID-47 will call `Rating.rate/2` from here).
- `apps/pidro_server/mix.exs:94-131` — `deps/0` (where `{:openskill, "~> 1.0"}`
  goes); umbrella shares one `mix.lock`.
- `apps/pidro_engine/test/unit/finnish/scorer_test.exs` — representative pure-module
  test style (`async: true`, `doctest`, `describe`/`test` on returned values).

### Origin
- **Research:** [docs/ratings-player-profiles/research/PID-45-openskill-rating.md](../ratings-player-profiles/research/PID-45-openskill-rating.md)
- **Linear issue:** PID-45
- OpenSkill / Weng-Lin paper: https://www.csie.ntu.edu.tw/~cjlin/papers/online_ranking/online_journal.pdf
- Package: https://hex.pm/packages/openskill (MIT, pure Elixir, v1.0.1)
