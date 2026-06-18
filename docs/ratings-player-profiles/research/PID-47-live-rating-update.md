---
date: 2026-06-07
ticket: PID-47
topic: "Update ratings on completed games + bot-seat policy (codebase as-is)"
status: complete
---
# Research: PID-47 Live rating update on game completion

## Summary

The live game-completion path and the rerating job already meet at one pure seam,
`PidroServer.Profiles.rate_game/3` (PID-46). What is NOT yet wired: the live
completion path (`Stats.save_completed_game/4`) still only calls
`Profiles.apply_completed_game/2`, which updates the **three lifetime counters**
(`games_played`, `wins`, `losses`) and does **nothing** to
`rating_mu`/`rating_sigma`/`rating_games_count`. Ratings today move only when the
rerating job (`rerate_all/0` / `rerate_incremental/0`) runs.

PID-47's job is to hook a rating update into the SAME transaction, using
`rate_game/3` so the live update is byte-identical to the rerating replay. Concretely:

- **Insertion point:** the `nil ->` branch of `save_completed_game/4`, inside the
  existing `Repo.transaction`, on the `{:ok, stats}` arm — right beside the existing
  `:ok = Profiles.apply_completed_game(player_results, winner)` call
  (`apps/pidro_server/lib/pidro_server/stats/stats.ex:326`). `player_results` and
  `winner` are both in scope there.
- **Live priors:** read each participant's stored `{rating_mu, rating_sigma}` from
  their `PlayerProfile` row. The existing private `Profiles.load_priors/1`
  (`profiles.ex:398`) does exactly this for the incremental job — it selects
  `{user_id, rating_mu, rating_sigma}` for a list of user ids into a
  `%{user_id => {mu, sigma}}` map, missing users falling back to `Rating.default/0`
  inside `rate_game/3`. PID-47 wants the same read (currently private).
- **`rated_game?/1`:** **currently PRIVATE** in `Profiles` (`profiles.ex:314`). It is
  the single shared "is this a rated game" predicate, called from inside `rate_game/3`
  and `participant_ids/1`. The live path uses it indirectly (by calling `rate_game/3`),
  so the live "rated game" decision is already identical to the rebuild's WITHOUT
  exposing it. It only needs to become public/shared if PID-47 wants to branch the
  count bump / cursor handling outside `rate_game/3`.
- **Live == rebuild test:** assert that running the REAL completion path over a fixed
  sequence of games yields the same `snapshot()` of
  `{rating_mu, rating_sigma, rating_games_count}` per profile as a fresh
  `Profiles.rerate_all()` over the same `game_stats` rows. This is the same assertion
  the PID-46 parity test makes today, except PID-46 simulates "live" with an in-memory
  `live_fold/1`; PID-47 replaces that simulation with the actual completion write.

## Completion transaction (`save_completed_game/4`)

`apps/pidro_server/lib/pidro_server/stats/stats.ex:295-344`. Called once per finished
room from `RoomManager.handle_info({:game_over, ...})`
(`apps/pidro_server/lib/pidro_server/games/room_manager.ex:1774`):

```elixir
:ok = Stats.save_completed_game(finished_room, winner, scores, game_state)
```

The function body:

```elixir
@spec save_completed_game(map(), atom(), map(), map() | nil) :: :ok
def save_completed_game(%{code: room_code} = room, winner, scores, game_state \\ nil) do
  case Repo.get_by(GameStats, room_code: room_code) do
    %GameStats{} ->
      :ok                                                    # idempotency: already saved → no-op

    nil ->
      bid_info = extract_bid_info(game_state)
      duration_seconds = max(1, DateTime.diff(DateTime.utc_now(), room.created_at, :second))
      abandonment_events = list_abandonments_for_room(room_code)
      player_results = build_player_results(room.seats, winner, abandonment_events)

      stats_attrs = %{
        room_code: room_code,
        winner: winner,
        final_scores: scores,
        bid_amount: bid_info.bid_amount,
        bid_team: bid_info.bid_team,
        duration_seconds: duration_seconds,
        completed_at: DateTime.utc_now(),
        player_ids: Map.keys(player_results),
        player_results: player_results
      }

      result =
        Repo.transaction(fn ->
          case save_game_result(stats_attrs) do
            {:ok, stats} ->
              :ok = Profiles.apply_completed_game(player_results, winner)   # <-- PID-47 insertion point (line 326)
              stats

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, _stats} ->
          Logger.info("Saved game stats for room #{room_code}")
          :ok

        {:error, changeset} ->
          Logger.error("Failed to save game stats for room #{room_code}: #{inspect(changeset)}")
          :ok
      end
  end
end
```

