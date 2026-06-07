---
date: 2026-06-07
ticket: PID-44
topic: "Player profile + lifetime stats store — codebase as-is"
status: complete
---
# Research: PID-44 Player profile + lifetime stats store

## Summary

The backend is a Phoenix 1.8 / Elixir OTP umbrella with two apps: `pidro_engine` (pure game rules) and `pidro_server` (Phoenix web + persistence). Persistence uses Postgres via a single `Ecto.Repo` (`PidroServer.Repo`). All persisted schemas use **`binary_id` (UUID) primary keys** with `@foreign_key_type :binary_id`.

Today there is **one per-game stats row** written at game completion (`game_stats` table, schema `PidroServer.Stats.GameStats`), and **no per-user rollup**. Lifetime stats are currently computed on-the-fly by scanning all `game_stats` rows whose `player_ids` array contains the user id (`PidroServer.Stats.get_user_stats/1`). There is **no profile, rating, XP, level, achievement, ELO, or OpenSkill code anywhere** in the codebase (verified by grep) — PID-44 would be greenfield in that respect, deriving from the existing `Accounts` + `Stats` modules.

A `game_stats` row already records everything PID-44 needs to roll up lifetime play: winner, final scores, the winning bid (amount + team), duration, the list of participating user ids, and a per-player `player_results` map (participation, result win/loss, team, position). Bots are NOT users and have NO user rows — they are simply absent from `player_ids`/`player_results` (or recorded under the abandoned human's id via `reserved_for`).

The completion write path is: engine reaches `:complete` → `GameAdapter.broadcast_game_over/2` PubSubs `{:game_over, room_code, winner, scores}` → `RoomManager.handle_info({:game_over, ...})` (room_manager.ex:1755) → `PidroServer.Stats.save_completed_game/4` (stats.ex:298), which is **idempotent per room** (it no-ops if a row for that `room_code` already exists). This is the single natural hook for updating a profile rollup on completion.

## Detailed Findings

### 1. The `PidroServer.Accounts` context — User schema, creation, Repo, dir layout

There is **no `accounts.ex` context module**. The accounts directory holds three files:

- `apps/pidro_server/lib/pidro_server/accounts/user.ex` — the `User` schema.
- `apps/pidro_server/lib/pidro_server/accounts/auth.ex` — the de-facto context (registration, auth, lookups, admin queries). This is where user creation lives.
- `apps/pidro_server/lib/pidro_server/accounts/token.ex` — auth token handling (not central to PID-44).

**`PidroServer.Accounts.User`** (`accounts/user.ex:1-82`):

- Primary key: `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id` (user.ex:12-13).
- Table: `"users"` (user.ex:15).
- Fields (user.ex:16-22):
  - `username` :string (required, min length 3, unique)
  - `email` :string (optional, format-validated, unique)
  - `password` :string, **virtual** (not stored)
  - `password_hash` :string (Bcrypt, set in `put_password_hash/1`)
  - `guest` :boolean, default `false`
  - `timestamps(type: :utc_datetime_usec)` → `inserted_at`, `updated_at` (note: microsecond precision; this is the only `:utc_datetime_usec` timestamp in the codebase — see Conventions).
- Changesets: `registration_changeset/2` (requires password, min 8, hashes) and `changeset/2` (cast username/email/password/guest, validations + unique constraints).
- There is **no `first_seen` field** beyond `inserted_at`; account age would derive from `inserted_at`.

**User creation / lookup** — `PidroServer.Accounts.Auth` (`accounts/auth.ex`):

- `register_user/1` (auth.ex:63-67): `%User{} |> User.registration_changeset(attrs) |> Repo.insert()`.
- `authenticate_user/2` (auth.ex:91-103).
- `get_user/1`, `get_user!/1` (auth.ex:121-148): `Repo.get(User, id)`.
- `get_user_by_username/1`, `get_user_by_email/1` (auth.ex:166-188).
- `get_users_map/1` (auth.ex:201-208): bulk fetch; **filters non-UUID ids** via `valid_uuid?/1` (auth.ex:289-296) using `Ecto.UUID.cast/1` — explicitly to skip bot ids and `"dev_host"`. This confirms non-user player ids can appear in stats data.
- `list_users/1`, `user_admin_summary/0`, `change_user/2`, `update_user/2`, `delete_user/1` (admin screens). `delete_user/1` doc note (auth.ex:282-287): *"Historical game stats keep the raw player id."* — so deleting a user does NOT cascade into `game_stats`.

**Repo** (`apps/pidro_server/lib/pidro_server/repo.ex:1-6`): `use Ecto.Repo, otp_app: :pidro_server, adapter: Ecto.Adapters.Postgres`. Single repo, no read replicas.

### 2. `PidroServer.Stats` context + `GameStats` schema, table, migrations, per-row contents

**`PidroServer.Stats.GameStats`** (`stats/game_stats.ex:1-68`):

- PK: `binary_id` autogenerate; `@foreign_key_type :binary_id` (game_stats.ex:9-10).
- Table: `"game_stats"` (game_stats.ex:12).
- Fields (game_stats.ex:13-22):
  - `room_code` :string (required)
  - `winner` :string — validated inclusion `["north_south", "east_west"]` (game_stats.ex:43)
  - `final_scores` :map — e.g. `%{north_south: 62, east_west: 45}` (atom-keyed when written; JSONB-roundtripped to string keys on read)
  - `bid_amount` :integer — validated 6..14 (game_stats.ex:47); the **winning** bid amount, nil if absent
  - `bid_team` :string — `north_south` / `east_west`; the team that won the bid
  - `duration_seconds` :integer — validated > 0
  - `completed_at` :utc_datetime (required)
  - `player_ids` `{:array, :binary_id}` — list of participating **user** ids (bots excluded)
  - `player_results` :map — per-user map (added later, see migration). Keys are user_id strings; values `%{participation, result, team, position}`.
  - `timestamps()` → `inserted_at`, `updated_at` (naive/utc default, NOT `_usec` — differs from `User`).
- Changeset normalizes atom enum fields to strings (`normalize_enum_fields/1`, game_stats.ex:51-67).

**So a completed-game row records, per game (not per player-row):** winner team, final cumulative scores per team, the winning bid amount + bidding team, game duration, the participating users, and a per-user result map (win/loss, team, position N/E/S/W, and participation = `:played | :abandoned | :substitute`). It does NOT store per-player bids, per-player bidding-win flags, per-player scores, or a bot flag (bots are simply omitted). **Note for the Playstyle metric** (bidding-win rate + average winning bid): the row records the *winning bid* and the *bidding team*, but does not currently mark which individual user was the bidder — only the team. Deriving a per-user "bidding-win rate" from `game_stats` alone requires inferring it from `bid_team` + the user's `team` in `player_results` (i.e. the user's team won the contract), not from a per-user bid record.

