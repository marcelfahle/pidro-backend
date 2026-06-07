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
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

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
         veteran_level: profile.veteran_level,
         veteran_xp: profile.veteran_xp,
         playstyle_bidding_wins: profile.playstyle_bidding_wins,
         playstyle_bidding_attempts: profile.playstyle_bidding_attempts,
         avg_winning_bid: average(profile.avg_winning_bid_sum, profile.avg_winning_bid_count),
         heritage_flags: profile.heritage_flags,
         first_seen_at: first_seen_at,
         account_age_days: account_age_days(first_seen_at)
       }}
    end
  end

  @doc """
  Applies one completed game to the set of participating users' profiles.

  Increments `games_played` and either `wins` or `losses` per the per-user
  result. Called once per newly-inserted `game_stats` row, from inside the
  `Stats` write path's transaction. Bots are already excluded by the caller
  (they never appear in `player_results`). Ids that are not valid UUIDs are
  logged and skipped rather than crashing the surrounding transaction.
  """
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

  def apply_completed_game(_player_results, _winner), do: :ok

  @doc """
  Recomputes a single user's lifetime counters from `game_stats` history and
  overwrites them.

  Idempotent; reproduces exactly what the incremental path would have produced.
  Tolerates string-keyed JSONB `player_results` on persisted rows.
  """
  @spec rebuild_from_history(Ecto.UUID.t()) ::
          {:ok, PlayerProfile.t()} | {:error, term()}
  def rebuild_from_history(user_id) do
    games =
      from(gs in GameStats, where: ^user_id in gs.player_ids)
      |> Repo.all()

    games_played = length(games)
    wins = Enum.count(games, &won_game?(&1, user_id))
    losses = games_played - wins

    with {:ok, profile} <- get_or_create_profile(user_id) do
      profile
      |> PlayerProfile.changeset(%{
        games_played: games_played,
        wins: wins,
        losses: losses
      })
      |> Repo.update()
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

  # --- Private helpers ---

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

  # Incremental path: atom-keyed in-memory result map built by
  # Stats.build_player_results/3.
  defp win_from_result?(%{result: :win}), do: true
  defp win_from_result?(%{result: "win"}), do: true
  defp win_from_result?(%{"result" => "win"}), do: true
  defp win_from_result?(%{"result" => :win}), do: true
  defp win_from_result?(_result), do: false

  # Rebuild path: persisted GameStats with string-keyed JSONB player_results.
  # Mirrors Stats.count_user_wins/2 — read the stored result, falling back to
  # position-vs-winner inference for historical rows written before
  # player_results existed.
  defp won_game?(%GameStats{} = game, user_id) do
    case get_player_result(game, user_id) do
      %{result: :win} ->
        true

      %{"result" => "win"} ->
        true

      _ ->
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

  defp average(_sum, 0), do: 0.0
  defp average(sum, count), do: sum / count

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