Key facts:

- **Idempotency per `room_code`:** the leading `Repo.get_by(GameStats, room_code: ...)`
  short-circuits with `:ok` if a row already exists. A re-fired `:game_over` (proven by
  `profile_rollup_test.exs` "re-running completion does not double-increment") never
  re-enters the transaction, so a PID-47 rating update placed inside it is also
  applied exactly once per room. `room_code` is the de-facto idempotency key (there is
  no DB unique constraint shown here, but `GameStats.changeset` may add one — out of
  scope).
- **In scope at the insertion point (line 326):** `player_results` (the atom-keyed
  in-memory map from `build_player_results/3`), `winner` (atom, e.g. `:north_south`),
  `stats` (the just-inserted `%GameStats{}` with `id`, `completed_at`, `inserted_at`),
  `room`, `scores`, `bid_info`, `abandonment_events`, `room_code`.
- **Atomicity:** the rating write must go on the `{:ok, stats}` arm so a stats-insert
  failure (`{:error, changeset}` → `Repo.rollback`) rolls back rating changes too.
  `profile_rollup_test.exs:83` ("forced stats-insert failure leaves no profile
  changes") already proves the counter writes roll back; a PID-47 rating write in the
  same transaction inherits this.

## Profiles seam as-is

### `apply_completed_game/2` — what it updates TODAY (counters only)

`profiles.ex:105-120`. Updates the three lifetime counters, NOT ratings:

```elixir
@spec apply_completed_game(map(), atom() | String.t()) :: :ok
def apply_completed_game(player_results, _winner) when is_map(player_results) do
  Enum.each(player_results, fn {user_id, result} ->
    case Ecto.UUID.cast(user_id) do
      {:ok, valid_id} ->
        apply_one(valid_id, win_from_result?(result))
      :error ->
        Logger.warning("Profiles.apply_completed_game skipping non-UUID id #{inspect(user_id)}")
    end
  end)
  :ok
end
```

`apply_one/2` (`profiles.ex:469`) lazily creates the profile (`get_or_create_profile/1`)
then `Repo.update_all(inc: [games_played: 1, wins: 1])` or `[..., losses: 1]`. It
**ignores `_winner`** and increments per-player regardless of whether the game is a
"rated" 4-human 2v2 — every UUID in `player_results` gets a counter bump (including
`:abandoned` reserved-for ids; bots never appear because `build_player_results/3`
skips pure bots). This is INTENTIONALLY different from rating policy: counters count
all human participation, ratings only move on rated games.

### `rate_game/3` — the parity seam (public)

`profiles.ex:170-218`. Pure, no DB, shared by both paths:

```elixir
@spec rate_game(map(), atom() | String.t(), %{optional(String.t()) => rating()}) ::
        {:rated, %{optional(String.t()) => rating()}} | :unrated
def rate_game(player_results, winner, prior_ratings) do
  case rated_game?(player_results) do
    {:ok, {{team_a, members_a}, {_team_b, members_b}}} ->
      winner_str = normalize_team(winner)

      # Orient teams by the stored winner so the winning roster goes first.
      {winners_ids, losers_ids} =
        if team_a == winner_str do
          {members_a, members_b}
        else
          {members_b, members_a}
        end

      winner_priors = Enum.map(winners_ids, &prior_for(prior_ratings, &1))
      loser_priors = Enum.map(losers_ids, &prior_for(prior_ratings, &1))

      %{winners: new_winners, losers: new_losers} =
        Rating.rate(winner_priors, loser_priors)

      updated =
        prior_ratings
        |> zip_ratings(winners_ids, new_winners)
        |> zip_ratings(losers_ids, new_losers)

      {:rated, updated}

    :error ->
      :unrated
  end
end
```

- Returns `{:rated, updated_map}` (priors with the four participants replaced by new
  `{mu, sigma}`) or `:unrated`.
- Tolerates atom- or string-keyed results and atom/string `winner` (`normalize_team/1`,
  `profiles.ex:344`).
- Missing prior → `Rating.default/0` via `prior_for/2` (`profiles.ex:347`).
- Keys in the returned map keep their `player_results` key form (string after a JSONB
  round-trip; atom in the live in-memory path). PID-47 must persist by casting keys
  back to UUID — same as `persist_ratings/3` does.

### `rated_game?/1` — the shared predicate (PRIVATE, left private by PID-46)

`profiles.ex:314-338`:

```elixir
defp rated_game?(player_results) when is_map(player_results) do
  valid =
    Enum.flat_map(player_results, fn {user_id, result} ->
      case Ecto.UUID.cast(user_id) do
        {:ok, _} -> [{user_id, team_of(result)}]
        :error -> []
      end
    end)

  ids = Enum.map(valid, fn {id, _team} -> id end)

  with true <- length(valid) == 4,
       true <- length(Enum.uniq(ids)) == 4,
       [{team_a, members_a}, {team_b, members_b}] <-
         valid
         |> Enum.group_by(fn {_id, team} -> team end, fn {id, _team} -> id end)
         |> Enum.to_list(),
       true <- length(members_a) == 2 and length(members_b) == 2 do
    {:ok, {{team_a, members_a}, {team_b, members_b}}}
  else
    _ -> :error
  end
end

defp rated_game?(_player_results), do: :error
```

Predicate: a game is **rated iff `player_results` has exactly 4 distinct valid-UUID
keys, split 2-per-team**. This is what makes single-player (bots-only) and
mid-game-disconnect (bot-filled) games unrated:

- A **pure bot** seat is never in `player_results` (skipped by `classify_seat/1` →
  `:skip` in `stats.ex:404`). A bot-filled disconnect leaves only 3 valid UUID keys →
  `:error` → `:unrated`. This is exactly the v1 "rate only games that started 4-human"
  behavior, achieved by key-count, not by a separate flag.
- A non-UUID seat id (e.g. `"dev_host"`, a guest) is dropped by `Ecto.UUID.cast`, again
  dropping below 4 → unrated (proven by `rerate_test.exs:174`).

The PID-46 doc comment (`profiles.ex:308-313`) explicitly flags that **PID-47 owns the
final policy** and may tighten this — e.g. exclude games with any `:abandoned` /
`:substitute` seat, or guest seats — and that it is a shared predicate both paths MUST
use the same one. It is currently private; PID-47 may need to make it (or a thin
wrapper) public if the live path wants to branch outside `rate_game/3` (e.g. to decide
whether to bump `rating_games_count`). Note: today the live path does NOT need it
exposed, because calling `rate_game/3` and matching on `:rated`/`:unrated` already
yields the identical decision.

### `rerate_all/0` and `rerate_incremental/0` — how they read/write rating columns

- **`rerate_all/0`** (`profiles.ex:229-259`): in ONE transaction — (1) `Repo.update_all`
  resets every profile to `Rating.default/0` + `rating_games_count: 0`; (2) replays
  `ordered_games_query()` (`order_by: [asc: completed_at, asc: inserted_at, asc: id]`)
  from an EMPTY accumulator via `replay_game/3` → `rate_game/3`; (3)
  `persist_ratings(acc, counts, :overwrite_count)` writes `rating_mu`/`rating_sigma`
  and OVERWRITES `rating_games_count`; (4) `set_cursor(last_game)`.
- **`rerate_incremental/0`** (`profiles.ex:277-303`): loads the composite cursor, queries
  `games_after_cursor_query(cursor)`, **seeds the accumulator from CURRENT stored
  ratings** via `load_priors(batch_user_ids)` (`profiles.ex:398`), replays, then
  `persist_ratings(acc, counts, :increment_count)` — overwrites μ/σ, INCREMENTS
  `rating_games_count`.
- **`persist_ratings/3`** (`profiles.ex:409-427`): per touched user, `get_or_create_profile`
  (lazy create) then `Repo.update_all` with `set: [rating_mu, rating_sigma, ...]`, and
  for `:increment_count` adds `inc: [rating_games_count: count]`.
- **`replay_game/3`** (`profiles.ex:375-388`): the shared step — `rate_game/3` on the
  accumulator; on `{:rated, updated}` it bumps each `participant_ids/1` count by 1 and
  returns the updated acc; on `:unrated` leaves acc/counts untouched.

The **incremental path is the live-equivalent**: its seed-from-stored-ratings +
overwrite-μ/σ + increment-count is exactly what a per-game live update should do
(priors = current stored ratings; count += 1). PID-47's per-game write is one
`replay_game/3`-shaped step against priors loaded for just that game's four players.

## Reading live priors

Inside the completion transaction, read each human player's current `{mu, sigma}` from
their profile row. The mechanism already exists:

- **`Profiles.load_priors/1`** (`profiles.ex:398-405`) — PRIVATE today:

  ```elixir
  defp load_priors(user_ids) do
    from(p in PlayerProfile,
      where: p.user_id in ^user_ids,
      select: {p.user_id, p.rating_mu, p.rating_sigma}
    )
    |> Repo.all()
    |> Map.new(fn {user_id, mu, sigma} -> {user_id, {mu, sigma}} end)
  end
  ```

  Returns `%{user_id => {mu, sigma}}` for users with existing rows; users WITHOUT a row
  are simply absent and default to `Rating.default/0` inside `rate_game/3`. PID-47 can
  reuse this (making it public or calling an analog) to build the `prior_ratings`
  argument for `rate_game/3`.
- **Lazy creation:** `load_priors/1` does NOT create rows. Creation happens at
  PERSIST time via `get_or_create_profile/1` (`profiles.ex:38`), called inside
  `persist_ratings/3` and `apply_one/2`. `get_or_create_profile/1` is race-safe
  (`Repo.insert(on_conflict: :nothing, conflict_target: :user_id)` + re-fetch). So the
  live path reads priors (absent = default), rates, then writes (creating rows as
  needed) — identical to the rebuild accumulator after the same prior games.
- **Why this matches the rebuild:** the rerating accumulator holds, at any point, each
  user's rating after all prior games. The stored profile rows ARE that accumulator
  persisted. So reading stored `{mu, sigma}` for the four players gives the SAME priors
  the rebuild would have at that game's turn, provided no game was missed — the same
  monotonic-arrival contract `rerate_incremental/0` documents (`profiles.ex:270-275`),
  with `rerate_all/0` as the authoritative repair.

## Seat classification recap (how bots / abandoned / guests appear in `player_results`)

Built by `Stats.build_player_results/3` (`stats.ex:239-257`) via `classify_seat/1`
(`stats.ex:383-404`). For each of the four seats:

| Seat | `classify_seat/1` result | In `player_results`? | Rated key? |
|------|--------------------------|----------------------|-----------|
| Connected human | `{:record, user_id, :played}` | yes | yes (valid UUID) |
| Connected human substitute | `{:record, user_id, :substitute}` | yes | yes (valid UUID) |
| Bot with `reserved_for` (abandoned human) | `{:record, reserved_for, :abandoned}` | yes (under the abandoned human's id) | yes (valid UUID) |
| Pure bot (no `reserved_for`) | `:skip` | **no** | n/a |

Each recorded entry is `build_result/3` → `%{participation, result, team, position}`
(`stats.ex:406-416`), where `team = team_for_position(position)` (north/south →
`:north_south`, east/west → `:east_west`) and `result = :win | :loss` vs `winner`.
`merge_abandonment_events/3` (`stats.ex:418`) also folds in any `AbandonmentEvent` rows
for the room under `Map.put_new` (won't overwrite a live seat).

Consequences for the rated decision (which the live path inherits by calling
`rate_game/3` → `rated_game?/1`):

- **Single-player / bots-only:** ≤1 human → far fewer than 4 valid-UUID keys → `:unrated`.
- **Mid-game disconnect bot-fill:** the disconnected seat becomes a pure bot
  (`reserved_for` cleared on permanent fill, or it surfaces as `:abandoned` if still
  reserved). If it ends as a pure bot → only 3 UUID keys → `:unrated`, matching v1
  "rate only games that started 4-human." If `:abandoned` keeps the original UUID, the
  game still has 4 UUID keys and is currently rated — **PID-47's policy call** per the
  `rated_game?/1` comment is whether to exclude games with any `:abandoned`/`:substitute`
  seat. Whatever PID-47 decides, it lives in the ONE `rated_game?/1` so both paths agree.
- **Guest / non-UUID host id** (e.g. `"dev_host"`): dropped by `Ecto.UUID.cast`, lowering
  the valid-key count → typically `:unrated`.

## Existing parity + rollup tests

### PID-46 parity test — `apps/pidro_server/test/pidro_server/profiles/rerate_test.exs`

The headline parity test (`rerate_test.exs:211-237`, "from-scratch replay equals
sequential live application (acceptance c)"):

```elixir
test "from-scratch replay equals sequential live application (acceptance c)" do
  [a, b, c, d, e, f] = for _ <- 1..6, do: uuid()
  base = ~U[2026-06-07 12:00:00Z]

  games = [
    {complete_game("R1", {a, b, c, d}, :north_south, at(base, 0)), :north_south},
    {complete_game("R2", {a, c, e, b}, :east_west, at(base, 1)), :east_west},
    {complete_game("R3", {e, f, a, d}, :north_south, at(base, 2)), :north_south},
    {complete_game("R4", {b, d, f, c}, :east_west, at(base, 3)), :east_west},
    {complete_game("R5", {a, b, e, f}, :north_south, at(base, 4)), :north_south},
    {complete_game("R6", {c, d, a, e}, :east_west, at(base, 5)), :east_west}
  ]

  {live_acc, live_counts} = live_fold(games)

  live =
    Map.new(live_acc, fn {id, {mu, sigma}} ->
      {id, {mu, sigma, Map.fetch!(live_counts, id)}}
    end)

  assert {:ok, %{profiles: profiles, games: rated}} = Profiles.rerate_all()
  assert profiles == 6
  assert rated == 6

  assert_profiles_match(live, snapshot())
end
```

How it simulates "live" TODAY — `live_fold/1` (`rerate_test.exs:76-88`): an in-memory
read-modify-write fold over the games in completion order, calling
`Profiles.rate_game(results, winner, acc)` against an accumulator seeded lazily at
default, bumping per-user counts on `{:rated, ...}`. It does NOT exercise the real
completion write — `complete_game/4` only seeds `game_stats` rows (via
`Stats.save_game_result/1`, `rerate_test.exs:36-49`) so `player_results` round-trips to
string-keyed JSONB; the rating math is simulated by `live_fold`, then compared against
`rerate_all()` + `snapshot()` (`rerate_test.exs:56-61`, reads
`{rating_mu, rating_sigma, rating_games_count}` per `PlayerProfile`).

**PID-47 test plan:** replace the `live_fold` simulation with the REAL completion path.
Drive games through `Stats.save_completed_game/4` (or the `RoomManager` `:game_over`
lifecycle, as `profile_rollup_test.exs` does), then assert `snapshot()` of the live-run
profiles equals `snapshot()` after a fresh `Profiles.rerate_all()` over the same
`game_stats` rows — reusing `assert_profiles_match/2` (compares μ/σ within `@delta =
1.0e-9` and exact `rating_games_count`). That asserts live == rebuild on the real path.

### PID-44 rollup integration tests — `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs`

`use PidroServer.DataCase, async: false`; `setup` starts `RoomManager` and
`Bots.BotSupervisor`, calls `RoomManager.reset_for_test()`. The completion pattern:

```elixir
{:ok, room} = RoomManager.create_room(user1, %{name: "Rollup"})
{:ok, _, _} = RoomManager.join_room(room.code, user2)
{:ok, _, _} = RoomManager.join_room(room.code, user3)
{:ok, _, _} = RoomManager.join_room(room.code, user4)

game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
send(GenServer.whereis(RoomManager), game_over)

saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
assert saved_game.winner == "north_south"

for user_id <- saved_game.player_ids do
  assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
  assert profile.games_played == 1
end
```

Asserting profile state after a completed game = create + join four humans, `send`
`{:game_over, ...}` to `RoomManager`, `wait_until/2`-poll for the `GameStats` row, then
read each participant's `PlayerProfile`. Three tests:

- `:29` — completing a game inserts `game_stats` + bumps each participant's
  `games_played` to 1; profile count == number of human seats.
- `:56` — re-firing `:game_over` twice does not double-increment (idempotency;
  `Repo.aggregate(GameStats, :count) == 1`, each profile `games_played == 1`).
- `:83` — a forced `Repo.rollback` after `apply_completed_game/2` inside a transaction
  leaves zero profiles (atomicity).

This is the exact harness a PID-47 integration test can extend to additionally assert
`rating_mu`/`rating_sigma`/`rating_games_count` moved for the four humans (and that
bot/single-player games leave them untouched). Other lifecycle/completion tests:
`apps/pidro_server/test/pidro_server/games/room_cleanup_test.exs` and
`apps/pidro_server/test/pidro_server/stats/score_protection_test.exs` (both
exercise `:game_over` / completion but not ratings).

## Open Questions

1. **`:abandoned` / `:substitute` policy.** `rated_game?/1` currently rates ANY 4-UUID
   2v2, including games where a seat is `:abandoned` (bot reserved for the original
   human) or `:substitute`. The PID-46 comment hands PID-47 the decision to tighten this.
   v1 ticket text says "rates only games that started 4-human" — does an `:abandoned`
   seat (original human disconnected, bot played) count as having "started 4-human" and
   stay rated, or should the presence of any non-`:played` participation make the game
   unrated? Whatever the answer, it must live in the single `rated_game?/1`.
2. **Should `rated_game?/1` / `load_priors/1` become public?** The live path can stay
   fully behind `rate_game/3` (decision + math) and only needs a prior-loader. If
   PID-47 wants to branch (e.g. skip the rating write entirely on unrated games to
   avoid loading priors, or to bump `rating_games_count` separately), exposing
   `rated_game?/1` and `load_priors/1` (or thin public wrappers) is the minimal change.
3. **Per-game count semantics.** Live application is one game at a time, so it mirrors
   `rerate_incremental/0`'s `:increment_count` (priors = stored ratings, count += 1), NOT
   `rerate_all/0`'s `:overwrite_count`. Confirm PID-47 uses the increment semantics so a
   live update over the same prior games equals the incremental job (and, by the PID-46
   parity proof, equals `rerate_all/0`).
4. **Cursor interaction.** `rerate_incremental/0` advances `RatingState`'s composite
   cursor. Should the live per-game write ALSO advance the cursor (so a later incremental
   run doesn't re-apply the same game and double-count `rating_games_count`)? This is the
   key correctness coupling between the live path and the incremental job — the parity
   test should cover "live update then `rerate_incremental/0` applies 0 games" or the
   acceptance "identical to what the rerating job replays" can break on counts.
5. **Non-UUID / guest hosts in dev.** `"dev_host"`-style ids drop a game below 4 valid
   keys → unrated. In production all four are real UUIDs, so this only affects dev/test
   fixtures, but the PID-47 test should use real UUIDs (as `rerate_test.exs` does) to
   exercise the rated path.
