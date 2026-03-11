defmodule PidroServer.Stats do
  @moduledoc """
  Context for game statistics and analytics.
  Handles saving game results and aggregating user stats.
  """

  require Logger
  import Ecto.Query, warn: false
  alias PidroServer.Repo
  alias PidroServer.Stats.{AbandonmentEvent, GameStats}

  @doc """
  Saves game result after completion.

  ## Examples

      iex> save_game_result(%{room_code: "ABC123", winner: :north_south, ...})
      {:ok, %GameStats{}}

      iex> save_game_result(%{})
      {:error, %Ecto.Changeset{}}
  """
  def save_game_result(attrs) do
    %GameStats{}
    |> GameStats.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets stats for a specific user.

  Returns aggregated statistics including:
  - Total games played
  - Wins/losses
  - Average bid amount
  - Total duration played

  ## Examples

      iex> get_user_stats(user_id)
      %{
        games_played: 42,
        wins: 25,
        losses: 17,
        win_rate: 0.595,
        total_duration_seconds: 12600,
        average_bid: 10.5
      }
  """
  def get_user_stats(user_id) do
    games_query =
      from gs in GameStats,
        where: ^user_id in gs.player_ids,
        select: gs

    games = Repo.all(games_query)
    games_abandoned = count_abandonments(user_id)
    last_abandoned_at = last_abandoned_at(user_id)

    total_games = length(games)
    wins = count_user_wins(games, user_id)
    losses = total_games - wins
    total_duration = Enum.reduce(games, 0, fn g, acc -> acc + (g.duration_seconds || 0) end)
    total_bids = Enum.reduce(games, 0, fn g, acc -> acc + (g.bid_amount || 0) end)
    avg_bid = if total_games > 0, do: total_bids / total_games, else: 0.0

    %{
      games_played: total_games,
      wins: wins,
      losses: losses,
      win_rate: if(total_games > 0, do: wins / total_games, else: 0.0),
      total_duration_seconds: total_duration,
      average_bid: avg_bid,
      games_abandoned: games_abandoned,
      abandonment_rate: if(total_games > 0, do: games_abandoned / total_games, else: 0.0),
      last_abandoned_at: last_abandoned_at
    }
  end

  @doc """
  Gets all game stats for a room code.
  """
  def get_game_by_room_code(room_code) do
    Repo.get_by(GameStats, room_code: room_code)
  end

  @doc """
  Lists recent games, optionally filtered by player.
  """
  def list_recent_games(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    player_id = Keyword.get(opts, :player_id)

    query =
      from gs in GameStats,
        order_by: [desc: gs.completed_at],
        limit: ^limit

    query =
      if player_id do
        from gs in query,
          where: ^player_id in gs.player_ids
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets leaderboard stats.
  Returns top players by win count.
  """
  def get_leaderboard(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    # This is a simplified version - in production you'd want to
    # maintain a separate leaderboard table or use more efficient queries
    query =
      from gs in GameStats,
        select: gs

    games = Repo.all(query)

    # Group by player and count wins
    player_stats =
      games
      |> Enum.flat_map(fn game ->
        Enum.map(game.player_ids || [], fn player_id ->
          {player_id, game}
        end)
      end)
      |> Enum.group_by(fn {player_id, _game} -> player_id end)
      |> Enum.map(fn {player_id, player_games} ->
        games_list = Enum.map(player_games, fn {_id, game} -> game end)
        wins = count_user_wins(games_list, player_id)

        %{
          player_id: player_id,
          games_played: length(games_list),
          wins: wins,
          win_rate: if(length(games_list) > 0, do: wins / length(games_list), else: 0.0)
        }
      end)
      |> Enum.sort_by(& &1.wins, :desc)
      |> Enum.take(limit)

    player_stats
  end

  @doc """
  Builds per-player results from seat data at game completion.

  Iterates through all seats and classifies each player's participation:

    * Connected human → `:played`
    * Bot with `reserved_for` set (abandoned human) → `:abandoned`
    * Bot without `reserved_for` (pure bot) → skipped
    * Human who joined as substitute → `:substitute` (Phase 8)

  Returns a map of `%{user_id => %{participation, result, team, position}}`.
  """
  @spec build_player_results(map(), atom(), [AbandonmentEvent.t() | map()]) :: map()
  def build_player_results(seats, winner, abandonment_events \\ [])

  def build_player_results(seats, winner, abandonment_events)
      when is_map(seats) and is_list(abandonment_events) do
    seats
    |> Enum.reduce(%{}, fn {position, seat}, acc ->
      case classify_seat(seat) do
        {:record, user_id, participation} ->
          Map.put(acc, user_id, build_result(participation, position, winner))

        :skip ->
          acc
      end
    end)
    |> merge_abandonment_events(abandonment_events, winner)
  end

  def build_player_results(_seats, _winner, _abandonment_events), do: %{}

  @doc """
  Records a player abandonment when Phase 3 fires.

  Called when a disconnected player's seat becomes permanently bot-filled
  (grace period expired without reconnection). Logs the abandonment event
  for observability.

  This data will be used for matchmaking penalties and profile badges
  in a future phase.

  ## Parameters

    * `user_id` - The ID of the player who abandoned the game
    * `room_code` - The room code where the abandonment occurred
    * `position` - The seat position that was abandoned
  """
  @spec record_abandonment(String.t(), String.t(), atom()) :: :ok
  def record_abandonment(user_id, room_code, position) do
    attrs = %{
      user_id: user_id,
      room_code: room_code,
      position: Atom.to_string(position)
    }

    %AbandonmentEvent{}
    |> AbandonmentEvent.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :room_code]
    )

    Logger.info("Abandonment recorded: user=#{user_id} room=#{room_code} position=#{position}")

    :ok
  end

  @doc """
  Persists the final game result exactly once for a finished room.
  """
  @spec save_completed_game(map(), atom(), map(), map() | nil) :: :ok
  def save_completed_game(%{code: room_code} = room, winner, scores, game_state \\ nil) do
    case Repo.get_by(GameStats, room_code: room_code) do
      %GameStats{} ->
        :ok

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

        case save_game_result(stats_attrs) do
          {:ok, _stats} ->
            Logger.info("Saved game stats for room #{room_code}")
            :ok

          {:error, changeset} ->
            Logger.error("Failed to save game stats for room #{room_code}: #{inspect(changeset)}")
            :ok
        end
    end
  end

  @doc """
  Lists abandonment events for a completed room.
  """
  @spec list_abandonments_for_room(String.t()) :: [AbandonmentEvent.t()]
  def list_abandonments_for_room(room_code) do
    from(ae in AbandonmentEvent,
      where: ae.room_code == ^room_code,
      order_by: [asc: ae.inserted_at]
    )
    |> Repo.all()
  end

  # Private helpers

  defp count_abandonments(user_id) do
    from(ae in AbandonmentEvent, where: ae.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  defp last_abandoned_at(user_id) do
    from(ae in AbandonmentEvent, where: ae.user_id == ^user_id, select: max(ae.inserted_at))
    |> Repo.one()
    |> to_utc_datetime()
  end

  defp classify_seat(%{
         occupant_type: :human,
         status: :connected,
         substitute: true,
         user_id: user_id
       })
       when not is_nil(user_id) do
    {:record, user_id, :substitute}
  end

  defp classify_seat(%{occupant_type: :human, status: :connected, user_id: user_id})
       when not is_nil(user_id) do
    {:record, user_id, :played}
  end

  defp classify_seat(%{occupant_type: :bot, reserved_for: reserved_for})
       when not is_nil(reserved_for) do
    # Abandoned human — bot is playing but the original human can still reclaim
    {:record, reserved_for, :abandoned}
  end

  defp classify_seat(_seat), do: :skip

  defp build_result(participation, position, winner) do
    team = team_for_position(position)
    result = if team == winner, do: :win, else: :loss

    %{
      participation: participation,
      result: result,
      team: team,
      position: position
    }
  end

  defp merge_abandonment_events(results, abandonment_events, winner) do
    Enum.reduce(abandonment_events, results, fn event, acc ->
      case normalize_abandonment_event(event) do
        {:ok, user_id, position} ->
          Map.put_new(acc, user_id, build_result(:abandoned, position, winner))

        :error ->
          acc
      end
    end)
  end

  defp normalize_abandonment_event(%AbandonmentEvent{user_id: user_id, position: position}) do
    normalize_abandonment_event(%{user_id: user_id, position: position})
  end

  defp normalize_abandonment_event(%{user_id: user_id, position: position})
       when is_binary(user_id) do
    case normalize_position(position) do
      {:ok, position_atom} -> {:ok, user_id, position_atom}
      :error -> :error
    end
  end

  defp normalize_abandonment_event(_event), do: :error

  defp normalize_position(position) when position in [:north, :east, :south, :west],
    do: {:ok, position}

  defp normalize_position("north"), do: {:ok, :north}
  defp normalize_position("east"), do: {:ok, :east}
  defp normalize_position("south"), do: {:ok, :south}
  defp normalize_position("west"), do: {:ok, :west}
  defp normalize_position(_position), do: :error

  defp team_for_position(position) when position in [:north, :south], do: :north_south
  defp team_for_position(position) when position in [:east, :west], do: :east_west

  defp extract_bid_info(%{highest_bid: {position, amount}})
       when position in [:north, :east, :south, :west] and is_integer(amount) do
    %{bid_amount: amount, bid_team: team_for_position(position)}
  end

  defp extract_bid_info(%{highest_bid: %{position: position, amount: amount}})
       when is_integer(amount) do
    case normalize_position(position) do
      {:ok, position_atom} ->
        %{bid_amount: amount, bid_team: team_for_position(position_atom)}

      :error ->
        %{bid_amount: nil, bid_team: nil}
    end
  end

  defp extract_bid_info(_game_state), do: %{bid_amount: nil, bid_team: nil}

  defp to_utc_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp to_utc_datetime(%DateTime{} = datetime), do: datetime
  defp to_utc_datetime(nil), do: nil

  defp count_user_wins(games, user_id) do
    Enum.count(games, fn game ->
      case get_player_result(game, user_id) do
        %{result: :win} ->
          true

        _ ->
          winner = game.winner
          player_position = get_player_position(game, user_id)

          case {winner, player_position} do
            {:north_south, pos} when pos in [:north, :south] -> true
            {:east_west, pos} when pos in [:east, :west] -> true
            {"north_south", pos} when pos in [:north, :south] -> true
            {"east_west", pos} when pos in [:east, :west] -> true
            _ -> false
          end
      end
    end)
  end

  defp get_player_result(%{player_results: player_results}, user_id)
       when is_map(player_results) do
    Map.get(player_results, user_id) || Map.get(player_results, to_string(user_id))
  end

  defp get_player_result(_game, _user_id), do: nil

  defp get_player_position(game, user_id) do
    player_ids = game.player_ids || []
    index = Enum.find_index(player_ids, &(&1 == user_id))

    case index do
      0 -> :north
      1 -> :east
      2 -> :south
      3 -> :west
      _ -> nil
    end
  end
end
