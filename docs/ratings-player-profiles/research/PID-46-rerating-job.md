---
date: 2026-06-07
ticket: PID-46
topic: "Rerating job — replayable ratings from game history (codebase as-is)"
status: complete
---
# Research: PID-46 Rerating job

## Summary

Everything PID-46 needs to (re)compute ratings from history already exists and is
proven by the lifetime-counter rebuild path. A completed game is one `game_stats`
row (`PidroServer.Stats.GameStats`); the two partnerships and the winner are fully
recoverable from that single row (`player_results` map keyed by user-id, each value
carrying `team`/`position`/`result`, plus the top-level `winner` string). The pure
rating estimator is `PidroServer.Rating` (`default/0`, `rate/2`, `ordinal/1`), and
the live per-game seam is `Profiles.apply_completed_game/2`, called once per newly
inserted row from inside `Stats.save_completed_game/4`'s `Repo.transaction`.

Key facts for the job:

- **Chronological ordering column:** `game_stats.completed_at` (`:utc_datetime`,
  indexed). It is **NOT total/stable** — second precision only, no tiebreaker, and
  multiple games can share a `completed_at`. For a deterministic total order, add a
  secondary key (`inserted_at`, also non-unique, or the unique `id`). `inserted_at`
  is plain `timestamps()` (naive, second-ish), `id` is a random UUIDv4 (NOT
  time-sortable). A stable order therefore needs `order_by: [asc: completed_at, asc:
  inserted_at, asc: id]` or similar — see "Game history data + ordering".
- **Two teams + winner per row:** group the (≤4) `player_results` entries by their
  `team` field (`north_south` / `east_west`); the winning team is the top-level
  `winner`. Each player's prior `{mu, sigma}` comes from the **running rebuild state**
  (an in-memory `%{user_id => {mu, sigma}}` accumulator the job maintains), not from
  the live `player_profiles` rows.
- **`rated_game?/1` knowable inputs:** per row you can see `player_ids` (recorded
  users only — bots are absent), and per-user `participation` (`:played` /
  `:abandoned` / `:substitute`) + `team` + `position` in `player_results`. Bots are
  structurally invisible (never recorded; an abandoned human is recorded under their
  own id with `participation: :abandoned`). Guests are real `users` rows and DO
  appear. So "started 4 distinct human seats, both teams populated" is derivable as
  "exactly 4 distinct UUID player_ids, two per team"; the bot-seat *policy* is PID-47's.
- **Shared per-game function for parity:** the seam is `Profiles.apply_completed_game/2`
  (profiles.ex:100). The rating update must be added there as a pure
  `player_results + winner + prior {mu,sigma} → new {mu,sigma}` step so the live path
  (PID-47) and this rebuild call the *same* function and produce identical results.
  The rebuild then feeds its running-state ratings into that same pure step per game.
- **No watermark / incremental infra exists** — greenfield. `rebuild_all/0` is a
  full wipe-and-recompute (overwrite). No `Repo.stream`, no last-processed marker
  anywhere in the codebase.

## Game history data + ordering

### The `game_stats` table

Schema `PidroServer.Stats.GameStats` (`apps/pidro_server/lib/pidro_server/stats/game_stats.ex:12-24`),
table `"game_stats"`, `binary_id` PK. Columns (and the migration
`apps/pidro_server/priv/repo/migrations/20251102100750_create_game_stats.exs`):

| column | type | notes |
|---|---|---|
| `id` | `:binary_id` (UUIDv4, random) | PK; **not time-sortable** |
| `room_code` | `:string` | unique-per-game in practice; idempotency key for the live write |
| `winner` | `:string` | `"north_south"` / `"east_west"` (atom→string normalized on write) |
| `final_scores` | `:map` | `%{north_south: int, east_west: int}`; string-keyed after JSONB read |
| `bid_amount` | `:integer` | winning bid 6..14, or nil |
| `bid_team` | `:string` | team that won the contract |
| `duration_seconds` | `:integer` | > 0 |
| `completed_at` | `:utc_datetime` | **second precision**, indexed — the chronological key |
| `player_ids` | `{:array, :binary_id}` | recorded user ids only (bots excluded); GIN-indexed |
| `player_results` | `:map` | per-user `%{participation, result, team, position}`; added by migration `20260308083652`; string-keyed after JSONB |
| `inserted_at` / `updated_at` | plain `timestamps()` | naive/second-precision, NOT `_usec` |