**Migrations** (`apps/pidro_server/priv/repo/migrations/`):

- `20251102091113_create_users.exs` — creates `users` (binary_id pk, unique indexes on username/email).
- `20251102100750_create_game_stats.exs` — creates `game_stats`; indexes on `completed_at`, `room_code`, and a **GIN index on `player_ids`** (`using: "GIN"`) to support the `^user_id in gs.player_ids` / `&&` array-overlap queries.
- `20260308083652_add_player_results_to_game_stats.exs` — `alter table … add :player_results, :map`.
- `20260311204000_create_abandonment_events.exs` — creates `abandonment_events` (note `user_id` is **:string here, NOT binary_id**; `timestamps(updated_at: false)`; unique index on `[:user_id, :room_code]`).
- `20260424030000_create_email_templates.exs`, `20260424050000_add_key_to_email_templates.exs` — unrelated (email).

**`PidroServer.Stats` context** (`stats/stats.ex`):

- `save_game_result/1` (stats.ex:23-27): insert via changeset.
- `get_user_stats/1` (stats.ex:50-78): **on-the-fly lifetime rollup** — `from gs in GameStats, where: ^user_id in gs.player_ids`, then computes `games_played, wins, losses, win_rate, total_duration_seconds, average_bid, games_abandoned, abandonment_rate, last_abandoned_at`. This is the function PID-44's "single cheap fetch" would replace/back.
- `get_user_stats_map/1` (stats.ex:86-132): bulk version for admin lists, uses array-overlap `fragment("? && ?", gs.player_ids, type(^user_ids, {:array, :binary_id}))`.
- `count_user_wins/2` (stats.ex:467-486): wins derived from `player_results[user_id].result == :win`, falling back to position-vs-winner inference.
- `get_leaderboard/1` (stats.ex:189-224): scans ALL `game_stats` (explicitly commented as a "simplified version … in production you'd want a separate leaderboard table") — relevant prior art for why a rollup table is wanted.
- `build_player_results/3`, `save_completed_game/4`, `record_abandonment/3`, `list_abandonments_for_room/1` (see Q3).

