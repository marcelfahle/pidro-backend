---
date: 2026-06-07
ticket: PID-52
status: complete
---

# PID-52 — Post-game progression summary (research, as-is)

## Summary

Today, a finished game produces a **single room-wide** `game_over` broadcast carrying only
`%{winner, scores}`. There is **no per-player "what changed" signal** anywhere on the path.
The progression side-effects (XP/level, rating/tier, achievements, playstyle) are all applied
**server-side inside `Profiles.apply_completed_game/5`** during `Stats.save_completed_game/4`, but
that function currently returns only `{:ok, %{user_id => [newly_earned_achievement_key]}}` and the
caller **explicitly discards it** (`{:ok, _newly_earned} = ...`, `stats.ex:410`). No before-values
are captured anywhere — all writes are blind `Repo.update_all(inc:)` / `set:` with no read-before.

To build the summary we need to (a) capture before/after profile snapshots per participant inside
the loop, (b) thread the resulting per-user summary out of `apply_completed_game` and out of
`save_completed_game`, and (c) deliver it **per-player** (the current `game_over` push is identical
for every socket; it must become keyed by `user_id` or pushed individually per member socket).

---

## 1. Completion → broadcast → client path

### 1a. Engine `:complete` → `GameAdapter.broadcast_game_over`

`apps/pidro_server/lib/pidro_server/games/game_adapter.ex:331-358`

The adapter watches state transitions; when the new state's `:phase` is `:complete` (or legacy
`:game_over`) it calls `broadcast_game_over/2`:

```elixir
# game_adapter.ex:331
# The engine finishes at :complete; older callers may still use :game_over.
if Map.get(new_state, :phase) in [:complete, :game_over] do
  broadcast_game_over(room_code, new_state)
end
```

```elixir
# game_adapter.ex:347-358
@spec broadcast_game_over(String.t(), map()) :: :ok | {:error, term()}
defp broadcast_game_over(room_code, state) do
  winner = Map.get(state, :winner)
  scores = Map.get(state, :scores) || Map.get(state, :cumulative_scores)

  Phoenix.PubSub.broadcast(
    PidroServer.PubSub,
    "game:#{room_code}",
    {:game_over, room_code, winner, scores}
  )
end
```

**Topic:** `"game:#{room_code}"`. **Message:** `{:game_over, room_code, winner, scores}` — a single
room-wide PubSub message, identical for everyone. `winner` is an atom (e.g. `:north_south`);
`scores` is a map like `%{north_south: 62, east_west: 45}`.

### 1b. `RoomManager` `{:game_over}` handler → `Stats.save_completed_game/4`

`apps/pidro_server/lib/pidro_server/games/room_manager.ex:1755-1783`

```elixir
def handle_info({:game_over, room_code, winner, scores}, %State{} = state) do
  case Map.get(state.rooms, room_code) do
    nil -> {:noreply, state}
    %Room{} = room ->
      game_state =
        case GameAdapter.get_state(room_code) do
          {:ok, state} -> state
          {:error, _reason} -> nil
        end

      finished_room = room |> Map.put(:status, :finished) |> ... |> touch_last_activity()

      :ok = Stats.save_completed_game(finished_room, winner, scores, game_state)

      updated_state = %{state | rooms: Map.put(state.rooms, room_code, finished_room)}
      broadcast_room(room_code, finished_room)
      broadcast_lobby_event({:room_updated, finished_room})
      maybe_schedule_empty_room_close(finished_room, room_code)
      {:noreply, updated_state}
  end
end
```

Note: `save_completed_game/4` hard-asserts `:ok` here (`= Stats.save_completed_game(...)`). It does
**not** propagate a summary back into the PubSub layer — and by the time RoomManager runs this, the
client `game_over` push (1c) has *already* been emitted by the GameAdapter broadcast, independently.
The RoomManager handler is a **separate subscriber** to the same `{:game_over, ...}` message; it does
the persistence/profile write but does **not** push anything to clients.

`Stats.save_completed_game/4` (`apps/pidro_server/lib/pidro_server/stats/stats.ex:377-430`):

```elixir
def save_completed_game(%{code: room_code} = room, winner, scores, game_state \\ nil) do
  case Repo.get_by(GameStats, room_code: room_code) do
    %GameStats{} -> :ok                       # idempotent: already saved
    nil ->
      ...
      player_results = build_player_results(room.seats, winner, abandonment_events)
      player_bidding = build_player_bidding(events_of(game_state), room.seats)
      ...
      Repo.transaction(fn ->
        case save_game_result(stats_attrs) do
          {:ok, stats} ->
            # PID-50: apply_completed_game now returns the per-user
            # newly-earned achievement keys. PID-52 will wire this into the
            # post-game payload; for now we capture and discard it.
            {:ok, _newly_earned} =
              Profiles.apply_completed_game(player_results, winner, scores, player_bidding)
            stats
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
  end
end
```