Indexes (migration): `index(:game_stats, [:completed_at])`, GIN
`index(:game_stats, [:player_ids])`, `index(:game_stats, [:room_code])`.

### Ordering — total/stable?

- The chronological column is **`completed_at`** (set to `DateTime.utc_now()` at the
  moment of the live write, stats.ex:317; for backfilled/seeded rows it is whatever
  the caller supplied). `inserted_at` would track *write* order, which equals
  completion order for the live path but may differ for migration-seeded rows where
  `completed_at` is historical — so `completed_at` is the correct domain key.
- It is **NOT total or stable on its own**: `:utc_datetime` truncates to seconds, has
  no microseconds, and there is no uniqueness constraint, so ties are possible (two
  games finishing in the same second). `id` is a random UUID, so it does NOT break
  ties chronologically. Ratings are path-dependent (order matters), so the job must
  pin a deterministic total order. Pragmatic choice:
  `order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]`. This is
  deterministic and repeatable (same input rows → same order) even though ties within
  a second are resolved arbitrarily-but-stably by `id`.

### Query all completed games in order (Ecto)

```elixir
import Ecto.Query
from(gs in PidroServer.Stats.GameStats,
  order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
)
|> PidroServer.Repo.all()
```

For the full deterministic recompute, this is the canonical iteration. `Repo.stream/1`
is **not used anywhere in the codebase today** (verified by grep) but is the natural
fit for large history and must run inside `Repo.transaction/1`.

### "Games since X" (incremental mode)

There is no stored watermark (see "Open Questions"). Filtering by a caller-supplied
cutoff:

```elixir
from(gs in GameStats,
  where: gs.completed_at > ^since_dt,
  order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id])
```

Caveat: because `completed_at` is non-unique at second precision, a strict `>` cutoff
on `completed_at` alone risks re-processing or skipping games that share the boundary
second. A safe incremental cursor needs the same composite key as the ordering (e.g.
remember the last processed `{completed_at, inserted_at, id}` tuple), not just a
timestamp.

## Team + winner recovery per row

From a single `game_stats` row, the two partnerships + winner are fully recoverable:

- **Team identifiers:** the two teams are the atoms `:north_south` and `:east_west`
  (strings on the persisted row). Position→team mapping is `team_for_position/1`
  (stats.ex:453-454): `:north`/`:south` → `:north_south`; `:east`/`:west` →
  `:east_west`. (This helper is private to `Stats`; the same mapping is also embedded
  in `player_results[*].team`, so the job can read `team` directly without re-deriving.)
- **Which `player_results` entries are on which team:** each value is
  `%{participation, result, team, position}` (built by `build_result/3`,
  stats.ex:406-416). Group the entries by `team` to get the two partnerships (each up
  to 2 recorded users). Note keys/values are **string-keyed** after a JSONB round-trip
  (`%{"team" => "north_south", "result" => "win", ...}`) but **atom-keyed** in the
  in-memory map built at completion — the job must tolerate both, exactly as
  `Profiles.win_from_result?/1` (profiles.ex:185-189), `Profiles.won_game?/2`
  (profiles.ex:195-215), and `Stats.get_player_result/2` (stats.ex:501-504) already do.
- **Winning team encoding:** the top-level `winner` field (`"north_south"` /
  `"east_west"`). Equivalently, each winning player's `result` is `:win`/`"win"`. For
  legacy rows with `player_results == nil`, the win is inferred from
  `winner` + position-by-`player_ids`-index (index 0=north, 1=east, 2=south, 3=west),
  the fallback in `won_game?/2` (profiles.ex:204-213) and `count_user_wins/2`
  (stats.ex:486-497).
- **Each player's `{mu, sigma}` "before" this game:** for a deterministic full
  recompute this comes from the **running rebuild accumulator**, NOT from
  `player_profiles`. The job seeds each newly-seen user to `PidroServer.Rating.default()`
  (`{25.0, 8.333…}`), then after each game replaces that user's entry with the updated
  tuple returned by the rating step, so the "before" for game N is the "after" of the
  user's game N−1. To match the live path exactly, the job must apply games in the
  same order the live path did (chronological). Persist the final accumulator into
  `player_profiles.rating_mu`/`rating_sigma` and set `rating_games_count` to the number
  of rated games applied per user.

