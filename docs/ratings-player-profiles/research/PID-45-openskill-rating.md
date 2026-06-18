---
date: 2026-06-07
ticket: PID-45
topic: "Integrate OpenSkill team rating (μ + σ) — dependency feasibility + codebase placement (as-is)"
status: complete
---
# Research: PID-45 OpenSkill team rating (μ + σ)

## Summary

A usable Elixir/Hex package exists: **`openskill`** (repo `philihp/openskill.ex`), an Elixir
implementation of the **Weng-Lin** Bayesian ranking (the license-free TrueSkill alternative the
ticket names). Its public API is exactly the shape the ticket wants: ratings are `{mu, sigma}`
tuples, `Openskill.rating/0` returns the library defaults `{25, 8.333333333333334}` (confirms the
ticket's 25.0 / 8.333), and `Openskill.rate/1` takes a list of teams (each a list of player rating
tuples), treats the **first team as the winner**, and returns the same nested shape with updated
`{mu, sigma}` per player. A 2v2 partnership is `[[a1, a2], [b1, b2]]` in and out — native, no
reshaping. There is also `rate_with_ids/2` (carry player ids; `:as_map` for a flat
`%{id => {mu, sigma}}`) and `ordinal/1` (`mu - 3*sigma` conservative display rating).

**Caveats (verifiable):** last release **v1.0.1 on 2020-04-22** (~6 years stale; effectively
unmaintained), **pre-1.0-feel / pinned at 1.x**, MIT licensed, pure-Elixir (no NIFs). Its declared
`elixir` requirement is `~> 1.14`; this umbrella pins `~> 1.19` (engine + server + root all
`elixir: "~> 1.19"`). `~> 1.14` is satisfied by 1.19 from the dependency's side, but the package was
last built against much older Elixir/OTP and has **not** been verified by Anthropic/here against
Elixir 1.19 / OTP 28. Its two runtime deps are `{:math, "~> 0.7.0"}` and `{:statistics, "~> 0.6.3"}`
(both also old, pure-Elixir). It is **not** currently in `mix.lock` or any `mix.exs` (grep: no
matches anywhere except this doc).

PID-44 already shipped the rating columns with the matching defaults
(`rating_mu` 25.0, `rating_sigma` 8.333, `rating_games_count` 0) and the completion hook
(`Profiles.apply_completed_game/2`) where a rating update would slot in. Pure modules + their unit
tests live overwhelmingly in `apps/pidro_engine/` (namespace `Pidro.*`, tests under
`apps/pidro_engine/test/unit/...` mirroring lib paths); a server-side non-engine pure helper would
sit as/under a context in `apps/pidro_server/lib/pidro_server/` (e.g. alongside `Profiles`).

## Dependency findings

