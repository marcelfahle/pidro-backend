defmodule PidroServerWeb.API.UserController do
  @moduledoc """
  Controller for user-related endpoints.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Stats

  action_fallback PidroServerWeb.API.FallbackController

  @doc """
  Get current user's game statistics.

  Returns aggregated stats including:
  - Total games played
  - Wins/losses
  - Win rate
  - Total duration played
  - Average bid amount

  ## Examples

      GET /api/v1/users/me/stats
      Authorization: Bearer <token>

      Response:
      {
        "data": {
          "games_played": 42,
          "wins": 25,
          "losses": 17,
          "win_rate": 0.595,
          "total_duration_seconds": 12600,
          "average_bid": 10.5
        }
      }
  """
  def stats(conn, _params) do
    user_id = conn.assigns.current_user.id
    stats = Stats.get_user_stats(user_id)

    conn
    |> put_status(:ok)
    |> json(%{data: stats})
  end
end