To call the estimator: group the participating users into `winners`/`losers` lists of
`{mu, sigma}`, winning team first, and call
`PidroServer.Rating.rate(winners, losers)` → `%{winners: [...], losers: [...]}` in the
same order. (`PidroServer.Rating` wraps `Openskill.rate/1`; rating.ex:61-66.)

## Seat classification (what's knowable)

What a `game_stats` row tells you about who occupied each seat:

- **`player_ids`** — only **recorded users** appear (bots excluded). Built as
  `Map.keys(player_results)` (stats.ex:318), so it always matches `player_results`.
  Entries are `binary_id` user UUIDs — except historically a non-UUID id like
  `"dev_host"` can appear (filtered downstream by `Ecto.UUID.cast/1`, e.g.
  `apply_completed_game/2` profiles.ex:103-109). A `rated_game?` predicate must apply
  the same UUID filter.
- **`player_results[uid].participation`** — `:played` / `:abandoned` / `:substitute`
  (strings after JSONB). Set by `classify_seat/1` (stats.ex:383-404):
  - connected human, `substitute: true` → `:substitute`
  - connected human → `:played`
  - bot with `reserved_for` (an abandoned human's id) → recorded under that human's id
    as `:abandoned`
  - **pure bot (no `reserved_for`)** → `:skip` — **never recorded**, so genuinely
    invisible in the row.
- **`team` / `position`** — per recorded user, so you can tell how many distinct human
  ids sat on each side.

**Knowable for `rated_game?/1`:** "did this game start 4 distinct human seats?" is
derivable as **exactly 4 distinct valid-UUID entries in `player_results`, with two on
each team** (count by grouping on `team`). If a seat was a pure bot, that team will
have < 2 recorded users → the row reveals a bot was present (by absence). What is NOT
recorded: an explicit bot flag, or *how many* bot seats there were if a seat was both
bot AND had no `reserved_for`. Guests are full `users` rows and are indistinguishable
from registered users at this layer (they appear normally). The authoritative
bot-seat/guest POLICY (e.g. exclude games with any bot, or any abandonment) is PID-47's;
PID-46 only needs the predicate to consume whatever PID-47 defines.

Seat struct reference: `apps/pidro_server/lib/pidro_server/games/room/seat.ex`
(`occupant_type :: :human | :bot | :vacant`, `user_id`, `reserved_for`, `substitute`,
`status`) — this is the completion-time input to `build_player_results/3`, not stored.

## Existing rebuild path

`PidroServer.Profiles` (`apps/pidro_server/lib/pidro_server/profiles/profiles.ex`):

- **`rebuild_from_history/1`** (profiles.ex:124-144): for one user, loads all rows
  where `^user_id in gs.player_ids` (GIN-indexed array membership), counts
  `games_played = length(games)`, `wins = Enum.count(games, &won_game?(&1, user_id))`,
  `losses = games_played - wins`, then **overwrites** those three counters via a
  changeset `Repo.update`. It does NOT iterate chronologically — order is irrelevant
  for additive counters (but WILL matter for path-dependent ratings).
- **`rebuild_all/0`** (profiles.ex:152-163): selects all `player_ids`, flattens,
  `Enum.uniq`, and calls `rebuild_from_history/1` per user; returns
  `{:ok, count}`. Loads every user's full game list once per user (N+1-ish; fine for
  a batch repair, but a rating recompute that must order games globally will instead
  want a single chronologically-ordered pass — see below).
- **Idempotency:** achieved by *overwrite* — it recomputes from scratch and writes the
  absolute value, so running twice yields identical counters (proven by
  `profiles_test.exs:243-255`). No accumulation, no watermark.
- **What it recomputes today:** exactly the three lifetime counters
  (`games_played`, `wins`, `losses`). It does NOT touch `rating_*`, `veteran_*`,
  `playstyle_*`, or `heritage_flags`.
