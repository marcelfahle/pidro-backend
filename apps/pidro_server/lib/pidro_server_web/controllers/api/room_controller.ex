defmodule PidroServerWeb.API.RoomController do
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
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Operation
  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.Schemas.{RoomSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Rooms"])

  # ==================== OpenAPI Operation Specs ====================

  @doc false
  def open_api_operation(:index) do
    %Operation{
      summary: "List all rooms",
      description: """
      Retrieves a list of available rooms from the RoomManager. The response can be
      filtered using a query parameter to show only waiting or ready rooms.

      This endpoint is publicly accessible and does not require authentication.
      """,
      operationId: "RoomController.index",
      tags: ["Rooms"],
      parameters: [
        Operation.parameter(
          :filter,
          :query,
          %OpenApiSpex.Schema{
            type: :string,
            enum: ["all", "waiting", "ready"],
            description: "Filter rooms by status"
          },
          "Optional filter parameter. Defaults to 'all'.",
          required: false
        )
      ],
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomsResponse)
      }
    }
  end

  @doc false
  def open_api_operation(:create) do
    %Operation{
      summary: "Create a new room",
      description: """
      Creates a new room with the authenticated user as the host. The room is created
      in a "waiting" status and is immediately joinable by other players. The response
      includes the newly created room's details and unique room code.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.create",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      requestBody:
        Operation.request_body(
          "Room creation parameters",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              room: %OpenApiSpex.Schema{
                type: :object,
                properties: %{
                  name: %OpenApiSpex.Schema{
                    type: :string,
                    description: "Optional room name"
                  }
                }
              }
            }
          },
          required: false
        ),
      responses: %{
        201 =>
          Operation.response(
            "Room created successfully",
            "application/json",
            RoomSchemas.RoomCreatedResponse
          ),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        422 =>
          Operation.response(
            "Validation error",
            "application/json",
            ErrorSchemas.validation_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:show) do
    %Operation{
      summary: "Get room details",
      description: """
      Gets the current state of a room including player list, host information, and
      room status. This endpoint is publicly accessible and does not require authentication.
      """,
      operationId: "RoomController.show",
      tags: ["Rooms"],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{
            type: :string,
            minLength: 4,
            maxLength: 4,
            description: "Unique 4-character room code"
          },
          "The unique room code",
          required: true
        )
      ],
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomResponse),
        404 =>
          Operation.response("Room not found", "application/json", ErrorSchemas.not_found_error())
      }
    }
  end

  @doc false
  def open_api_operation(:join) do
    %Operation{
      summary: "Join a room",
      description: """
      Adds the authenticated player to a room. The player can only be in one room
      at a time. When the 4th player joins, the room status automatically changes to
      "ready" and the game starts.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.join",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{
            type: :string,
            minLength: 4,
            maxLength: 4,
            description: "Unique 4-character room code"
          },
          "The unique room code",
          required: true
        )
      ],
      responses: %{
        200 =>
          Operation.response(
            "Successfully joined room",
            "application/json",
            RoomSchemas.RoomResponse
          ),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        404 =>
          Operation.response("Room not found", "application/json", ErrorSchemas.not_found_error()),
        422 =>
          Operation.response(
            "Room full or already in room",
            "application/json",
            ErrorSchemas.validation_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:leave) do
    %Operation{
      summary: "Leave a room",
      description: """
      Leaves the room that the player is currently in. If the player is the host,
      the entire room is closed and all players are removed. The response indicates
      success without returning room details.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.leave",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{
            type: :string,
            minLength: 4,
            maxLength: 4,
            description: "Unique 4-character room code"
          },
          "The unique room code",
          required: true
        )
      ],
      responses: %{
        204 =>
          Operation.response("Successfully left room", "application/json", %OpenApiSpex.Schema{
            type: :object
          }),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        404 =>
          Operation.response(
            "Room not found or not in room",
            "application/json",
            ErrorSchemas.not_found_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:state) do
    %Operation{
      summary: "Get room game state",
      description: """
      Retrieves the current game state from the Pidro.Server process. This includes
      the game phase, current turn, player hands, bids, tricks, and scores.

      This endpoint is publicly accessible and does not require authentication.
      """,
      operationId: "RoomController.state",
      tags: ["Rooms"],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{
            type: :string,
            minLength: 4,
            maxLength: 4,
            description: "Unique 4-character room code"
          },
          "The unique room code",
          required: true
        )
      ],
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.GameStateResponse),
        404 =>
          Operation.response(
            "Room or game not found",
            "application/json",
            ErrorSchemas.not_found_error()
          )
      }
    }
  end

  # ==================== Action Functions ====================

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
  def join(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]
    position = parse_position(params["position"])

    with {:ok, room, assigned_position} <- RoomManager.join_room(code, user.id, position) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room, assigned_position: assigned_position})
    end
  end

  @doc false
  @spec parse_position(String.t() | nil) :: atom() | nil
  defp parse_position(nil), do: nil
  defp parse_position("north"), do: :north
  defp parse_position("east"), do: :east
  defp parse_position("south"), do: :south
  defp parse_position("west"), do: :west
  defp parse_position("north_south"), do: :north_south
  defp parse_position("east_west"), do: :east_west
  defp parse_position(_), do: nil

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

  @doc """
  Joins a room as a spectator.

  Adds the authenticated user as a spectator to an active game room. Spectators
  can only join rooms that are currently playing or finished. They can watch the
  game state but cannot perform any game actions.

  Requires authentication via Bearer token.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Headers Required

      Authorization: Bearer <token>

  ## Route Example

      POST /api/v1/rooms/A1B2/watch

  ## Response Example (Success)

      {
        "data": {
          "room": {
            "code": "A1B2",
            "host_id": "user123",
            "player_ids": ["user123", "user456", "user789", "user012"],
            "spectator_ids": ["user_spectator_1"],
            "status": "playing",
            "max_players": 4,
            "max_spectators": 10,
            "created_at": "2024-11-02T10:30:00Z"
          }
        }
      }

  ## Response Example (Error - Room Not Available for Spectators)

      {
        "errors": [
          {
            "code": "ROOM_NOT_AVAILABLE_FOR_SPECTATORS",
            "title": "Room not available for spectators",
            "detail": "Can only spectate games that are playing or finished"
          }
        ]
      }

  ## Response Example (Error - Spectators Full)

      {
        "errors": [
          {
            "code": "SPECTATORS_FULL",
            "title": "Spectators full",
            "detail": "Room has reached maximum number of spectators"
          }
        ]
      }
  """
  @spec watch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def watch(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    with {:ok, room} <- RoomManager.join_spectator_room(code, user.id) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Removes the authenticated user from spectating a room.

  Leaves the room as a spectator. The response indicates success without
  returning room details.

  Requires authentication via Bearer token.

  Returns HTTP 204 (No Content) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Headers Required

      Authorization: Bearer <token>

  ## Route Example

      DELETE /api/v1/rooms/A1B2/unwatch

  ## Response Example (Success)

      (204 No Content response with empty body)

  ## Response Example (Error - Not Spectating)

      {
        "errors": [
          {
            "code": "NOT_SPECTATING",
            "title": "Not spectating",
            "detail": "User is not spectating any room"
          }
        ]
      }
  """
  @spec unwatch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unwatch(conn, %{"code" => _code}) do
    user = conn.assigns[:current_user]

    with :ok <- RoomManager.leave_spectator(user.id) do
      conn
      |> put_status(:no_content)
      |> send_resp(:no_content, "")
    end
  end

  @doc """
  Gets the current game state for a room.

  Retrieves the current game state from the Pidro.Server process. This includes
  the game phase, current turn, player hands, bids, tricks, and scores.

  This endpoint is publicly accessible and does not require authentication.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include:
      - `code` - The unique room code (case-insensitive)

  ## Route Example

      GET /api/v1/rooms/A1B2/state

  ## Response Example (Success)

      {
        "data": {
          "state": {
            "phase": "bidding",
            "hand_number": 1,
            "current_turn": "north",
            "current_dealer": "west",
            "players": {
              "north": {
                "position": "north",
                "team": "north_south",
                "hand": [[14, "hearts"], [13, "hearts"], ...],
                "tricks_won": 0
              },
              ...
            },
            "bids": [
              {"position": "west", "amount": "pass"},
              {"position": "north", "amount": 8}
            ],
            "tricks": [],
            "cumulative_scores": {
              "north_south": 0,
              "east_west": 0
            }
          }
        }
      }

  ## Response Example (Error - Game Not Started)

      {
        "errors": [
          {
            "code": "GAME_NOT_FOUND",
            "title": "Game not found",
            "detail": "No game is currently active for this room"
          }
        ]
      }
  """
  @spec state(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def state(conn, %{"code" => code}) do
    alias PidroServer.Games.GameAdapter

    with {:ok, game_state} <- GameAdapter.get_state(code) do
      conn
      |> put_view(RoomJSON)
      |> render(:state, %{state: game_state})
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