### Package identity
- **Hex package name:** `openskill` — https://hex.pm/packages/openskill
- **GitHub:** https://github.com/philihp/openskill.ex (author philihp; also maintains the JS/Go ports)
- **Docs:** https://hexdocs.pm/openskill (redirects to https://openskill.hexdocs.pm/Openskill.html)
- **Latest version:** **1.0.1**
- **Last release date:** **2020-04-22** (~6 years old as of 2026-06-07)
- **License:** **MIT**
- **Downloads (hex.pm, observed):** ~585 last-30-days / ~932 all-time — low but nonzero usage.
- **Underlying method:** Weng-Lin Bayesian online ranking
  (paper: https://www.csie.ntu.edu.tw/~cjlin/papers/online_ranking/online_journal.pdf), the
  patent-/license-free alternative to Microsoft TrueSkill.

### Compatibility / red flags (verifiable)
- **Declared `elixir` requirement:** `elixir: "~> 1.14"` (from the repo `mix.exs`). This umbrella is
  `elixir: "~> 1.19"` in `mix.exs:8`, `apps/pidro_engine/mix.exs:15`, `apps/pidro_server/mix.exs:12`.
  `~> 1.14` admits 1.19, so the version constraint itself is not a blocker.
- **Maintenance:** last release 2020-04-22; no releases since. Treat as **unmaintained**.
- **Native deps / NIFs:** **none** — pure Elixir.
- **Its declared dependencies (from repo `mix.exs`):**
  - `{:math, "~> 0.7.0"}` (runtime) — pure-Elixir math helpers.
  - `{:statistics, "~> 0.6.3"}` (runtime) — pure-Elixir stats (normal pdf/cdf etc.).
  - dev/test only: `{:excoveralls, "~> 0.18"}`, `{:ex_doc, ">= 0.0.0"}`, `{:mix_test_watch, "~> 1.2"}`.
- **Not verified here:** an actual compile/run under Elixir 1.19 / OTP 28. Both runtime deps are
  also old (2018-era versions); whether they resolve cleanly against this umbrella's lock is an open
  item (see Open Questions). No archived flag observed on the GitHub repo.

### Public API (concrete)
Ratings are `{mu, sigma}` tuples (gaussian: mean + standard deviation).

- **`Openskill.rating/0`** → default `{25, 8.333333333333334}` (≈ 25 and 25/3). Confirms the
  ticket's "new players init to library defaults (25.0 / 8.333)".
- **`Openskill.rating/2`** → `Openskill.rating(mu, sigma)` for custom values, e.g.
  `Openskill.rating(32.444, 5.123)` → `{32.444, 5.123}`.
- **`Openskill.rate/1`** (the update function) → input is a list of teams, each team a list of
  player rating tuples; **the first team is treated as the winner** (highest rank). Output is the
  same nested structure with updated tuples. Winners' `mu` rises; losers' `mu` falls; `sigma`
  shrinks for everyone (less uncertainty after observing a result).
- **`Openskill.rate_with_ids/2`** → same as `rate/1` but each player is `{id, {mu, sigma}}`;
  preserves ids on output; option `as_map: true` returns a flat `%{id => {mu, sigma}}`.
- **`Openskill.ordinal/1`** → `mu - 3*sigma`, a conservative scalar for leaderboards/sorting.
- **Default model:** OpenSkill (across its ports/docs) defaults to **Plackett-Luce** (a generalized
  Bradley-Terry); Thurstone-Mosteller is the alternative model. For the 2-team case `rate/1` gives
  sensible win/loss updates either way. (OpenSkill model docs:
  https://openskill.me/en/stable/api/openskill.models.weng_lin.plackett_luce.html)

#### Minimal usage example (verbatim from README)
```elixir
> a1 = Openskill.rating
{25, 8.333333333333334}
> a2 = Openskill.rating(32.444, 5.123)
{32.444, 5.123}
> b1 = Openskill.rating(43.381, 2.421)
{43.381, 2.421}
> b2 = Openskill.rating(25.188, 6.211)
{25.188, 6.211}

# First team is the winner. 2v2 partnership passed natively as [[a1,a2],[b1,b2]].
> [[a1, a2], [b1, b2]] = Openskill.rate([[a1, a2], [b1, b2]])
[
  [
    {28.669648436582808, 8.071520788025197},
    {33.83086971107981, 5.062772998705765}
  ],
  [
    {43.071274808241974, 2.4166900452721256},
    {23.149503312339064, 6.1378606973362135}
  ]
]
```
With ids:
```elixir
> Openskill.rate_with_ids([
    [{"a1", a1}, {"a2", a2}],
    [{"b1", b1}, {"b2", b2}]
  ], as_map: true)
%{
  "a1" => {28.669648436582808, 8.071520788025197},
  "a2" => {33.83086971107981, 5.062772998705765},
  "b1" => {43.071274808241974, 2.4166900452721256},
  "b2" => {23.149503312339064, 6.1378606973362135}
}
```
**Install snippet (README):** `{:openskill, "~> 1.0"}` in `mix.exs` deps.

Note the example output: the winning team (`[a1,a2]`, listed first) gains `mu` (25→28.67, 32.44→33.83)
while the losing team's stronger player loses `mu` (b1 43.38→43.07, b2 25.19→23.15), and every
player's `sigma` shrinks. "Blowout vs close" behaving sensibly (per the acceptance criteria) is a
function of the gap between the input `mu`s — a heavy-favorite win moves ratings little; an upset
moves them a lot — which falls straight out of `rate/1` with no tuning.

### Presence in this repo
- Grep for `openskill` across `mix.exs` / `mix.lock` / `apps/**/*.ex(s)`: **no matches** (other than
  this doc). PID-44 deliberately left rating greenfield. So adding the dep means a new line in
  `apps/pidro_server/mix.exs` deps (the rating consumer lives server-side — see placement) and a
  `mix deps.get` to populate the umbrella-shared `mix.lock`.

## In-house alternative (feasibility only — no recommendation)

Implementing the Weng-Lin update in-house as a pure module is feasible and small for the fixed 2-team
shape this game has (always two partnerships, exactly one winner, no draws). The math is the
Weng-Lin Bayesian approximation (Thurstone-Mosteller for 2 teams, or Plackett-Luce generalized):
per team compute team `mu` = sum of player `mu`, team variance = sum of `sigma^2` + teams * `beta^2`;
derive `v`/`w` multiplier functions from the normal pdf/cdf at the standardized score difference;
update each player's `mu` by `±(sigma^2 / c) * v` and shrink `sigma` toward
`sigma^2 * (1 - sigma^2/c^2 * w)`. Library defaults used by OpenSkill: **μ = 25**, **σ = 25/3 ≈
8.333**, **β = 25/6 ≈ 4.1667** (and a small `tau`/dynamics term in some variants). The only external
primitive needed is the standard normal pdf/cdf (a handful of lines, or via `:math.erf`-based
approximations). This keeps the engine clean (a single pure function `update(team_a, team_b, outcome)
→ updated ratings`) and avoids an unmaintained dependency, at the cost of owning/validating the
numerics. Stated for plan awareness only.

## Codebase placement (engine vs server, test patterns)

### `apps/pidro_engine/` — pure modules + unit tests (the model for "pure")
- **Namespace:** `Pidro.*` (NOT `PidroEngine.*`; the top app module is `PidroEngine` but all domain
  code is under `Pidro`). Layout (from `apps/pidro_engine/lib/`):
  - `lib/pidro/core/` — pure data + types: `types.ex`, `card.ex`, `deck.ex`, `player.ex`, `trick.ex`,
    `gamestate.ex`, `events.ex`, `binary.ex` (`Pidro.Core.*`).
  - `lib/pidro/game/` — pure rules engine: `engine.ex`, `state_machine.ex`, `dealing.ex`,
    `bidding.ex`, `trump.ex`, `discard.ex`, `play.ex`, `replay.ex`, `errors.ex` (`Pidro.Game.*`).
  - `lib/pidro/finnish/` — pure Finnish-variant scoring: `rules.ex`, `scorer.ex`
    (`Pidro.Finnish.*`).
  - `lib/pidro/` OTP layer (the only stateful part): `server.ex`, `supervisor.ex`, `move_cache.ex`.
- **Tests:** `apps/pidro_engine/test/` split into `unit/`, `integration/`, `properties/`,
  `support/`. Unit tests **mirror the lib path**: e.g. `Pidro.Finnish.Scorer` →
  `test/unit/finnish/scorer_test.exs`. Property tests use `stream_data` (the engine's only test dep:
  `{:stream_data, "~> 1.0", only: [:dev, :test]}`).
- **`mix.exs` deps** (`apps/pidro_engine/mix.exs:175-192`): runtime `{:typed_struct, "~> 0.3"}`,
  `{:accessible, "~> 0.3"}`; test `{:stream_data, "~> 1.0"}`; dev/test `dialyxir`, `credo`; dev-only
  `benchee`, `ex_doc`. (If the rating math were placed in the engine, the `openskill` dep would be
  added here — but see "server" note below, since the rating *consumer* and DB live server-side.)

#### Representative pure module + test (verbatim)
A clean example of the engine's "pure function in / value out" style and its doctest+unit test
pairing is `Pidro.Finnish.Scorer`. Two representative functions:

```elixir
# apps/pidro_engine/lib/pidro/finnish/scorer.ex
@spec game_over?(Types.GameState.t()) :: boolean()
def game_over?(%Types.GameState{cumulative_scores: scores}) do
  Enum.any?(scores, fn {_team, score} -> score >= 62 end)
end

@spec determine_winner(Types.GameState.t()) :: {:ok, team()} | {:error, :game_not_over}
def determine_winner(%Types.GameState{cumulative_scores: scores, bidding_team: bidding_team} = state) do
  if game_over?(state) do
    ns_score = scores.north_south
    ew_score = scores.east_west
    winner =
      cond do
        ns_score >= 62 and ew_score >= 62 -> bidding_team
        ns_score >= 62 -> :north_south
        ew_score >= 62 -> :east_west
      end
    {:ok, winner}
  else
    {:error, :game_not_over}
  end
end
```

Its test (`apps/pidro_engine/test/unit/finnish/scorer_test.exs`) — note `async: true`, `doctest`,
and `describe`/`test` blocks asserting on the returned map verbatim:

```elixir
defmodule Pidro.Finnish.ScorerTest do
  use ExUnit.Case, async: true

  alias Pidro.Finnish.Scorer
  alias Pidro.Core.Types

  doctest Pidro.Finnish.Scorer

  describe "score_trick/2" do
    test "scores a simple trick without 2 of trump" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {14, :hearts}},  # Ace: 1 point
          {:east, {11, :hearts}},   # Jack: 1 point
          {:south, {10, :hearts}},  # Ten: 1 point
          {:west, {7, :hearts}}     # Seven: 0 points
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :north
      assert result.winner_points == 3
      assert result.two_of_trump_player == nil
      assert result.two_of_trump_points == 0
    end
  end
end
```
A PID-45 pure module would follow this exact pattern: a module with a typed pure function, doctest
examples in `@doc`, and an `async: true` unit test mirroring the lib path. The ticket's acceptance
(win / blowout-vs-close) maps directly onto `describe "update.../..."` + `test` blocks asserting on
the returned `{mu, sigma}` tuples.

### `apps/pidro_server/` — lib layout + where a server-side pure helper sits
- **Layout** (`apps/pidro_server/lib/`):
  - `pidro_server/` — contexts: `accounts/` (`auth.ex`, `user.ex`, `token.ex`), `stats/`
    (`stats.ex`, `game_stats.ex`, `abandonment_event.ex`), **`profiles/`** (`profiles.ex`,
    `player_profile.ex`), `games/` (room/bots/OTP), `emails/`, `dev/`.
  - `pidro_server_web/` — Phoenix web layer (controllers, channels, live, components, plugs,
    serializers, schemas).
- **Idiomatic placement for a non-engine pure helper:** as (or under) a context in
  `apps/pidro_server/lib/pidro_server/`. The rating consumer is server-side because it reads/writes
  `PlayerProfile` rows and is invoked from the `Stats`/`Profiles` completion path. A pure rating
  module would idiomatically live alongside `Profiles` (e.g. a `PidroServer.Profiles.Rating` pure
  module, or a `pidro_server/ratings/` context), with the **`Profiles` context orchestrating** (load
  ratings → call pure update → persist), matching `apps/pidro_server/CLAUDE.md`'s "pure functions
  over GenServer logic / thin orchestration" rule and PID-44's existing `Profiles.apply_completed_game/2`.
  (The engine `Pidro.*` namespace is reserved for game rules; rating is a server/persistence
  concern, so server placement keeps the engine free of a DB/profile dependency.)
- **`mix.exs` deps** (`apps/pidro_server/mix.exs:94-131`): `{:pidro_engine, in_umbrella: true}`,
  Phoenix/Ecto/Postgrex/Bandit stack, `jason`, `req`, `swoosh`, `open_api_spex`, etc.; dev/test
  `credo`, `dialyxir`, `excoveralls`, `ex_doc`. **A new `{:openskill, "~> 1.0"}` would be added
  here** (server consumes it).
- **Server tests:** under `apps/pidro_server/test/` mirroring lib paths, `use PidroServer.DataCase`
  for DB-touching tests, `Ecto.UUID.generate()` for ids. A *pure* rating module needs no DataCase —
  a plain `use ExUnit.Case, async: true` test (engine style) suffices; only the orchestration in
  `Profiles` would need DataCase.

### Umbrella shared deps
Both apps point at the umbrella-shared `_build`, `config/config.exs`, `deps`, and **single
`mix.lock`** (`build_path: "../../_build"`, `config_path: "../../config/config.exs"`,
`deps_path: "../../deps"`, `lockfile: "../../mix.lock"` in each app `mix.exs`). The root `mix.exs`
(`apps_path: "apps"`, `deps: []`) declares no deps itself. A dep is declared in the consuming app's
`mix.exs`; `mix deps.get` resolves it into the shared `deps/` and pins it in the single root
`mix.lock`. So `openskill` goes in `apps/pidro_server/mix.exs` and is locked once for the umbrella.

## Profile rating columns (from PID-44)

`apps/pidro_server/lib/pidro_server/profiles/player_profile.ex` (schema `player_profiles`,
binary_id PK, `@foreign_key_type :binary_id`) already defines the rating columns with the exact
OpenSkill defaults — lines 30-33:

```elixir
# --- Rating (PID-45/47 compute; PID-44 defaults only) ---
field :rating_mu, :float, default: 25.0
field :rating_sigma, :float, default: 8.333
field :rating_games_count, :integer, default: 0
```
- `rating_mu` :float default **25.0** — matches `Openskill.rating/0` mu (25).
- `rating_sigma` :float default **8.333** — matches `Openskill.rating/0` sigma (8.333333…, stored
  rounded to 8.333).
- `rating_games_count` :integer default **0** — count of rated games applied so far.
- All three are in the schema's `@castable` list (player_profile.ex:51-66), so a changeset can write
  them. The `@moduledoc` explicitly states "progression columns ship with defaults and are written
  by PID-45..PID-51" and "PID-45/47 compute" the rating.
- The completion hook already exists: `PidroServer.Profiles.apply_completed_game/2`
  (`profiles.ex:100-115`) is called once per newly-inserted `game_stats` row from inside the `Stats`
  write transaction (`stats.ex:326`: `Profiles.apply_completed_game(player_results, winner)`). Today
  it only increments `games_played`/`wins`/`losses`; this is the natural seam where a rating update
  (compute new `{mu, sigma}` per user, bump `rating_games_count`) would be added in PID-45.

## Game-completion data shape (what feeds "two partnerships + outcome")

The rating call needs: who is on each partnership + which partnership won. At completion this is
fully derivable, but **note it is keyed by team, not by an explicit per-team player list** — the
caller must group the four players by team.

From `apps/pidro_server/lib/pidro_server/stats/stats.ex` (and PID-44 doc
`docs/ratings-player-profiles/research/PID-44-player-profile-store.md`):

- **`winner`** — a team atom, one of `:north_south | :east_west` (passed into
  `save_completed_game/4`, `build_player_results/3`, `apply_completed_game/2`). On the persisted
  `game_stats` row it round-trips as the string `"north_south"`/`"east_west"`.
- **`final_scores`** — `%{north_south: integer, east_west: integer}` cumulative team scores (atom
  keys in memory; string keys after JSONB).
- **`player_results`** — the per-user map built by `build_player_results/3` (`stats.ex:238-256`).
  Each value (`build_result/3`, `stats.ex:406-416`) is:
  ```elixir
  %{
    participation: :played | :abandoned | :substitute,
    result: :win | :loss,        # team == winner ?
    team: :north_south | :east_west,
    position: :north | :east | :south | :west
  }
  ```
  Keyed by `user_id` (UUID string). **Bots are absent** (pure-bot seats `:skip`ped; an abandoned
  human is recorded under their own id via the seat's `reserved_for`).
- **Which players are on which partnership:** derived from `position` via `team_for_position/1`
  (`stats.ex:453-454`): `north`/`south` → `:north_south`; `east`/`west` → `:east_west`. So the two
  partnerships are the two groups of `player_results` entries sharing a `team`. (The two seats of a
  partnership are partners; seat order within a team is not separately significant for rating.)
- **Which partnership won:** `winner` directly, and equivalently each user's `result` (`:win` for
  the winning team's two players, `:loss` for the other two).

So to build the `Openskill.rate/1` input at the `apply_completed_game/2` seam: load each
participating user's `{rating_mu, rating_sigma}` from their `PlayerProfile`, group the (up to four)
users into two lists by `team`, order the list so the **winning team is first**, call
`Openskill.rate([winners, losers])` (or `rate_with_ids/2` to keep user ids), then write the updated
`{mu, sigma}` back per user and bump `rating_games_count`. Edge cases visible in the data:
partnerships may have fewer than 2 *recorded* users (a pure-bot partner is absent from
`player_results`), and abandoned/substitute participants are still recorded — PID-45 must decide how
to feed teams with missing/bot players to `rate/1` (it expects players on both teams).

## Open Questions

1. **Elixir 1.19 / OTP 28 build:** `openskill` declares `elixir ~> 1.14` and last released 2020;
   not compile-verified here against this umbrella. Do `openskill` + its old deps `math ~> 0.7.0` /
   `statistics ~> 0.6.3` resolve and compile under Elixir 1.19 / OTP 28 (and against the existing
   `mix.lock`)? This is the single biggest go/no-go for using the package vs. the in-house module.
2. **Engine vs server placement of the math:** the ticket says "keep the math in a PURE module so
   the engine stays clean … the server orchestrates." Does "engine" mean `apps/pidro_engine`
   (`Pidro.*`, would force adding `openskill` + a profile-agnostic rating type there) or simply "a
   pure module (server-side, in `pidro_server`)"? The rating consumer (`Profiles`) and DB are
   server-side, which argues for a `PidroServer`-namespaced pure module.
3. **Missing/bot players in a partnership:** `player_results` omits pure bots, so a partnership may
   have 0–2 recorded users. `Openskill.rate/1` expects both teams populated. How should PID-45 form
   the two team lists when a seat was a bot (skip rating that game? treat bot as a default-rating
   placeholder? only rate all-human games)?
4. **Which participations count toward rating:** should `:abandoned` / `:substitute` participants be
   rated the same as `:played`, or excluded/penalized? (Affects how `player_results` is filtered
   before building teams.)
5. **Guests:** guest users have `users` rows and appear in `player_ids`/`player_results`; do they
   get rated like registered users (inherited PID-44 open question)?
6. **Default model choice:** `Openskill.rate/1` uses the library's built-in model; if a specific
   Weng-Lin variant (Plackett-Luce vs Thurstone-Mosteller) or non-default `beta`/`tau` is wanted,
   confirm whether the package exposes options (README mentions a TODO for configurable `gamma`).
   Ticket says "defaults fine," so likely a non-issue.
7. **Concurrency / ordering:** ratings are path-dependent (order of games matters). The completion
   hook runs inside the `Stats` transaction per game; confirm no concurrent rating writes to the same
   profile race (PID-44 uses `Repo.update_all(inc: ...)` for counters, which won't compose with a
   read-modify-write `{mu, sigma}` update).