- **Win detection helpers:** `won_game?/2` (profiles.ex:195-215) reads the stored
  `result` (atom or string), falling back to `winner`+position inference for legacy
  nil-`player_results` rows; `win_from_result?/1` (profiles.ex:185-189) handles the
  four atom/string `result` shapes for the live path; `get_player_result/2`
  (profiles.ex:217-222) and `get_player_position/2` (profiles.ex:224-234) mirror the
  `Stats` equivalents.

**How rating recompute slots alongside it:** the current per-user, order-agnostic
iteration is *wrong* for ratings (order-dependent). The rating recompute wants a
**separate global iteration**: one chronologically-ordered pass over ALL `game_stats`
(the composite ordering above), maintaining an in-memory `%{user_id => {mu, sigma}}`
accumulator, applying each rated game via the shared per-game rating step, then a
single bulk write of final `{mu, sigma}` + `rating_games_count` per user. The existing
counter rebuild can remain a separate concern (or be folded into the same pass — the
counters are order-independent and could be tallied in the same loop). They are
logically independent: counters need set membership; ratings need ordered replay.

The existing mix task `Mix.Tasks.Pidro.RebuildProfiles`
(`apps/pidro_server/lib/mix/tasks/pidro.rebuild_profiles.ex`) just calls
`app.start` then `Profiles.rebuild_all()` and prints a count — the pattern a
`pidro.rerate` (or extended) task would follow.

## Live update path & parity seam

The live per-game update path:

1. Engine reaches terminal phase → PubSub `{:game_over, ...}` →
   `RoomManager.handle_info({:game_over, ...})` → `Stats.save_completed_game/4`
   (`apps/pidro_server/lib/pidro_server/stats/stats.ex:298-344`).
2. `save_completed_game/4` is **idempotent per `room_code`** (`Repo.get_by(GameStats,
   room_code:)` → `:ok` no-op if a row already exists, stats.ex:300-303).
3. On a new row, it builds `player_results` from seats, then runs a **single
   `Repo.transaction`** (stats.ex:323-332):
   ```elixir
   Repo.transaction(fn ->
     case save_game_result(stats_attrs) do
       {:ok, stats} ->
         :ok = Profiles.apply_completed_game(player_results, winner)
         stats
       {:error, changeset} -> Repo.rollback(changeset)
     end
   end)
   ```
   So the `game_stats` insert and the profile update commit atomically together.
4. `Profiles.apply_completed_game/2` (profiles.ex:100-115) iterates `player_results`,
   skips non-UUID ids, and calls `apply_one/2` which lazily creates the profile and
   does `Repo.update_all(inc: [...])` to bump `games_played` + `wins`/`losses`.

**Parity seam for the shared rating function:** today `apply_completed_game/2` only
touches counters. To guarantee the rerating job and live PID-47 produce identical
ratings, the rating update must be implemented as a **pure** function of
`(player_results, winner, prior_ratings) → updated_ratings` (delegating the math to
`PidroServer.Rating.rate/2`), and BOTH paths must call it:

- **Live (PID-47):** inside the same transaction, after the row insert, load the four
  users' current `{mu, sigma}` from `player_profiles`, call the shared pure step, write
  back. (Note the existing counter update uses `Repo.update_all(inc:)`, which is an
  in-DB increment; a `{mu, sigma}` write is a read-modify-write and cannot be expressed
  as `inc:` — concurrency/ordering of rating writes is an open item, see PID-45 doc.)
- **Rebuild (PID-46):** feed the running-state ratings (not the DB rows) into the SAME
  pure step, in chronological order, then bulk-persist.

Because the inputs (`player_results` shape, `winner`, the team-grouping rule, the
order-only estimator) are identical, a single shared pure function is the parity
guarantee. The acceptance "produces the SAME result as live per-game updates" reduces
to: (a) same per-game function, (b) same game ordering, (c) same starting defaults
(`PidroServer.Rating.default/0`), (d) same set of rated games (same `rated_game?`
predicate).

## Mix task + batch + test patterns