### 3. Where/how game completion writes stats — the call path

1. **Engine** reaches terminal phase. `GameState` (`apps/pidro_engine/lib/pidro/core/types.ex`, `GameState` typedstruct from line 236) carries `:phase`, `:winner` (team), `:cumulative_scores` (`%{team => integer}`), `:highest_bid` (`{position, amount}`), `:bidding_team`, `:hand_number`, `:bids` (list of `%Bid{position, amount}`), `:players` (`%{position => %Player{team, tricks_won, …}}`), `:tricks`.
2. **`PidroServer.Games.GameAdapter.broadcast_game_over/2`** (`games/game_adapter.ex:348-358`): when `new_state.phase in [:complete, :game_over]` (game_adapter.ex:332), reads `winner = state.winner` and `scores = state.scores || state.cumulative_scores`, then `Phoenix.PubSub.broadcast(PidroServer.PubSub, "game:#{room_code}", {:game_over, room_code, winner, scores})`.
3. **`PidroServer.Games.RoomManager.handle_info({:game_over, room_code, winner, scores}, state)`** (`games/room_manager.ex:1755-1783`): fetches live engine state via `GameAdapter.get_state(room_code)` (room_manager.ex:1762), marks the room `:finished`, then calls:
   `:ok = Stats.save_completed_game(finished_room, winner, scores, game_state)` (room_manager.ex:1774).
4. **`PidroServer.Stats.save_completed_game/4`** (`stats/stats.ex:298-331`) — **the persistence function** and the idempotency boundary:
   - `Repo.get_by(GameStats, room_code: room_code)` → if a row exists, returns `:ok` (no duplicate). **Idempotent per room_code.**
   - Otherwise builds attrs and inserts:
     - `bid_info = extract_bid_info(game_state)` (stats.ex:443-459): from `game_state.highest_bid` (`{position, amount}` or `%{position, amount}`) → `%{bid_amount, bid_team}` (team derived from position).
     - `duration_seconds = max(1, DateTime.diff(now, room.created_at, :second))`.
     - `abandonment_events = list_abandonments_for_room(room_code)`.
     - `player_results = build_player_results(room.seats, winner, abandonment_events)`.
     - `player_ids = Map.keys(player_results)`.
