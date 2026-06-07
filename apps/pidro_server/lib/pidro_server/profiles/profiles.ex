defmodule PidroServer.Profiles do
  @moduledoc """
  Context for per-user profiles and lifetime stats rollups.

  A `PidroServer.Profiles.PlayerProfile` is one durable row per user, created
  lazily. It holds lifetime play counters (`games_played`, `wins`, `losses`)
  maintained incrementally on game completion (via the `Stats.save_completed_game/4`
  hook) and rebuildable from `game_stats` history. Derived values such as
  `win_rate`, `avg_winning_bid`, and `account_age_days` are computed at read time,
  never stored.

  Progression columns (rating, veteran/XP, playstyle, heritage) ship with
  defaults and are owned by later tickets (PID-45..PID-51); PID-44 does not write
  them.
  """

  require Logger
  import Ecto.Query, warn: false

  alias PidroServer.Accounts.User
  alias PidroServer.Achievements
  alias PidroServer.Achievements.Catalog
  alias PidroServer.Playstyle
  alias PidroServer.Profiles.Achievement
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Profiles.PostGameSummary
  alias PidroServer.Profiles.RatingState
  alias PidroServer.Progression
  alias PidroServer.Progression.Heritage
  alias PidroServer.Rating
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  @typedoc "A player rating `{mu, sigma}`, as `PidroServer.Rating`."
  @type rating :: {float(), float()}

  @doc """
  Returns the profile for a user, creating a default row lazily if absent.

  Race-safe: a concurrent insert against the unique `user_id` index is absorbed
  by `on_conflict: :nothing` followed by a re-fetch.
  """
  @spec get_or_create_profile(Ecto.UUID.t()) ::
          {:ok, PlayerProfile.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_profile(user_id) do
    case Repo.get_by(PlayerProfile, user_id: user_id) do
      %PlayerProfile{} = profile ->
        {:ok, profile}

      nil ->
        %PlayerProfile{}
        |> PlayerProfile.changeset(%{user_id: user_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :user_id)
        |> case do
          {:ok, %PlayerProfile{id: nil}} ->
            # on_conflict: :nothing returned a struct without an id (a concurrent
            # insert won the race) — re-fetch the existing row.
            {:ok, Repo.get_by!(PlayerProfile, user_id: user_id)}

          {:ok, %PlayerProfile{} = profile} ->
            {:ok, profile}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Single cheap fetch for the profile screen.

  Returns the stored profile fields plus derived values (`win_rate`,
  `avg_winning_bid`, `first_seen_at`, `account_age_days`). Lazily creates the
  profile row. This is a unique-index lookup — no `game_stats` array scan.
  """
  @spec get_profile_for_screen(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def get_profile_for_screen(user_id) do
    with {:ok, profile} <- get_or_create_profile(user_id) do
      first_seen_at = first_seen_at(user_id)
      earned = list_achievements(user_id)
      earned_keys = MapSet.new(earned, & &1.achievement_key)

      # Playstyle (PID-51): derive the needle/label/avg-bid from the accumulators.
      rate =
        Playstyle.bidding_win_rate(
          profile.playstyle_bidding_wins,
          profile.playstyle_bidding_attempts
        )

      needle = Playstyle.needle(rate)

      {:ok,
       %{
         user_id: profile.user_id,
         games_played: profile.games_played,
         wins: profile.wins,
         losses: profile.losses,
         win_rate: win_rate(profile.wins, profile.games_played),
         rating_mu: profile.rating_mu,
         rating_sigma: profile.rating_sigma,
         rating_games_count: profile.rating_games_count,
         # veteran_level recomputed from XP (canonical) so a stale cache can never
         # surface; equals the stored cache by construction once any game/rebuild ran.
         veteran_level: Progression.level_for_xp(profile.veteran_xp),
         veteran_xp: profile.veteran_xp,
         veteran_title: Progression.title_for_level(Progression.level_for_xp(profile.veteran_xp)),
         veteran_progress: Progression.level_progress(profile.veteran_xp),
         playstyle_bidding_wins: profile.playstyle_bidding_wins,
         playstyle_bidding_attempts: profile.playstyle_bidding_attempts,
         # PID-51 derived playstyle view (raw counters kept above — internal):
         bidding_win_rate: if(rate == :insufficient, do: nil, else: rate),
         aggression_needle: needle,
         aggression_label: Playstyle.label(needle),
         aggression_insufficient: rate == :insufficient,
         avg_winning_bid:
           Playstyle.avg_winning_bid(profile.avg_winning_bid_sum, profile.avg_winning_bid_count),
         heritage_flags: profile.heritage_flags,
         heritage: Heritage.display(profile.heritage_flags),
         first_seen_at: first_seen_at,
         account_age_days: account_age_days(first_seen_at),
         # PID-50: earned achievements (joined to Catalog for display copy) +
         # an optional active-catalog view with an `earned` flag so a UI can
         # show locked achievements. Dormant defs are NOT surfaced.
         achievements: screen_achievements(earned),
         achievements_catalog: screen_catalog(earned_keys)
       }}
    end
  end

  # Joins the user's earned rows to the Catalog for display copy, ordered by
  # award time. Unknown keys (a def removed from the catalog) are dropped.
  defp screen_achievements(earned) do
    earned
    |> Enum.sort_by(& &1.awarded_at, DateTime)
    |> Enum.flat_map(fn row ->
      case safe_existing_atom(row.achievement_key) do
        {:ok, key} ->
          def = Enum.find(Catalog.all(), &(&1.key == key))

          if def do
            [
              %{
                key: key,
                name: def.name,
                description: def.description,
                tier: row.tier,
                awarded_at: row.awarded_at
              }
            ]
          else
            []
          end

        :error ->
          []
      end
    end)
  end

  # The active catalog annotated with an `earned` flag (cheap: in-memory data +
  # an already-loaded earned-key set).
  defp screen_catalog(earned_keys) do
    Enum.map(Catalog.active(), fn def ->
      %{
        key: def.key,
        name: def.name,
        description: def.description,
        tier: def.tier,
        earned: MapSet.member?(earned_keys, Atom.to_string(def.key))
      }
    end)
  end

  @doc """
  Arity-2 shim for the lifetime-counter completion hook (PID-44). Delegates with
  empty `scores` + default options so the historical call shape keeps working;
  ratings and XP now move too (see the `/4` doc). With empty scores, XP for these
  callers is `0 + win_bonus` for winners and `0` for losers — production always
  passes real scores from `stats.ex`.
  """
  @spec apply_completed_game(map(), atom() | String.t()) ::
          {:ok, %{optional(Ecto.UUID.t()) => map()}}
  def apply_completed_game(player_results, winner),
    do: apply_completed_game(player_results, winner, %{}, %{}, [])

  @doc """
  Applies one completed game to the participating users' profiles, inside the
  caller's transaction (`Stats.save_completed_game/4`).

  ## Lifetime counters (PID-44)

  Increments `games_played` and either `wins` or `losses` for every valid-UUID
  key in `player_results` (counters count ALL human participation, including
  `:abandoned` reserved-for ids). Bots never appear (the caller skips them). Ids
  that are not valid UUIDs are logged and skipped rather than crashing the
  surrounding transaction.

  ## Veteran XP (PID-49) — every completed game, NOT rated-gated

  In the SAME per-participant loop as the counters (dedication, not skill), each
  valid-UUID participant earns `Progression.xp_for_game(team_score, won?)` from
  the per-team `scores` map (`%{north_south: int, east_west: int}`, atom- or
  string-keyed). `veteran_xp` is incremented and `veteran_level` is recomputed
  from the new total. This runs for single-player and bot-filled games too — XP
  is NOT behind `rated_game?/1` (which stays exclusive to the rating block).

  ## Ratings (PID-47) — bot-seat policy (authoritative, v1)

  Rates ONLY a game that started 4 distinct human seats (a full 2v2 of real
  users). Reads each participant's CURRENT stored `{mu, sigma}` as priors via
  `load_priors/1`, calls the shared `rate_game/3`, and on `{:rated, updated}`
  overwrites each participant's `rating_mu`/`rating_sigma` and increments
  `rating_games_count` by 1; on `:unrated` leaves every rating column untouched.

  Single-player / bots-only, 3-human + bot-fill, and any game with fewer than 4
  distinct valid-UUID keys are unrated (lifetime counters still update). This
  falls out of the single shared `rated_game?/1` (reached via `rate_game/3`) —
  no separate flag. `:abandoned` (original human disconnected, bot played under
  their UUID) and `:substitute` seats stay RATED in v1: they still represent 4
  distinct human UUIDs that started the game. Tightening the predicate to exclude
  them is deferred — a one-line change in the single shared `rated_game?/1` that
  both the live and rebuild paths track automatically.

  The per-game move is identical-by-construction to one `rerate_incremental/0`
  replay step (same `rate_game/3`, same priors-at-this-game, count += 1), and so
  matches a fresh `rerate_all/0`. This path does NOT advance the `rating_state`
  cursor — see the cursor-coherence contract in `rerate_incremental/0`'s `@doc`.

  The `opts` keyword is a forward seam only; pass `[]` (no options read in v1).

  ## Achievements (PID-50) + the newly-earned-keys return (PID-52 seam)

  After counters/XP/rating, evaluates the active `Catalog` achievements for each
  valid-UUID participant (live `ctx`: post-update aggregates, this game's
  `game_view`, and the user's ordered history incl. this game — the row was
  inserted earlier in this same transaction) and idempotent-upserts the awards.

  The newly-earned keys (those awarded for the FIRST time this call) become the
  `achievements_unlocked` field of each participant's summary (PID-52).

  ## Post-game summary (PID-52) — the new return

  **Returns `{:ok, %{user_id => summary_map}}`** — one ephemeral per-player
  "what changed" map (built by the pure `PostGameSummary.build/3` from a BEFORE
  snapshot read at the top of the loop body + the XP/rating/achievement deltas
  this call computes). Nothing is persisted; the summary is built from
  in-transaction reads and handed back for the caller to push. See
  `PidroServer.Profiles.PostGameSummary` for the shape. There is no rebuild
  concern — `rebuild_*` are untouched.

  ## Playstyle (PID-51) — every completed game, NOT rated-gated

  In the SAME per-participant loop, each valid-UUID participant's bidding facts
  from `player_bidding` (`%{user_id => %{"attempts", "wins", "won_bid_sum"}}`,
  the per-game map built by `Stats.build_player_bidding/2`; string- or atom-keyed
  tolerant, `nil` → no-op) are folded into the four playstyle accumulators
  (`playstyle_bidding_attempts`, `playstyle_bidding_wins`, `avg_winning_bid_sum`,
  `avg_winning_bid_count`). Like XP, playstyle is *character* not skill — it ticks
  for single-player / bot-filled games too. Bot seats never appear as keys in
  `player_bidding`, so bots never pollute a human's accumulators.
  """
  @spec apply_completed_game(map(), atom() | String.t(), map(), map(), keyword()) ::
          {:ok, %{optional(Ecto.UUID.t()) => map()}}
  def apply_completed_game(player_results, winner, scores, player_bidding \\ %{}, opts \\ [])

  def apply_completed_game(player_results, winner, scores, player_bidding, _opts)
      when is_map(player_results) do
    player_bidding = if is_map(player_bidding), do: player_bidding, else: %{}
    rated? = match?({:ok, _}, rated_game?(player_results))

    # 1. Lifetime counters (PID-44) + veteran XP (PID-49) + playstyle (PID-51):
    #    every valid-UUID participant, regardless of rated status. Capture a
    #    single coherent BEFORE snapshot per participant (one read at the top of
    #    the loop body, before the writers run) and the XP delta the writer
    #    already computes — both threaded into the summary later.
    {before_snapshots, xp_deltas} =
      Enum.reduce(player_results, {%{}, %{}}, fn {user_id, result}, {befores, xp} ->
        case Ecto.UUID.cast(user_id) do
          {:ok, valid_id} ->
            {:ok, before} = get_or_create_profile(valid_id)

            apply_one(valid_id, win_from_result?(result))
            xp_delta = apply_xp(valid_id, result, scores)
            apply_playstyle(valid_id, bidding_facts_for(player_bidding, user_id))

            {Map.put(befores, valid_id, before_snapshot(before)), Map.put(xp, valid_id, xp_delta)}

          :error ->
            Logger.warning(
              "Profiles.apply_completed_game skipping non-UUID id #{inspect(user_id)}"
            )

            {befores, xp}
        end
      end)

    # 2. Ratings (PID-47): rated 4-human games only, priors from stored rows.
    #    Surfaces the per-user before/after μ/σ + counts (empty on :unrated).
    rating_deltas = apply_live_rating(player_results, winner)

    # 3. Achievements (PID-50): per valid-UUID participant, evaluate active defs
    #    against the post-update aggregates + this game + ordered history, and
    #    idempotent-upsert. Returns the per-user newly-earned keys.
    newly_earned = apply_live_achievements(player_results, scores)

    # 4. Assemble the ephemeral per-player summary from the deltas just computed.
    summaries =
      Map.new(before_snapshots, fn {valid_id, before} ->
        deltas =
          build_deltas(
            rated?,
            Map.fetch!(xp_deltas, valid_id),
            Map.get(rating_deltas, valid_id),
            Map.get(newly_earned, valid_id, [])
          )

        {valid_id, PostGameSummary.build(before, deltas, [])}
      end)

    {:ok, summaries}
  end

  def apply_completed_game(_player_results, _winner, _scores, _player_bidding, _opts),
    do: {:ok, %{}}

  # The BEFORE snapshot of the profile columns the summary classifies against.
  defp before_snapshot(%PlayerProfile{} = profile) do
    %{
      veteran_xp: profile.veteran_xp,
      rating_mu: profile.rating_mu,
      rating_sigma: profile.rating_sigma,
      rating_games_count: profile.rating_games_count
    }
  end

  # Merge the XP, rating, and achievement deltas into the shape PostGameSummary
  # expects. A casual game (or a participant with no rating move) carries
  # `rating_after: nil`.
  defp build_deltas(rated?, %{xp_earned: xp_earned, veteran_xp_after: xp_after}, rating, keys) do
    {rating_after, count_after} =
      case rating do
        %{after: after_rating, count_after: count_after} -> {after_rating, count_after}
        nil -> {nil, nil}
      end

    %{
      xp_earned: xp_earned,
      veteran_xp_after: xp_after,
      rated?: rated? and not is_nil(rating_after),
      rating_after: rating_after,
      rating_count_after: count_after,
      newly_earned_keys: keys
    }
  end

  @doc """
  Recomputes a single user's lifetime counters from `game_stats` history and
  overwrites them.

  Idempotent; reproduces exactly what the incremental path would have produced.
  Tolerates string-keyed JSONB `player_results` on persisted rows.
  """
  @spec rebuild_from_history(Ecto.UUID.t()) ::
          {:ok, PlayerProfile.t()} | {:error, term()}
  def rebuild_from_history(user_id) do
    # Canonical total order (`[asc: completed_at, asc: inserted_at, asc: id]`):
    # the win-streak evaluator needs a stable consecutive ordering, and it must
    # match the order the live path's history query sees so awards stay in parity.
    games =
      from(gs in GameStats,
        where: ^user_id in gs.player_ids,
        order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
      )
      |> Repo.all()

    games_played = length(games)
    wins = Enum.count(games, &won_game?(&1, user_id))
    losses = games_played - wins

    # Veteran XP is a commutative per-game sum, so the rebuild mirrors the live
    # path exactly (same xp_for_game/2 inputs). Order-agnostic, idempotent.
    veteran_xp =
      Enum.reduce(games, 0, fn game, acc -> acc + xp_for_history_game(game, user_id) end)

    # Playstyle accumulators are commutative per-game sums of each row's stored
    # player_bidding facts (string-keyed JSONB tolerant; nil/missing → zero), so
    # the rebuild mirrors the live path exactly. wins == won-bid count, so the
    # avg's count accumulator equals the wins sum.
    playstyle =
      Enum.reduce(
        games,
        %{attempts: 0, wins: 0, won_bid_sum: 0},
        fn game, acc ->
          %{attempts: attempts, wins: wins, won_bid_sum: won_bid_sum} =
            playstyle_facts(bidding_facts_for(game.player_bidding, user_id) || %{})

          %{
            attempts: acc.attempts + attempts,
            wins: acc.wins + wins,
            won_bid_sum: acc.won_bid_sum + won_bid_sum
          }
        end
      )

    with {:ok, profile} <- get_or_create_profile(user_id) do
      result =
        profile
        |> PlayerProfile.changeset(%{
          games_played: games_played,
          wins: wins,
          losses: losses,
          veteran_xp: veteran_xp,
          veteran_level: Progression.level_for_xp(veteran_xp),
          playstyle_bidding_attempts: playstyle.attempts,
          playstyle_bidding_wins: playstyle.wins,
          avg_winning_bid_sum: playstyle.won_bid_sum,
          avg_winning_bid_count: playstyle.wins
        })
        |> Repo.update()

      # Achievements (PID-50): re-award all active defs from the full ordered
      # history. Idempotent (on_conflict: :nothing) and never removes/downgrades
      # — permanence holds even if a def now evaluates false. Same evaluator as
      # the live path; the ctx history is the identical total order, so the
      # earned-key set matches the live path by construction.
      ctx = %{
        user_id: user_id,
        aggregates: %{games_played: games_played, wins: wins},
        this_game: nil,
        history: Enum.map(games, &history_game_view(&1, user_id))
      }

      ctx
      |> Achievements.evaluate_active()
      |> then(&ensure_achievements(user_id, &1))

      result
    end
  end

  @doc """
  Rebuilds every known user's profile from history.

  Collects the distinct set of user ids appearing in `game_stats.player_ids`
  and rebuilds each. Returns `{:ok, count}` with the number of profiles rebuilt.
  """
  @spec rebuild_all() :: {:ok, non_neg_integer()}
  def rebuild_all do
    user_ids =
      from(gs in GameStats, select: gs.player_ids)
      |> Repo.all()
      |> List.flatten()
      |> Enum.uniq()

    Enum.each(user_ids, &rebuild_from_history/1)

    {:ok, length(user_ids)}
  end

  # --- Achievements context (PID-50) ---

  @doc """
  All earned achievement rows for a user (permanent; one per `achievement_key`).
  """
  @spec list_achievements(Ecto.UUID.t()) :: [Achievement.t()]
  def list_achievements(user_id) do
    from(a in Achievement, where: a.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Idempotently awards one achievement to a user.

  Insert with `on_conflict: :nothing` against the unique `[:user_id,
  :achievement_key]` index. Returns `:awarded` when a row was actually inserted
  (newly earned this call) or `:already` when the conflict absorbed it (already
  earned). Permanent — there is no remove/downgrade path.
  """
  @spec award_achievement(Ecto.UUID.t(), atom() | String.t(), pos_integer(), map()) ::
          :awarded | :already
  def award_achievement(user_id, key, tier \\ 1, metadata \\ %{}) do
    now = DateTime.utc_now()

    # insert_all + on_conflict: :nothing gives a reliable affected-row count:
    # 1 when actually inserted (newly earned), 0 when the unique conflict
    # absorbed it (already earned). A plain Repo.insert returns a struct with the
    # client-generated binary_id in BOTH cases, so it cannot distinguish them.
    {count, _} =
      Repo.insert_all(
        Achievement,
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            achievement_key: to_string(key),
            tier: tier,
            awarded_at: now,
            metadata: metadata,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:user_id, :achievement_key]
      )

    if count == 1, do: :awarded, else: :already
  end

  @doc """
  Awards a batch of `{key, tier, metadata}` and returns the list of keys that
  were **newly** awarded (the `:awarded` subset). Used by both the live seam and
  rebuild; re-running with an already-earned set returns `[]`.
  """
  @spec ensure_achievements(Ecto.UUID.t(), [{atom(), pos_integer(), map()}]) :: [atom()]
  def ensure_achievements(user_id, awards) do
    Enum.flat_map(awards, fn {key, tier, metadata} ->
      case award_achievement(user_id, key, tier, metadata) do
        :awarded -> [key]
        :already -> []
      end
    end)
  end

  @doc """
  Pure per-game rating update — the parity seam shared by the rerating job
  (PID-46) and live completion wiring (PID-47).

  Given one game's `player_results` map and `winner`, plus a `prior_ratings` map
  `%{user_id => {mu, sigma}}` for the participating users, returns
  `{:rated, updated_ratings}` where `updated_ratings` is `prior_ratings` with the
  four participants replaced by their new `{mu, sigma}`; or `:unrated` if the game
  does not satisfy `rated_game?/1`.

  Pure: no DB. Tolerates atom- or string-keyed JSONB `player_results`. Missing
  priors default to `Rating.default/0`. The caller owns where priors come from
  (rebuild: an in-memory accumulator; PID-47: the players' stored profile rows).

  Keys in the returned map keep the user-id form as it appears in
  `player_results` (string after a JSONB round-trip).
  """
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

  @doc """
  Wipes every profile's rating to `Rating.default/0` and recomputes it from the
  full `game_stats` history in a fixed total order, seeded from defaults.

  Deterministic and idempotent: re-running produces byte-identical
  `rating_mu`/`rating_sigma`/`rating_games_count`. Runs entirely inside one
  transaction (reset + replay + persist + cursor advance commit atomically).
  Returns `{:ok, %{profiles: persisted_count, games: rated_game_count}}`.
  """
  @spec rerate_all() :: {:ok, %{profiles: non_neg_integer(), games: non_neg_integer()}}
  def rerate_all do
    {default_mu, default_sigma} = Rating.default()

    Repo.transaction(fn ->
      # 1. Reset all ratings to the exact Rating.default/0 (not the rounded
      #    schema default) so replayed values and the accumulator seed match.
      Repo.update_all(PlayerProfile,
        set: [rating_mu: default_mu, rating_sigma: default_sigma, rating_games_count: 0]
      )

      # 2. Replay all games in a deterministic total order from an empty
      #    accumulator (each newly-seen user defaults inside rate_game/3).
      games = Repo.all(ordered_games_query())

      {acc, counts, last_game} =
        Enum.reduce(games, {%{}, %{}, nil}, fn game, {acc, counts, _last} ->
          {acc, counts} = replay_game(game, acc, counts)
          {acc, counts, game}
        end)

      # 3. Persist only touched users (untouched users already hold the reset
      #    default + count 0).
      persist_ratings(acc, counts, :overwrite_count)

      # 4. Advance / clear the cursor.
      set_cursor(last_game)

      %{profiles: map_size(acc), games: counts |> Map.values() |> Enum.sum() |> div(4)}
    end)
  end

  @doc """
  Applies only games completed strictly after the stored composite cursor, using
  the current stored profile ratings as priors, then advances the cursor.

  Equivalent to continuing the `rerate_all/0` accumulator from where it left off:
  the priors at the cursor are exactly the persisted post-cursor-game ratings.
  μ/σ are overwritten; `rating_games_count` is incremented (we are extending, not
  recomputing from zero). Runs inside one transaction.

  Assumes **monotonic `completed_at` arrival** — games are written in roughly
  completion order, so "after the cursor" is the genuinely-new set. A game that
  arrives out of order (a backfill with an old `completed_at`, or a same-second
  tie sorting before the cursor) is skipped; `rerate_all/0` is the authoritative
  repair and re-sorts and replays everything. Same drift-then-rebuild contract as
  the PID-44 counters. Returns `{:ok, %{games: rated_game_count}}`.

  ## Cursor-coherence contract (PID-47)

  Once the live completion path (`apply_completed_game/3`) is active, ratings move
  per game at completion time WITHOUT advancing this cursor (advancing one shared
  `rating_state` row per game-over would serialize every realtime completion on a
  single row lock). The cursor therefore reflects the last BATCH rerate, NOT live
  progress, and lags behind live game completions.

  Consequently `rerate_incremental/0` is a **backfill / repair tool**, not a
  steady-state job. It MUST NOT be run concurrently with (or after, against the
  same games as) live updates: it would re-apply games the live path already
  applied, double-moving μ/σ and double-counting `rating_games_count`.
  **`rerate_all/0` is the source-of-truth repair** once live updates are active —
  it wipes to `Rating.default/0` and replays the full history in total order,
  producing the canonical values regardless of any live/incremental drift.
  """
  @spec rerate_incremental() :: {:ok, %{games: non_neg_integer()}}
  def rerate_incremental do
    Repo.transaction(fn ->
      cursor = load_cursor()
      games = Repo.all(games_after_cursor_query(cursor))

      # Seed the accumulator from CURRENT stored profile ratings for the users
      # in this batch (unseen users default lazily inside rate_game/3).
      batch_user_ids =
        games
        |> Enum.flat_map(&participant_ids/1)
        |> Enum.uniq()

      acc = load_priors(batch_user_ids)

      {acc, counts, last_game} =
        Enum.reduce(games, {acc, %{}, nil}, fn game, {acc, counts, _last} ->
          {acc, counts} = replay_game(game, acc, counts)
          {acc, counts, game}
        end)

      persist_ratings(acc, counts, :increment_count)
      if last_game, do: set_cursor(last_game)

      %{games: counts |> Map.values() |> Enum.sum() |> div(4)}
    end)
  end

  # --- Private helpers ---

  # Pure rated-game predicate. A game is rated iff `player_results` has exactly
  # 4 distinct valid-UUID keys, split 2 per team. Returns
  # `{:ok, {{team_a, [ids]}, {team_b, [ids]}}}` (team strings) or `:error`.
  #
  # PID-47 owns the FINAL policy and may tighten this (e.g. exclude games with
  # any :abandoned / :substitute seat, or guest seats). It is a shared predicate:
  # both the live path and the rebuild must use the same one.
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

  defp team_of(%{team: team}), do: normalize_team(team)
  defp team_of(%{"team" => team}), do: normalize_team(team)
  defp team_of(_result), do: nil

  defp normalize_team(team) when is_atom(team) and not is_nil(team), do: Atom.to_string(team)
  defp normalize_team(team), do: team

  defp prior_for(prior_ratings, user_id) do
    Map.get(prior_ratings, user_id) || Rating.default()
  end

  defp zip_ratings(acc, ids, new_ratings) do
    ids
    |> Enum.zip(new_ratings)
    |> Enum.reduce(acc, fn {id, rating}, acc -> Map.put(acc, id, rating) end)
  end

  defp ordered_games_query do
    from(gs in GameStats, order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id])
  end

  defp games_after_cursor_query(nil), do: ordered_games_query()

  defp games_after_cursor_query({c_at, c_ins, c_id}) do
    from(gs in GameStats,
      where:
        gs.completed_at > ^c_at or
          (gs.completed_at == ^c_at and gs.inserted_at > ^c_ins) or
          (gs.completed_at == ^c_at and gs.inserted_at == ^c_ins and gs.id > ^c_id),
      order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
    )
  end

  # Apply one game through the shared step, bumping per-user counts on a rated
  # game and leaving acc/counts untouched on an unrated one.
  defp replay_game(game, acc, counts) do
    case rate_game(game.player_results, game.winner, acc) do
      {:rated, updated} ->
        counts =
          game
          |> participant_ids()
          |> Enum.reduce(counts, fn id, counts -> Map.update(counts, id, 1, &(&1 + 1)) end)

        {updated, counts}

      :unrated ->
        {acc, counts}
    end
  end

  # The valid-UUID participant ids of a rated game (empty list for unrated).
  defp participant_ids(game) do
    case rated_game?(game.player_results) do
      {:ok, {{_team_a, members_a}, {_team_b, members_b}}} -> members_a ++ members_b
      :error -> []
    end
  end

  # Live per-game rating move (PID-47): one rerate_incremental/0-shaped step.
  # Reads the four participants' stored priors, rates via the shared rate_game/3,
  # and on a rated game overwrites μ/σ + increments rating_games_count by 1 for
  # exactly those four ids. On :unrated, nothing is written.
  #
  # Surfaces (PID-52) the per-user after-rating + after-count as
  # `%{user_id => %{after: {mu, sigma}, count_after: n}}` (empty map on
  # :unrated) so the summary can classify the tier move without re-reading.
  defp apply_live_rating(player_results, winner) do
    ids = participant_ids(%{player_results: player_results})
    priors = load_priors(ids)

    case rate_game(player_results, winner, priors) do
      {:rated, updated} ->
        # Restrict the persist to the four rated participants so rate_game/3's
        # carried-through non-participant priors are never re-written.
        acc = Map.take(updated, ids)
        counts = Map.new(ids, &{&1, 1})
        persist_ratings(acc, counts, :increment_count)

        counts_after =
          from(p in PlayerProfile,
            where: p.user_id in ^ids,
            select: {p.user_id, p.rating_games_count}
          )
          |> Repo.all()
          |> Map.new()

        Map.new(ids, fn id ->
          {id, %{after: Map.fetch!(acc, id), count_after: Map.get(counts_after, id, 1)}}
        end)

      :unrated ->
        %{}
    end
  end

  # Live achievements (PID-50). For each valid-UUID participant: build the ctx
  # from the post-update aggregates (re-read in this txn), this game's view, and
  # the user's ordered history (incl. this game — already inserted earlier in
  # this transaction), evaluate active defs, and idempotent-upsert. Returns the
  # per-user newly-earned keys as `%{user_id => [key]}`.
  defp apply_live_achievements(player_results, scores) do
    player_results
    |> Enum.reduce(%{}, fn {user_id, result}, acc ->
      case Ecto.UUID.cast(user_id) do
        {:ok, valid_id} ->
          aggregates =
            Repo.one(
              from p in PlayerProfile,
                where: p.user_id == ^valid_id,
                select: %{games_played: p.games_played, wins: p.wins}
            ) || %{games_played: 0, wins: 0}

          this_game = live_game_view(player_results, scores, result)

          ctx = %{
            user_id: valid_id,
            aggregates: aggregates,
            this_game: this_game,
            history: ordered_history_views(valid_id)
          }

          newly =
            ctx
            |> Achievements.evaluate_active()
            |> then(&ensure_achievements(valid_id, &1))

          if newly == [], do: acc, else: Map.put(acc, valid_id, newly)

        :error ->
          acc
      end
    end)
  end

  # The user's full ordered history as `game_view`s, in the canonical total
  # order — the same order rebuild_from_history/1 uses, so the streak evaluator
  # sees an identical sequence in both paths.
  defp ordered_history_views(user_id) do
    from(gs in GameStats,
      where: ^user_id in gs.player_ids,
      order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
    )
    |> Repo.all()
    |> Enum.map(&history_game_view(&1, user_id))
  end

  # Build a normalized game_view from the live in-scope data for one participant.
  defp live_game_view(player_results, scores, result) do
    team = team_from_result(result)
    won? = win_from_result?(result)
    team_score = score_for_team(scores, team)
    opponent_score = score_for_team(scores, opponent_team(team))

    %{
      won?: won?,
      team_score: team_score,
      opponent_score: opponent_score,
      partnered_win?: won? and match?({:ok, _}, rated_game?(player_results))
    }
  end

  # Build a normalized game_view from a persisted GameStats row for one user,
  # reusing the same tolerant team/score/result helpers the counters use.
  defp history_game_view(%GameStats{} = game, user_id) do
    team = team_for_user(game, user_id)
    won? = won_game?(game, user_id)
    team_score = score_for_team(game.final_scores, team)
    opponent_score = score_for_team(game.final_scores, opponent_team(team))

    %{
      won?: won?,
      team_score: team_score,
      opponent_score: opponent_score,
      partnered_win?: won? and match?({:ok, _}, rated_game?(game.player_results))
    }
  end

  defp opponent_team(team) do
    case normalize_team(team) do
      "north_south" -> "east_west"
      "east_west" -> "north_south"
      _ -> nil
    end
  end

  @doc """
  Loads stored `{mu, sigma}` priors for the given user ids as a
  `%{user_id => {mu, sigma}}` map. Pure read; creates no rows. Shared by the
  incremental rerate job and the live completion path so both see identical
  priors-at-this-game.

  Only users who have actually been RATED (`rating_games_count > 0`) contribute a
  prior. Users with no row — or a lazily-created counter-only row that has never
  been rated — are omitted, so callers default them to the EXACT `Rating.default/0`
  inside `rate_game/3`. This is what makes the live path identical-by-construction
  to a from-scratch `rerate_all/0`: the rounded schema-default `rating_sigma`
  (8.333) on an unrated row never leaks in as a prior in place of `Rating.default/0`
  (8.333…).
  """
  @spec load_priors([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => rating()}
  def load_priors(user_ids) do
    from(p in PlayerProfile,
      where: p.user_id in ^user_ids and p.rating_games_count > 0,
      select: {p.user_id, p.rating_mu, p.rating_sigma}
    )
    |> Repo.all()
    |> Map.new(fn {user_id, mu, sigma} -> {user_id, {mu, sigma}} end)
  end

  # Overwrite each touched user's μ/σ; either overwrite the count (full rebuild)
  # or increment it (incremental). Lazily creates a profile row if absent.
  defp persist_ratings(acc, counts, count_mode) do
    Enum.each(acc, fn {user_id, {mu, sigma}} ->
      {:ok, _profile} = get_or_create_profile(user_id)
      count = Map.get(counts, user_id, 0)

      set =
        case count_mode do
          :overwrite_count -> [rating_mu: mu, rating_sigma: sigma, rating_games_count: count]
          :increment_count -> [rating_mu: mu, rating_sigma: sigma]
        end

      query = from(p in PlayerProfile, where: p.user_id == ^user_id)

      case count_mode do
        :overwrite_count -> Repo.update_all(query, set: set)
        :increment_count -> Repo.update_all(query, set: set, inc: [rating_games_count: count])
      end
    end)
  end

  # --- Cursor ---

  defp load_cursor do
    case Repo.get(RatingState, RatingState.singleton_id()) do
      %RatingState{last_completed_at: nil} ->
        nil

      %RatingState{last_game_id: nil} ->
        nil

      %RatingState{} = state ->
        {state.last_completed_at, state.last_inserted_at, state.last_game_id}

      nil ->
        nil
    end
  end

  defp set_cursor(nil) do
    upsert_cursor(%{last_completed_at: nil, last_inserted_at: nil, last_game_id: nil})
  end

  defp set_cursor(%GameStats{} = game) do
    upsert_cursor(%{
      last_completed_at: game.completed_at,
      last_inserted_at: game.inserted_at,
      last_game_id: game.id
    })
  end

  defp upsert_cursor(attrs) do
    state =
      Repo.get(RatingState, RatingState.singleton_id()) ||
        %RatingState{id: RatingState.singleton_id()}

    state
    |> RatingState.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp apply_one(user_id, won?) do
    {:ok, _profile} = get_or_create_profile(user_id)

    increments =
      if won? do
        [games_played: 1, wins: 1]
      else
        [games_played: 1, losses: 1]
      end

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(inc: increments)

    :ok
  end

  # Live XP writer (PID-49), inside the surrounding completion transaction.
  # Increments veteran_xp by the per-game award, then recomputes the
  # veteran_level cache from the post-inc total. The XP inc is commutative; the
  # level set is a pure function of the new XP. Surfaces the per-game delta +
  # after-total so the summary (PID-52) needs no re-read.
  defp apply_xp(user_id, result, scores) do
    won? = win_from_result?(result)
    team_score = team_score_for(result, scores)
    delta = Progression.xp_for_game(team_score, won?)
    {:ok, _profile} = get_or_create_profile(user_id)

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(inc: [veteran_xp: delta])

    new_xp =
      Repo.one(from p in PlayerProfile, where: p.user_id == ^user_id, select: p.veteran_xp)

    from(p in PlayerProfile, where: p.user_id == ^user_id)
    |> Repo.update_all(set: [veteran_level: Progression.level_for_xp(new_xp)])

    %{xp_earned: delta, veteran_xp_after: new_xp}
  end

  # Live playstyle writer (PID-51), inside the surrounding completion
  # transaction. Folds one game's per-user bidding facts into the four
  # accumulators (commutative per-game sums → live == rebuild). A nil/absent
  # facts map (no bidding facts for this user) is a no-op.
  defp apply_playstyle(_user_id, nil), do: :ok

  defp apply_playstyle(user_id, facts) when is_map(facts) do
    %{attempts: attempts, wins: wins, won_bid_sum: won_bid_sum} = playstyle_facts(facts)

    if attempts == 0 and wins == 0 and won_bid_sum == 0 do
      :ok
    else
      {:ok, _profile} = get_or_create_profile(user_id)

      from(p in PlayerProfile, where: p.user_id == ^user_id)
      |> Repo.update_all(
        inc: [
          playstyle_bidding_attempts: attempts,
          playstyle_bidding_wins: wins,
          avg_winning_bid_sum: won_bid_sum,
          # wins == won-bid count, so the avg's count accumulator is fed from wins.
          avg_winning_bid_count: wins
        ]
      )
    end

    :ok
  end

  defp apply_playstyle(_user_id, _facts), do: :ok

  # Resolve a user's per-game bidding facts from the player_bidding map,
  # tolerating atom (just-built) or string (JSONB round-trip) user-id keys.
  defp bidding_facts_for(player_bidding, user_id) when is_map(player_bidding) do
    Map.get(player_bidding, user_id) || Map.get(player_bidding, to_string(user_id))
  end

  defp bidding_facts_for(_player_bidding, _user_id), do: nil

  # Normalize a per-user facts map (atom- or string-keyed; missing/non-integer
  # → 0) into the three accumulator deltas.
  defp playstyle_facts(facts) when is_map(facts) do
    %{
      attempts: facts_int(facts, :attempts, "attempts"),
      wins: facts_int(facts, :wins, "wins"),
      won_bid_sum: facts_int(facts, :won_bid_sum, "won_bid_sum")
    }
  end

  defp facts_int(facts, atom_key, string_key) do
    value = Map.get(facts, atom_key) || Map.get(facts, string_key)
    if is_integer(value), do: value, else: 0
  end

  # Per-game XP contribution for the rebuild: reuses won_game?/2 for the win
  # bonus and reads the user's team score from the stored final_scores
  # (string-keyed JSONB tolerant). Legacy rows missing a team's score floor to 0.
  defp xp_for_history_game(%GameStats{} = game, user_id) do
    won? = won_game?(game, user_id)
    team = team_for_user(game, user_id)
    team_score = score_for_team(game.final_scores, team)
    Progression.xp_for_game(team_score, won?)
  end

  # Live path: read scores[result.team], tolerating atom/string keys on both the
  # result map's team and the scores map. Defaults to 0 when absent.
  defp team_score_for(result, scores) do
    score_for_team(scores, team_from_result(result))
  end

  defp team_from_result(%{team: team}), do: team
  defp team_from_result(%{"team" => team}), do: team
  defp team_from_result(_result), do: nil

  # Rebuild path: the user's team from the stored result, with the same
  # position-vs-player_ids fallback won_game?/2 uses for legacy rows.
  defp team_for_user(game, user_id) do
    case get_player_result(game, user_id) do
      %{team: team} ->
        team

      %{"team" => team} ->
        team

      _ ->
        case get_player_position(game, user_id) do
          pos when pos in [:north, :south] -> :north_south
          pos when pos in [:east, :west] -> :east_west
          _ -> nil
        end
    end
  end

  # Tolerant team-score read: atom OR string team key against an atom- OR
  # string-keyed scores map. Non-integer / absent values floor to 0.
  defp score_for_team(scores, team) when is_map(scores) and not is_nil(team) do
    value =
      Map.get(scores, team) ||
        Map.get(scores, to_string(team)) ||
        atom_keyed_score(scores, team)

    if is_integer(value), do: value, else: 0
  end

  defp score_for_team(_scores, _team), do: 0

  # When `team` is a string (JSONB result) but `scores` is atom-keyed (in-memory).
  defp atom_keyed_score(scores, team) when is_binary(team) do
    case safe_existing_atom(team) do
      {:ok, atom} -> Map.get(scores, atom)
      :error -> nil
    end
  end

  defp atom_keyed_score(_scores, _team), do: nil

  defp safe_existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  # Incremental path: atom-keyed in-memory result map built by
  # Stats.build_player_results/3.
  defp win_from_result?(%{result: :win}), do: true
  defp win_from_result?(%{result: "win"}), do: true
  defp win_from_result?(%{"result" => "win"}), do: true
  defp win_from_result?(%{"result" => :win}), do: true
  defp win_from_result?(_result), do: false

  # Rebuild path: persisted GameStats with string-keyed JSONB player_results.
  # An explicitly-stored result (win OR loss) is authoritative; only rows with
  # NO recorded result (legacy rows written before player_results existed) fall
  # back to position-vs-winner inference. The fallback relies on player_ids
  # order, which is unreliable for modern rows whose player_ids come from an
  # unordered map — so it must never be reached when a result is present.
  defp won_game?(%GameStats{} = game, user_id) do
    case get_player_result(game, user_id) do
      %{result: :win} -> true
      %{"result" => "win"} -> true
      %{result: :loss} -> false
      %{"result" => "loss"} -> false
      _ -> won_game_by_position?(game, user_id)
    end
  end

  defp won_game_by_position?(%GameStats{} = game, user_id) do
    winner = game.winner
    position = get_player_position(game, user_id)

    case {winner, position} do
      {:north_south, pos} when pos in [:north, :south] -> true
      {:east_west, pos} when pos in [:east, :west] -> true
      {"north_south", pos} when pos in [:north, :south] -> true
      {"east_west", pos} when pos in [:east, :west] -> true
      _ -> false
    end
  end

  defp get_player_result(%{player_results: player_results}, user_id)
       when is_map(player_results) do
    Map.get(player_results, user_id) || Map.get(player_results, to_string(user_id))
  end

  defp get_player_result(_game, _user_id), do: nil

  defp get_player_position(game, user_id) do
    player_ids = game.player_ids || []

    case Enum.find_index(player_ids, &(&1 == user_id)) do
      0 -> :north
      1 -> :east
      2 -> :south
      3 -> :west
      _ -> nil
    end
  end

  defp win_rate(_wins, 0), do: 0.0
  defp win_rate(wins, games_played), do: wins / games_played

  defp first_seen_at(user_id) do
    case Repo.get(User, user_id) do
      %User{inserted_at: inserted_at} -> inserted_at
      nil -> nil
    end
  end

  defp account_age_days(nil), do: nil

  defp account_age_days(%DateTime{} = first_seen_at) do
    DateTime.diff(DateTime.utc_now(), first_seen_at, :day)
  end
end
