defmodule PidroServer.Stats do
  @moduledoc """
  Context for game statistics and analytics.
  Handles saving game results and aggregating user stats.
  """

  import Ecto.Query, warn: false
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

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

    total_games = length(games)

    if total_games == 0 do
      %{
        games_played: 0,
        wins: 0,
        losses: 0,
        win_rate: 0.0,
        total_duration_seconds: 0,
        average_bid: 0.0
      }
    else
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
        average_bid: avg_bid
      }
    end
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

  # Private helpers

  defp count_user_wins(games, user_id) do
    Enum.count(games, fn game ->
      winner = game.winner
      player_position = get_player_position(game, user_id)

      case {winner, player_position} do
        {:north_south, pos} when pos in [:north, :south] -> true
        {:east_west, pos} when pos in [:east, :west] -> true
        _ -> false
      end
    end)
  end

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