5. **`build_player_results/3`** (`stats/stats.ex:238-256`) iterates `room.seats` (a `%{position => %Seat{}}` map) and classifies each seat via `classify_seat/1` (stats.ex:370-391):
   - connected human + `substitute: true` → `{:record, user_id, :substitute}`
   - connected human → `{:record, user_id, :played}`
   - bot with `reserved_for` set → `{:record, reserved_for, :abandoned}` (the abandoned human's id)
   - pure bot (no `reserved_for`) → `:skip` (bots never recorded)
   - Each recorded user gets `%{participation, result (:win/:loss by team-vs-winner), team, position}` (`build_result/3`, stats.ex:393-403). Then merges any abandonment events (`merge_abandonment_events/3`, stats.ex:405-415).

**Data available at completion** (the function's inputs): per-seat `user_id` + occupant_type + substitute/reserved flags (so: who played, who abandoned, who substituted, and each player's seat position → team N/S = north_south, E/W = east_west); the winning team; final per-team cumulative scores; the winning bid amount + bidding team. **Not directly available in the persisted attrs:** per-player bid history (it lives only on the transient `game_state.bids` / `highest_bid` at call time — only the single highest/winning bid is extracted), per-player scores, or an explicit bot flag.

### 4. Schema / context / migration / test conventions

- **Schemas:** `use Ecto.Schema`; binary_id PKs via `@primary_key {:id, :binary_id, autogenerate: true}` + `@foreign_key_type :binary_id`; `import Ecto.Changeset`; a `changeset/2` (and sometimes a purpose-specific changeset) that `cast`s + `validate_*`s + `unique_constraint`s. `@moduledoc` present. Enum-like fields stored as `:string` with `validate_inclusion`. Timestamps: most use plain `timestamps()`; `User` uses `timestamps(type: :utc_datetime_usec)`; `AbandonmentEvent` uses `timestamps(updated_at: false)`.
- **Contexts:** plain modules (e.g. `PidroServer.Stats`, `PidroServer.Accounts.Auth`) that `alias PidroServer.Repo` and wrap `Repo.*` calls; `import Ecto.Query`. No Phoenix-generated `Accounts` boilerplate. Pure-function bias per `apps/pidro_server/CLAUDE.md` ("Single source of truth: Derive data, don't store duplicates" — directly relevant tension for a rollup table).
- **Migrations:** named `YYYYMMDDHHMMSS_snake_case_description.exs`, module `PidroServer.Repo.Migrations.<CamelCase>`, `use Ecto.Migration`, `def change`. Tables created with `create table(:name, primary_key: false) do add :id, :binary_id, primary_key: true … end`. Indexes created explicitly after the table; GIN used for array columns. Newest migration timestamp: `20260424050000`.
- **Tests:** under `apps/pidro_server/test/`, mirroring lib paths (`test/pidro_server/stats/`, `test/pidro_server/games/`, etc.). Support modules in `test/support/`: `data_case.ex` (`PidroServer.DataCase` — used by `score_protection_test.exs`), `conn_case.ex`, `channel_case.ex`, `fixtures.ex`. The only existing Stats test is `test/pidro_server/stats/score_protection_test.exs` — it uses `use PidroServer.DataCase, async: false`, generates user ids with `Ecto.UUID.generate()`, drives `RoomManager` end-to-end, and asserts on persisted `GameStats` (incl. that `player_results` round-trips with **string keys/values** after JSONB: `saved_game.player_results[user2]["participation"] == "abandoned"`, stats.ex test:204). Idempotency is explicitly tested (sends `:game_over` twice, asserts `Repo.aggregate(GameStats, :count) == 1`, test:210). There is **no dedicated Accounts/Auth context test** found.

### 5. How a player/user is identified across a game; bot seats

- A user is identified by their **UUID** (`User.id`, binary_id). In `game_stats`, `player_ids` is `{:array, :binary_id}` and `player_results` keys are user-id strings; there is **no foreign-key/association** declared from `game_stats` to `users` — it's a loose array of ids (deletes don't cascade; non-UUID ids like `"dev_host"` can appear and are filtered by `Auth.get_users_map/1`).
- **Bots are NOT users** — they have no `users` row. In `Seat` (`games/room/seat.ex:22-52`), `occupant_type` is `:human | :bot | :vacant`; bot seats have `bot_pid` set and `user_id: nil`. At completion, pure bot seats are `:skip`ped (never recorded). A human who disconnected and was bot-substituted is recorded under their original id via the seat's `reserved_for` field (participation `:abandoned`). So "is this seat a bot?" is expressed structurally (occupant_type + bot_pid + reserved_for), never as a column on stats.
- Seat→team mapping: north/south → `north_south`, east/west → `east_west` (`team_for_position/1`, stats.ex:440-441).
- `abandonment_events.user_id` is a **:string** column (not binary_id) — a small inconsistency to note when joining.

### 6. Existing profile / rating / xp / level / achievement / elo / openskill code

**None.** Grep across `apps/**/*.ex` for `rating`, `xp`, `veteran`, `mastery`, `playstyle`, `heritage`, `elo`, `openskill`, `sigma`, `mu`, `achievement` returned no progression-domain matches (only false positives like config "level" and unrelated words). The word "profile" appears only as: admin "profile edits" in `Auth.change_user/update_user` (auth.ex:266-280) and OpenAPI schema/JSON for the API user-stats response. The closest existing artifact to a "profile screen" feed is:

