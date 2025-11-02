defmodule PidroServerWeb.API.UserController do
  @moduledoc """
  API controller for user-related operations.

  This controller handles user-specific functionality including statistics
  and user data retrieval. All endpoints are protected and require authentication
  via Bearer token in the Authorization header.

  ## Authentication

  All endpoints in this controller require a valid Bearer token in the
  Authorization header. Tokens are validated via the Authenticate plug.

  ## OpenAPI Documentation

  This controller includes OpenAPI 3.0 specifications for all endpoints:
  - GET /api/v1/users/me/stats - Get current user's game statistics

  All endpoints are tagged with "Users" in the OpenAPI specification.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Stats
  alias PidroServerWeb.Schemas.{UserSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Users"])

  operation(:stats,
    summary: "Get current user's game statistics",
    description: """
    Retrieves aggregated game statistics for the currently authenticated user.

    This endpoint requires authentication. The Bearer token must be included
    in the Authorization header: `Authorization: Bearer <token>`

    Returns comprehensive statistics including:
    - Total games played
    - Total wins and losses
    - Win rate (as a decimal from 0.0 to 1.0)
    - Total time spent playing (in seconds)
    - Average bid amount across all games

    All statistics are calculated from the user's complete game history and
    updated in real-time based on their participation in games.

    ## Error Responses
    - Returns 401 Unauthorized if token is missing, invalid, or expired
    """,
    security: [%{"bearer" => []}],
    responses: [
      ok:
        {"User statistics retrieved successfully", "application/json",
         UserSchemas.UserStatsResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()}
    ]
  )

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
