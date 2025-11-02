defmodule PidroServerWeb.Api.RoomController do
  @moduledoc """
  API controller for game room operations.

  This controller handles all room-related endpoints including listing rooms,
  creating new rooms, retrieving room details, and managing player join/leave
  operations. All operations are delegated to the RoomManager GenServer for
  centralized state management.

  ## Authentication

  The following endpoints require authentication (valid Bearer token):
  - `create/2` - Creating a room requires the current user
  - `join/2` - Joining a room requires the current user
  - `leave/2` - Leaving a room requires the current user

  Unauthenticated endpoints:
  - `index/2` - Listing rooms is publicly available
  - `show/2` - Viewing room details is publicly available

  ## Error Handling

  All errors are delegated to the FallbackController for centralized error
  handling. Common error responses include:
  - `{:error, :room_not_found}` - Room code doesn't exist (404)
  - `{:error, :room_full}` - Room already has 4 players (422)
  - `{:error, :already_in_room}` - Player is already in another room (422)
  - `{:error, :not_in_room}` - Player is not in any room (404)
  """

  use PidroServerWeb, :controller

  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.Api.RoomJSON

  action_fallback PidroServerWeb.Api.FallbackController

  @doc """
  Lists all rooms with optional filtering.

  Retrieves a list of available rooms from the RoomManager. The response can be
  filtered using a query parameter to show only waiting or ready rooms.

  This endpoint is publicly accessible and does not require authentication.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters:
      - `filter` - Optional filter parameter ("waiting", "ready", or "all"). Defaults to "all".

  ## Query Examples

      GET /api/v1/rooms
      GET /api/v1/rooms?filter=waiting
      GET /api/v1/rooms?filter=ready

  ## Response Example (Success)

      {
        "data": {
          "rooms": [
            {
              "code": "A1B2",
              "host_id": "user123",
              "player_ids": ["user123", "user456"],
              "status": "waiting",
              "max_players": 4,
              "created_at": "2024-11-02T10:30:00Z"
            },
            {
              "code": "X9Z8",
              "host_id": "user789",
              "player_ids": ["user789"],
              "status": "waiting",
              "max_players": 4,
              "created_at": "2024-11-02T10:35:00Z"
            }
          ]
        }
      }
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    filter = parse_filter(params["filter"])
    rooms = RoomManager.list_rooms(filter)

    conn
    |> put_view(RoomJSON)
    |> render(:index, %{rooms: rooms})
  end

  @doc """
  Creates a new game room.

  Creates a new room with the authenticated user as the host. The room is created
  in a "waiting" status and is immediately joinable by other players. The response
  includes the newly created room's details and unique room code.

  Requires authentication via Bearer token.

  Returns HTTP 201 (Created) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `params` - Request parameters:
      - `room` - Optional nested object with:
        - `name` - Room name (optional)

  ## Headers Required

      Authorization: Bearer <token>

  ## Request Body Example

      {
        "room": {
          "name": "Fun Game Night"
        }
      }

  ## Response Example (Success)

      {
        "data": {
          "room": {
            "code": "A1B2",
            "host_id": "user123",
            "player_ids": ["user123"],
            "status": "waiting",
            "max_players": 4,
            "created_at": "2024-11-02T10:30:00Z"
          },
          "code": "A1B2"
        }
      }

  ## Response Example (Error - Already in room)

      {
        "errors": [
          {
            "code": "ALREADY_IN_ROOM",
            "title": "Already in room",
            "detail": "User is already in another room"
          }
        ]
      }
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    user = conn.assigns[:current_user]
    metadata = parse_metadata(params["room"])

    with {:ok, room} <- RoomManager.create_room(user.id, metadata) do
      conn
      |> put_status(:created)
      |> put_view(RoomJSON)
      |> render(:created, %{room: room})
    end
  end

  @doc """
  Retrieves details of a specific room.

  Gets the current state of a room including player list, host information, and
  room status. This endpoint is publicly accessible and does not require authentication.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Route Example

      GET /api/v1/rooms/A1B2

  ## Response Example (Success)

      {
        "data": {
          "room": {
            "code": "A1B2",
            "host_id": "user123",
            "player_ids": ["user123", "user456", "user789"],
            "status": "waiting",
            "max_players": 4,
            "created_at": "2024-11-02T10:30:00Z"
          }
        }
      }

  ## Response Example (Error - Not Found)

      {
        "errors": [
          {
            "code": "NOT_FOUND",
            "title": "Not found",
            "detail": "Resource not found"
          }
        ]
      }
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"code" => code}) do
    with {:ok, room} <- RoomManager.get_room(code) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Joins an existing room.

  Adds the authenticated player to a room. The player can only be in one room
  at a time. When the 4th player joins, the room status automatically changes to
  "ready" and the game starts.

  Requires authentication via Bearer token.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Headers Required

      Authorization: Bearer <token>

  ## Route Example

      POST /api/v1/rooms/A1B2/join

  ## Response Example (Success)

      {
        "data": {
          "room": {
            "code": "A1B2",
            "host_id": "user123",
            "player_ids": ["user123", "user456"],
            "status": "waiting",
            "max_players": 4,
            "created_at": "2024-11-02T10:30:00Z"
          }
        }
      }

  ## Response Example (Error - Room Full)

      {
        "errors": [
          {
            "code": "ROOM_FULL",
            "title": "Room full",
            "detail": "Room already has 4 players"
          }
        ]
      }

  ## Response Example (Error - Room Not Found)

      {
        "errors": [
          {
            "code": "NOT_FOUND",
            "title": "Not found",
            "detail": "Resource not found"
          }
        ]
      }

  ## Response Example (Error - Already in Room)

      {
        "errors": [
          {
            "code": "ALREADY_IN_ROOM",
            "title": "Already in room",
            "detail": "User is already in another room"
          }
        ]
      }
  """
  @spec join(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def join(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    with {:ok, room} <- RoomManager.join_room(code, user.id) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Removes the authenticated player from their current room.

  Leaves the room that the player is currently in. If the player is the host,
  the entire room is closed and all players are removed. The response indicates
  success without returning room details.

  Requires authentication via Bearer token.

  Returns HTTP 204 (No Content) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Headers Required

      Authorization: Bearer <token>

  ## Route Example

      DELETE /api/v1/rooms/A1B2/leave

  ## Response Example (Success)

      (204 No Content response with empty body)

  ## Response Example (Error - Not in Room)

      {
        "errors": [
          {
            "code": "NOT_IN_ROOM",
            "title": "Not in room",
            "detail": "Player is not in any room"
          }
        ]
      }

  ## Response Example (Error - Room Not Found)

      {
        "errors": [
          {
            "code": "NOT_FOUND",
            "title": "Not found",
            "detail": "Resource not found"
          }
        ]
      }
  """
  @spec leave(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def leave(conn, %{"code" => _code}) do
    user = conn.assigns[:current_user]

    with :ok <- RoomManager.leave_room(user.id) do
      conn
      |> put_status(:no_content)
      |> send_resp(:no_content, "")
    end
  end

  ## Private Helper Functions

  @doc false
  # Parses the filter parameter from request params
  #
  # Valid filters: "waiting", "ready", or nil (defaults to :all)
  # Converts string filters to atoms for RoomManager.list_rooms/1
  @spec parse_filter(String.t() | nil) :: :all | :waiting | :ready
  defp parse_filter(nil), do: :all
  defp parse_filter("waiting"), do: :waiting
  defp parse_filter("ready"), do: :ready
  defp parse_filter(_), do: :all

  @doc false
  # Parses room metadata from the request body
  #
  # Extracts relevant fields like name from the room parameters
  # Returns an empty map if no metadata is provided
  @spec parse_metadata(map() | nil) :: map()
  defp parse_metadata(nil), do: %{}

  defp parse_metadata(room_params) when is_map(room_params) do
    room_params
    |> Map.take(["name"])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, String.to_atom(key), value)
    end)
  end

  defp parse_metadata(_), do: %{}
end