- `PidroServer.Stats.get_user_stats/1` (stats.ex:50) — the per-user lifetime aggregate computed live.
- API surface: `PidroServerWeb` user-stats endpoint (`controllers/api/user_controller.ex:82-93` calls `Stats.get_user_stats(user_id)`), with OpenAPI shape in `schemas/user_schemas.ex:280+` (`games_played`, `wins`, `win_rate`, etc.).
- Admin LiveViews consume it: `live/dev/user_detail_live.ex:495` (`Stats.get_user_stats`) and `live/dev/user_list_live.ex:404` (`Stats.get_user_stats_map`).

So PID-44's "single cheap fetch" would back/replace `get_user_stats/1`, and the rollup table is greenfield. The `get_leaderboard/1` comment (stats.ex:191-193) already anticipates "a separate leaderboard table."

## Code References

- `apps/pidro_server/lib/pidro_server/accounts/user.ex:12-23` — User schema: binary_id PK, table `"users"`, fields username/email/password(virtual)/password_hash/guest, `:utc_datetime_usec` timestamps.
- `apps/pidro_server/lib/pidro_server/accounts/auth.ex:63-67` — `register_user/1` (user creation).
- `apps/pidro_server/lib/pidro_server/accounts/auth.ex:201-208,289-296` — `get_users_map/1` + `valid_uuid?/1` (filters non-UUID/bot ids).
- `apps/pidro_server/lib/pidro_server/accounts/auth.ex:282-287` — `delete_user/1`: stats keep raw player id (no cascade).
- `apps/pidro_server/lib/pidro_server/repo.ex:1-6` — single Postgres Repo.
- `apps/pidro_server/lib/pidro_server/stats/game_stats.ex:9-49` — GameStats schema + changeset (all fields/validations).
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:50-78` — `get_user_stats/1` (current live lifetime rollup; target of "single cheap fetch").
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:298-331` — `save_completed_game/4` (idempotent per-room completion write; the natural rollup hook).
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:238-256,370-403` — `build_player_results/3` + `classify_seat/1` + `build_result/3` (per-user participation/result/team/position; bots skipped).
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:443-459` — `extract_bid_info/1` (winning bid amount + bidding team from game_state).
- `apps/pidro_server/lib/pidro_server/stats/stats.ex:189-224` — `get_leaderboard/1` ("in production you'd want a separate leaderboard table").
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex:1755-1783` — `{:game_over, ...}` handler that calls `Stats.save_completed_game/4`.
- `apps/pidro_server/lib/pidro_server/games/game_adapter.ex:332-358` — `broadcast_game_over/2` emits `{:game_over, room_code, winner, scores}`.
- `apps/pidro_server/lib/pidro_server/games/room/seat.ex:22-52` — Seat struct (occupant_type, user_id, reserved_for, substitute) — how bots vs humans are distinguished.
- `apps/pidro_engine/lib/pidro/core/types.ex:236-330` — `GameState` struct (winner, cumulative_scores, highest_bid, bidding_team, bids, players) available at completion.
- `apps/pidro_server/priv/repo/migrations/20251102091113_create_users.exs` — users table migration (binary_id pattern, verbatim below).
- `apps/pidro_server/priv/repo/migrations/20251102100750_create_game_stats.exs` — game_stats migration (GIN index on player_ids).
- `apps/pidro_server/priv/repo/migrations/20260308083652_add_player_results_to_game_stats.exs` — most recent stats-related migration (alter add :map).
- `apps/pidro_server/test/pidro_server/stats/score_protection_test.exs:1-251` — representative context test (DataCase, UUID fixtures, idempotency assertions, JSONB string-key round-trip).
- `apps/pidro_server/lib/pidro_server_web/controllers/api/user_controller.ex:82-93` + `schemas/user_schemas.ex:280+` — API surface consuming `get_user_stats/1`.

## Conventions observed

### Representative schema module (verbatim) — `GameStats`

```elixir
defmodule PidroServer.Stats.GameStats do
  @moduledoc """
  Schema for storing game statistics and history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_stats" do
    field :room_code, :string
    field :winner, :string
    field :final_scores, :map
    field :bid_amount, :integer
    field :bid_team, :string
    field :duration_seconds, :integer
    field :completed_at, :utc_datetime
    field :player_ids, {:array, :binary_id}
    field :player_results, :map

    timestamps()
  end

  @doc false
  def changeset(game_stats, attrs) do
    attrs = normalize_enum_fields(attrs)

    game_stats
    |> cast(attrs, [
      :room_code, :winner, :final_scores, :bid_amount, :bid_team,
      :duration_seconds, :completed_at, :player_ids, :player_results
    ])
    |> validate_required([:room_code, :completed_at])
    |> validate_inclusion(:winner, ["north_south", "east_west"], message: "must be north_south or east_west")
    |> validate_inclusion(:bid_team, ["north_south", "east_west"])
    |> validate_number(:bid_amount, greater_than_or_equal_to: 6, less_than_or_equal_to: 14)
    |> validate_number(:duration_seconds, greater_than: 0)
  end
  # ... normalize_enum_fields/1 omitted ...
end
```

### Most recent stats migration (verbatim) — add player_results

```elixir
defmodule PidroServer.Repo.Migrations.AddPlayerResultsToGameStats do
  use Ecto.Migration

  def change do
    alter table(:game_stats) do
      add :player_results, :map
    end
  end
end
```

### Table-creation migration (verbatim) — game_stats (binary_id + GIN pattern)

```elixir
defmodule PidroServer.Repo.Migrations.CreateGameStats do
  use Ecto.Migration

  def change do
    create table(:game_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_code, :string, null: false
      add :winner, :string
      add :final_scores, :map
      add :bid_amount, :integer
      add :bid_team, :string
      add :duration_seconds, :integer
      add :completed_at, :utc_datetime
      add :player_ids, {:array, :binary_id}

      timestamps()
    end

    create index(:game_stats, [:completed_at])
    create index(:game_stats, [:player_ids], using: "GIN")
    create index(:game_stats, [:room_code])
  end
end
```

### Conventions distilled

- **Migrations:** `YYYYMMDDHHMMSS_snake_case.exs`; module `PidroServer.Repo.Migrations.<CamelCase>`; `use Ecto.Migration` + `def change`; `create table(:x, primary_key: false) do add :id, :binary_id, primary_key: true … end`; explicit indexes (GIN for arrays). Latest stamp `20260424050000`.
- **Schemas:** binary_id PK + `@foreign_key_type :binary_id`; `changeset/2` with cast → validate_required → validate_inclusion/number → unique_constraint; enums stored as strings with `validate_inclusion`; `@moduledoc`.
- **Contexts:** plain modules aliasing `PidroServer.Repo`, wrapping Repo calls; `import Ecto.Query, warn: false`.
- **Tests:** `use PidroServer.DataCase`; `Ecto.UUID.generate()` for ids; drive real GenServers (`RoomManager`) for integration; assert on persisted rows; remember JSONB maps come back **string-keyed/string-valued**.

## Open Questions

1. **Profile PK / association to User:** convention is binary_id everywhere, but `game_stats` deliberately has NO FK to `users` (and stores stray ids like `"dev_host"`). Should a profile row have a real `references(:users)` FK (cascade on delete?) given `delete_user/1` explicitly preserves historical stats — or follow the loose-id pattern?
2. **Bidding-win-rate / average-winning-bid (Playstyle):** `game_stats` records the *winning bid* and *bidding team*, but not which individual user bid it. Can per-user bidding-win rate be derived as "user's team == bid_team AND user's team == winner"? Or does PID-44 require capturing per-player bid data that the engine has (`game_state.bids`) but is not currently persisted into `game_stats`?
3. **Idempotent rebuild source:** `save_completed_game/4` is idempotent per `room_code`, but `player_results` keys round-trip as strings via JSONB; a rebuild that re-scans `game_stats` must handle both atom-keyed (in-memory) and string-keyed (DB) result maps (see `get_player_result/2`, stats.ex:488-493).
4. **Timestamp precision mismatch:** `User` uses `:utc_datetime_usec`; `game_stats`/`abandonment_events` use default. Which precision should the profile table adopt for `first_seen` / rating-update timestamps?
5. **Bots vs guests in rating:** bots have no user row (excluded), but `guest` users DO have rows and appear in `player_ids`. Should guest users get profiles/ratings, or only registered users?
6. **Rebuild trigger:** there is currently no batch/rebuild path or background job infrastructure visible in the Stats context — where would an idempotent "rebuild from completed-games history" run (mix task, Repo transaction, on-demand function)?