- **Mix task pattern** (`apps/pidro_server/lib/mix/tasks/pidro.rebuild_profiles.ex`):
  `defmodule Mix.Tasks.Pidro.<Name>`, `use Mix.Task`, `@shortdoc`, `@moduledoc` with a
  usage example, `@impl Mix.Task def run(_args)` that calls `Mix.Task.run("app.start")`
  first (to boot the Repo), invokes the context function, and prints via
  `Mix.shell().info/1`. A PID-46 task would mirror this (e.g. `pidro.rerate`), likely
  taking args for full-vs-incremental and a `--since` cutoff.
- **Batch / transaction:** the only `Repo.transaction` in this area is the live
  per-game one (stats.ex:323). There is **no `Repo.stream` usage anywhere** in the
  app — a streaming chronological pass for a large history would be new code and must
  be wrapped in `Repo.transaction(fn -> Repo.stream(query) |> Enum.reduce(...) end)`.
  Counters today use `Repo.update_all(inc: ...)` (profiles.ex:177-179); bulk rating
  writes would more likely be per-user `Repo.update` / a batched `update_all` per
  distinct value, since `inc:` cannot express a `{mu, sigma}` overwrite.
- **SQL sandbox / DataCase** (`apps/pidro_server/test/support/data_case.ex`, verbatim):

```elixir
defmodule PidroServer.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias PidroServer.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PidroServer.DataCase
    end
  end

  setup tags do
    PidroServer.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(PidroServer.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

- **Representative DB test** (`apps/pidro_server/test/pidro_server/profiles/profiles_test.exs`):
  `use PidroServer.DataCase, async: true`; ids via `Ecto.UUID.generate()`; a local
  `save_game/4` helper calls `Stats.save_game_result/1` to seed `game_stats` rows
  (which round-trips `player_results` to **string keys** — see test:227); asserts the
  rebuild reproduces the incremental counters exactly (profiles_test.exs:206-241),
  idempotency (twice → identical, :243-255), drift-overwrite (:257-271), and the
  nil-`player_results` legacy fallback (:273-288). This file is the direct template for
  the PID-46 parity test: run live `apply_completed_game/2` for a sequence of games,
  separately run the rerating job over the same seeded rows, assert identical
  `rating_mu`/`rating_sigma`/`rating_games_count`.

## Open Questions

1. **Watermark / incremental cursor:** none exists (greenfield). Where is "last
   processed" stored — a new column/table, a max(`completed_at`) probe, or a
   `rating_games_count`-based reconciliation? And because `completed_at` is non-unique
   at second precision, the cursor likely needs the full composite key
   `{completed_at, inserted_at, id}`, not just a timestamp.
2. **Deterministic tiebreak:** `completed_at` is second-precision and non-unique;
   `id` is random UUID (not time-sortable). The job must pick a fixed total order
   (proposed `[completed_at, inserted_at, id]`) and the LIVE path must have applied
   games in that same order for parity to hold — but live games are applied in real
   completion order, which equals `completed_at` order only up to same-second ties.
   Are same-second multi-game ties realistic, and does the parity check tolerate them?
3. **Counters in the same pass?** The order-agnostic counter rebuild
   (`rebuild_from_history/1`) and the order-dependent rating replay are logically
   separable; should PID-46 fold counters into the single chronological pass, or leave
   `rebuild_all/0` untouched and add a parallel rating pass?
4. **Rating write strategy / concurrency:** counters use `Repo.update_all(inc:)`; a
   `{mu, sigma}` overwrite is read-modify-write. For the bulk persist at the end of the
   rerating job this is fine, but the LIVE shared step needs a concurrency-safe write
   (inherited PID-45 open question) — does parity testing need to account for that?
5. **`rated_game?` policy source:** PID-46 needs the predicate but PID-47 owns the
   policy. What exactly counts (4 distinct human UUIDs? exclude any `:abandoned` /
   `:substitute`? exclude guests?) — and does the LIVE path filter identically so the
   rebuild's rated-game set matches?
6. **Default-seeding source:** the rebuild seeds new users to
   `PidroServer.Rating.default/0` `{25.0, 8.333…}`. The stored `player_profiles`
   defaults are `25.0` / `8.333` (rounded). Should the job seed from the schema default
   or from `Rating.default/0` (8.333333…)? They differ in the 4th decimal, which can
   diverge under replay vs a live row that was created with the rounded default.