The `# PID-52 will wire this in` comment at `stats.ex:407-409` marks the intended seam.

### 1c. Channel receives the broadcast → pushes to client

`apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex:438-449`

```elixir
def handle_info(
      {:game_over, room_code, winner, scores},
      %{assigns: %{room_code: room_code}} = socket
    ) do
  # Broadcast game over to all players
  push(socket, "game_over", %{winner: winner, scores: scores})

  # Schedule room closure after 5 minutes
  Process.send_after(self(), {:close_room, room_code}, :timer.minutes(5))

  {:noreply, socket}
end
```

**Client event name:** `"game_over"`. **Payload:** `%{winner: winner, scores: scores}` — and this is
the **complete** game-over payload the client receives today. There is no XP/level/tier/achievement
content in it. Compare the `state_update` push (`game_channel.ex:416-436`) which is the only place a
`GameStateSerializer.serialize/1` result is pushed (event `"game_state"`).

### 1d. Serializer

`apps/pidro_server/lib/pidro_server_web/serializers/game_state_serializer.ex:32-56` (`serialize/1`)
shapes the live **game state** (phase, players, scores, winner, etc.) for the `"game_state"` push. It
does **not** build a game-over/results payload — there is no progression-summary builder anywhere in
the serializer. `serialize/1` does include `winner:` and `scores:`/`cumulative_scores:` (lines 50-52),
but the `game_over` push (1c) bypasses the serializer entirely and sends the raw `winner`/`scores`.

So: **no results/summary builder exists yet.** A new builder (e.g. a `PostGameSummary` serializer)
would be the place to shape the per-player "what changed" map.

---

## 2. Per-player vs broadcast — injection point

**Today it is room-broadcast, NOT per-player.** One `{:game_over, room_code, winner, scores}` PubSub
message fans out to every subscribed `GameChannel` process, and each pushes the **identical**
`%{winner, scores}` to its socket. Nothing in the payload is keyed by `user_id`.

The summary is intrinsically **per-player** (each player needs THEIR xp/level/tier deltas). Two viable
injection points exist in the current architecture:

- **(A) Per-socket push.** The `GameChannel` already knows its own user — `socket.assigns` carries the
  authenticated user (the channel uses `legal_actions_for_socket/1` and presence per-user). The
  game-over handler could look up *this socket's* summary from a `%{user_id => summary}` map carried in
  the broadcast, and push only that user's slice. This is the cleanest: the broadcast stays one message,
  but it carries a `summaries: %{user_id => summary}` map, and each channel pushes `summaries[my_user_id]`.

- **(B) Keyed map in the broadcast.** Same idea, surfaced explicitly: change the PubSub message /
  client payload to include a `%{user_id => per_player_summary}` map and let the client pick its own
  slice. Less private (every client sees every player's deltas).

The blocker for both: the summary is computed in `Profiles.apply_completed_game` (called from
`Stats.save_completed_game` in the **RoomManager** process), but the `game_over` PubSub broadcast that
reaches the channels is emitted **earlier and independently** by the **GameAdapter** (1a). So the
summary is not available at the moment the current `game_over` message is broadcast.

**Cleanest seam:** thread the per-user summary out of `apply_completed_game` → out of
`save_completed_game` → and have the **RoomManager** `{:game_over}` handler (room_manager.ex:1774)
emit a *new* per-player-summary broadcast (e.g. `{:game_summary, room_code, %{user_id => summary}}`) on
`"game:#{room_code}"` after the profile write completes. The `GameChannel` would add a `handle_info`
for it and push only `summaries[socket.assigns.user_id]`. (The existing `"game_over"` push can stay as
the always-present fallback skeleton; the summary push layers on top.)

---

## 3. `apply_completed_game/5` loop + before/after capture

`apps/pidro_server/lib/pidro_server/profiles/profiles.ex:255-287`

```elixir
def apply_completed_game(player_results, winner, scores, player_bidding \\ %{}, opts \\ [])

def apply_completed_game(player_results, winner, scores, player_bidding, _opts)
    when is_map(player_results) do
  player_bidding = if is_map(player_bidding), do: player_bidding, else: %{}

  # 1. Lifetime counters (PID-44) + veteran XP (PID-49) + playstyle (PID-51):
  #    every valid-UUID participant, regardless of rated status.
  Enum.each(player_results, fn {user_id, result} ->
    case Ecto.UUID.cast(user_id) do
      {:ok, valid_id} ->
        apply_one(valid_id, win_from_result?(result))
        apply_xp(valid_id, result, scores)
        apply_playstyle(valid_id, bidding_facts_for(player_bidding, user_id))
      :error ->
        Logger.warning("... skipping non-UUID id #{inspect(user_id)}")
    end
  end)

  # 2. Ratings (PID-47): rated 4-human games only, priors from stored rows.
  apply_live_rating(player_results, winner)

  # 3. Achievements (PID-50): per valid-UUID participant ... idempotent-upsert.
  newly_earned = apply_live_achievements(player_results, scores)

  {:ok, newly_earned}
end

def apply_completed_game(_player_results, _winner, _scores, _player_bidding, _opts),
  do: {:ok, %{}}
```

### What state is read-before vs written-after today (per participant)

All three writers are **blind increments** — they read the profile only to recompute a derived cache
*after* the write, never to capture a before-snapshot:

- **`apply_one/2`** (`profiles.ex:899-913`): `get_or_create_profile`, then
  `Repo.update_all(inc: [games_played: 1, wins/losses: 1])`. No before-value captured.

- **`apply_xp/3`** (`profiles.ex:919-935`):
  ```elixir
  delta = Progression.xp_for_game(team_score, won?)
  ... Repo.update_all(inc: [veteran_xp: delta])
  new_xp = Repo.one(... select: p.veteran_xp)          # AFTER value only
  ... Repo.update_all(set: [veteran_level: Progression.level_for_xp(new_xp)])
  ```
  It computes `delta` (= **xp_earned this game**, recoverable) and the **after** xp/level, but never
  reads `veteran_xp`/`veteran_level` **before** the inc. `level_before` / `title_before` are lost.

- **`apply_playstyle/2`** (`profiles.ex:941-964`): blind `Repo.update_all(inc: [...])` of the four
  playstyle accumulators. No before/after captured.

- **`apply_live_rating/2`** (`profiles.ex:706-721`): reads priors via `load_priors(ids)` (the
  **before** μ/σ for the four rated participants — this IS captured locally), rates via `rate_game/3`,
  then on `{:rated, updated}` calls `persist_ratings(acc, counts, :increment_count)`. So
  `rating_mu/sigma_before` exist as `priors` here and `rating_mu/sigma_after` as `updated`, but
  `rating_games_count` before/after and the **tier** classification (before vs after) are not computed.

- **`apply_live_achievements/2`** (`profiles.ex:728-...`): returns the per-user newly-earned keys
  `%{user_id => [key]}` — this is the one delta already surfaced.

### What must be captured to build the "what changed" summary

For each participant, **before the writes**, snapshot the profile (`get_or_create_profile` already
runs first in each writer — a single read up front would serve all):

| Field | Before | After | Derived delta |
|---|---|---|---|
| veteran_xp | `profile.veteran_xp` (NOT captured today) | after inc (`apply_xp` reads it) | `xp_earned = Progression.xp_for_game(team_score, won?)` |
| veteran_level | `Progression.level_for_xp(xp_before)` (NOT captured) | `level_for_xp(xp_after)` | `leveled_up = after > before` |
| title | `Progression.title_for_level(level_before)` (NOT captured) | `title_for_level(level_after)` | title change |
| rating μ/σ | `priors` in `apply_live_rating` (captured locally) | `updated` (captured locally) | rated games only |
| rating_games_count | `profile.rating_games_count` (NOT surfaced) | before + 1 | provisional gate input |
| tier | `Tier.classify(μ_before, σ_before, count_before)` (NOT computed) | `Tier.classify(μ_after, σ_after, count_after)` | tier move + provisional change |
| achievements | — | — | `newly_earned[user_id]` (already returned) |

**None of the before-values are captured today.** The natural capture point is a single
`get_or_create_profile`/read at the top of the per-participant loop body, before the four writers run,
threading a `%{user_id => before_snapshot}` accumulator and combining with the after-reads + computed
deltas + `newly_earned` to produce `%{user_id => what_changed_summary}` as the new return value.

---

## 4. Building blocks (signatures) — to compose the summary

### `PidroServer.Progression` (`progression.ex`)
- `xp_for_game(team_score :: integer(), won? :: boolean(), opts \\ []) :: non_neg_integer()` — line 122
- `level_for_xp(xp :: non_neg_integer()) :: pos_integer()` — line 145
- `title_for_level(level :: pos_integer()) :: title()` — line 167
- `next_level_at(xp) :: non_neg_integer() | :max` (190), `level_progress(xp) :: {into, span} | :max` (213)

### `PidroServer.Rating.Tier` (`rating/tier.ex`)
- `classify(mu :: float(), sigma :: float(), games_count :: non_neg_integer()) :: %{tier:, provisional: boolean()}` — line 65
- `classify(%{rating_mu:, rating_sigma:, rating_games_count:}) :: result()` — line 94 (profile-shaped overload, ideal for before/after snapshots)
- `tier :: :provisional | :bronze | :silver | :gold | :platinum | :master`; gate: `provisional_min_games: 10`, `provisional_max_sigma: 6.0` (tier.ex:30-44)

### `PidroServer.Rating` (`rating.ex`)
- `default() :: rating()` (line 31) — `{25.0, 8.333}`
- `rate(winning_team :: [rating, ...], losing_team :: [rating, ...]) :: %{...}` — line 57
- `ordinal(rating()) :: float()` (line 77) — `mu - 3*sigma`, the band input
- `rating :: {mu :: float(), sigma :: float()}`

### Profiles rating step (`profiles.ex`)
- `rate_game(player_results, winner, prior_ratings) :: {:rated, updated} | :unrated` — line 477
- `apply_completed_game/5` returns `{:ok, %{user_id => [newly_earned_key]}}` — line 283 (the achievements delta)

### `PidroServer.Playstyle` (`playstyle.ex`)
- `bidding_win_rate(wins, attempts) :: rate() | :insufficient` — line 83
- `needle(rate()) :: float()` — line 91 (`:insufficient` → 0.5)
- `label(needle :: float()) :: :careful | :balanced | :aggressive` — line 124
- `avg_winning_bid(sum, count) :: float() | nil` — line 137

(The profile read API: `Profiles.get_or_create_profile(user_id) :: {:ok, PlayerProfile.t()}` — gives the
before/after column values directly: `veteran_xp`, `veteran_level`, `rating_mu`, `rating_sigma`,
`rating_games_count`, `playstyle_*` — see `player_profile.ex:24-43`.)

---

## 5. Rated-vs-casual flag at completion

There is **one shared predicate**: `rated_game?/1` (`profiles.ex:618-642`).

```elixir
defp rated_game?(player_results) when is_map(player_results) do
  # A game is rated iff player_results has exactly 4 distinct valid-UUID keys,
  # split 2 per team. Returns {:ok, {{team_a, [ids]}, {team_b, [ids]}}} or :error.
  ...
end
defp rated_game?(_player_results), do: :error
```

It is reached in the loop **via `rate_game/3`** (`profiles.ex:477-504` calls `rated_game?` and returns
`{:rated, updated}` or `:unrated`) and via `participant_ids/1` (696) and `apply_live_rating/2` (706).
So inside `apply_completed_game`, the rated/casual answer is available right now as:

- `participant_ids(%{player_results: player_results})` — non-empty list ⇒ rated, `[]` ⇒ casual; or
- match `rated_game?(player_results)` directly (used in achievements ctx at `profiles.ex:785`,
  `partnered_win?: won? and match?({:ok, _}, rated_game?(player_results))`).

For the summary: compute `rated? = match?({:ok, _}, rated_game?(player_results))` once. When `rated?`,
layer the **tier move** (and provisional change) into each rated participant's summary. When **casual**
(single-player / non-4-human), the summary must **lead with Veteran level / Mastery** and **omit** any
tier/skill number (rating columns are untouched on `:unrated` — `apply_live_rating` returns `:ok` with
no writes, `profiles.ex:718-720`). The XP/level beat (PID-49) is applied for **every** valid-UUID
participant regardless of rated status (loop step 1), so it is always the guaranteed fallback signal.

---

## 6. Game-over channel tests

**There is currently NO test asserting the client-pushed `"game_over"` payload.** The channel test
(`apps/pidro_server/test/pidro_server_web/channels/game_channel_test.exs`) has no `assert_push
"game_over"`. The representative push-assertion pattern there is for `"game_state"` (the only push that
serializes state), at lines 371-396:

```elixir
test "pushes transition delay metadata with serialized game state", %{...} do
  ...
  Phoenix.PubSub.broadcast(
    PidroServer.PubSub, "game:#{room_code}",
    {:state_update, room_code, %{state: state, transition_delay_ms: 40}}
  )

  assert_push "game_state",
              %{state: pushed_state, legal_actions: legal_actions, transition_delay_ms: 40},
              ...
  assert pushed_state == GameStateSerializer.serialize(state)
end
```

The game-over **behaviour** is covered only at the **integration / rollup** level, not at the channel
push level — `apps/pidro_server/test/pidro_server/stats/profile_rollup_test.exs:35-60` drives the full
completion path by sending the PubSub message straight to RoomManager and asserting the **DB** effects:

```elixir
game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
send(GenServer.whereis(RoomManager), game_over)

saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
assert saved_game.winner == "north_south"

for user_id <- saved_game.player_ids do
  assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
  assert profile.games_played == 1
end
```

It also asserts idempotency (double-send → one `GameStats`, `:82`), transaction rollback atomicity
(`:97-105`), and rating moves (`:118-125`, `rating_games_count == 1`, μ up for winners / down for
losers). This rollup test is the natural home to add `%{user_id => summary}` return-value assertions;
a new `assert_push "game_over"` / per-player-summary push test would belong in `game_channel_test.exs`.

---

## 7. Serialization conventions for the client

- **JSON encoding**: `Phoenix.json_library()` (Jason) via the endpoint (`endpoint.ex:53`). Channel
  pushes pass plain Elixir maps; Jason encodes them. **Atom map keys are emitted verbatim** as JSON
  string keys — so `%{winner: winner, scores: scores}` becomes `{"winner": ..., "scores": ...}`.
- **Casing is `snake_case`**, not camelCase. Every serializer field and channel push uses snake_case
  atom keys: `hand_number`, `current_turn`, `cumulative_scores`, `highest_bid`, `trick_number`,
  `transition_delay_ms`, `legal_actions`, etc. (`game_state_serializer.ex:34-55`,
  `game_channel.ex:425-429`). A PID-52 summary should follow suit (`xp_earned`, `veteran_level`,
  `leveled_up`, `tier_before`, `tier_after`, `provisional`, `newly_earned_achievements`).
- **Atoms as values**: `winner` is pushed as a raw atom (`:north_south`) and Jason encodes it as the
  string `"north_south"`. Tier atoms (`:gold`) and title atoms would likewise serialize to strings.
  (Note `build_player_results` stores `winner` as a string `"north_south"` in `GameStats`, but the
  **live push** sends the atom; both round-trip to the same JSON string.)
- **Maps keyed by position/user**: `scores`/`cumulative_scores` are maps keyed by team atoms
  (`%{north_south: 62}`) → JSON `{"north_south": 62}`. A per-player summary map keyed by `user_id`
  (UUID string) would serialize cleanly as a JSON object keyed by UUID strings.

---

## Open Questions

1. **Where does the summary push originate?** The current `game_over` PubSub broadcast is emitted by
   `GameAdapter` (1a) *before* `Stats.save_completed_game` runs in RoomManager, so the summary isn't
   ready at that moment. Confirm the intended design: a *second* broadcast (e.g. `{:game_summary, ...}`)
   from the RoomManager handler after the profile write — or fold the summary into the existing
   `game_over` by deferring that broadcast until after persistence?
2. **Per-socket privacy.** Should each player see only their own deltas (per-socket push, slice by
   `socket.assigns.user_id`) or the whole `%{user_id => summary}` map (room broadcast)?
3. **Casual fallback shape.** Exact field set the results screen wants for casual (XP/level/title +
   Mastery/achievements) vs rated (add `tier_before`/`tier_after`/`provisional`)? Acceptance says casual
   "leads with Veteran/Mastery, not a loud skill number."
4. **Single-read before-snapshot.** Each writer currently does its own `get_or_create_profile`. Capturing
   before-values likely means one read up front per participant and threading a snapshot map — confirm we
   want to refactor the four writers to accept/return snapshots vs adding a separate pre-read pass.
5. **Transaction boundary.** The summary is built inside the same `Repo.transaction`; if the txn rolls
   back (atomicity test, rollup_test:97), no summary should be pushed. Confirm the push happens only on
   `{:ok, _stats}` after commit (i.e. from RoomManager, not inside the txn).
6. **Non-UUID / bot seats.** Loop skips non-UUID ids (`profiles.ex:270-271`); single-player games with
   bot partners are casual. Confirm the summary is built only for human valid-UUID participants.
