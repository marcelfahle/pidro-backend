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
  - `create_invite/2` - Minting an invite link; host only (R1, KD5)
  - `seat/2`, `lock/2`, `kick/2` - Host controls for waiting rooms (R23)

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
  - `{:error, :table_locked}` - The host locked the table (423)
  - `{:error, :kicked}` - The caller was kicked from this room (403)
  - `{:error, :room_not_waiting}` - A host control outside `:waiting`/`:ready` (409)
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias OpenApiSpex.Operation
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.Room.Config
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.Invite
  alias PidroServerWeb.API.{InviteController, InviteJSON, RoomJSON}
  alias PidroServerWeb.Schemas.{ErrorSchemas, InviteSchemas, RoomSchemas}

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
  def open_api_operation(:lobby) do
    %Operation{
      summary: "Get categorized lobby data",
      description: """
      Returns rooms grouped into four categories for the lobby UI:
      my_rejoinable, open_tables, substitute_needed, and spectatable.

      Requires authentication to identify which rooms the user can rejoin.
      """,
      operationId: "RoomController.lobby",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomsResponse),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:create) do
    %Operation{
      summary: "Create a new room",
      description: """
      Creates a new room with the authenticated user as the host, seated north. The room
      is created in a "waiting" status and is immediately joinable by other players. The
      response includes the newly created room's details and unique room code.

      The body is a flat JSON object with three optional fields:

      - `name` - trimmed, at most 60 characters; missing or blank means no name
      - `seats` - `seat_2` (east), `seat_3` (south) and `seat_4` (west), each `"ai"` or
        `"open"`; a missing seat is open. A bot is started for every `"ai"` seat, and a
        room whose three seats are all `"ai"` is a solo room, hidden from the lobby
      - `bot_difficulty` - `"random"`, `"basic"` or `"smart"`; defaults to `"basic"`

      Name, difficulty and solo are stored on the room and returned as `config`.

      Every other key is rejected, including a `room` wrapper and `settings`. A rejected
      request creates no room and starts no bot. The 422 response lists every problem at
      once, one entry per field, with the field path as `code`: `name`, `bot_difficulty`,
      `seats`, `seats.seat_5`, `settings`, or `body` when the body is not a JSON object.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.create",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      requestBody:
        Operation.request_body(
          "Room creation parameters",
          "application/json",
          RoomSchemas.RoomCreateRequest,
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
            "Invalid request: one error per problem, each with the field path as its code " <>
              "(e.g. `settings`, `bot_difficulty`, `seats.seat_5`); or ALREADY_IN_ROOM",
            "application/json",
            ErrorSchemas.validation_error()
          ),
        429 =>
          Operation.response(
            "Rate limit exceeded; see Retry-After",
            "application/json",
            ErrorSchemas.too_many_requests_error()
          ),
        503 =>
          Operation.response(
            "No free room code could be allocated; retry shortly",
            "application/json",
            ErrorSchemas.room_code_exhausted_error()
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
          Operation.response("Room not found", "application/json", ErrorSchemas.not_found_error()),
        429 =>
          Operation.response(
            "Rate limit exceeded; see Retry-After",
            "application/json",
            ErrorSchemas.too_many_requests_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:join) do
    %Operation{
      summary: "Join a room",
      description: """
      Adds the authenticated player to a room. The player can only be in one room
      at a time. A full waiting room starts only after every human confirms readiness.
      In a playing room, this explicit command claims an owner-opened substitute
      seat. Successful admission ends any spectator membership atomically; game
      channel joins/reconnects never claim unowned seats.

      A locked table answers 423 `TABLE_LOCKED`; a user the host kicked answers
      403 `KICKED`. Limited at policy `room_join` (per user).

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.join",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
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
        403 =>
          Operation.response(
            "Kicked from this room",
            "application/json",
            ErrorSchemas.error_response()
          ),
        404 =>
          Operation.response("Room not found", "application/json", ErrorSchemas.not_found_error()),
        422 =>
          Operation.response(
            "Room full, seat taken or already in room",
            "application/json",
            ErrorSchemas.validation_error()
          ),
        423 =>
          Operation.response("Table locked", "application/json", ErrorSchemas.locked_error()),
        429 =>
          Operation.response(
            "Rate limit exceeded; see Retry-After",
            "application/json",
            ErrorSchemas.too_many_requests_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:create_invite) do
    %Operation{
      summary: "Mint the room's invite link",
      description: """
      Mints an invite for a room the caller hosts while it is waiting. One link per
      table: a second mint updates the active invite's `seat_hint` and `label` in
      place and answers 200 with the same code. `supersedes` names an earlier
      invite the caller hosted (play again); it forwards here with state `moved`
      while this table waits.

      A room that is not `waiting`/`ready` answers 409 `ROOM_NOT_WAITING`; more
      than 20 invites for one room answer 409 `INVITE_LIMIT`; a non-host answers
      403. Limited at policy `invite_mint` (per user).
      """,
      operationId: "RoomController.create_invite",
      tags: ["Invites"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      requestBody:
        Operation.request_body(
          "Seat hint, label and supersedes",
          "application/json",
          InviteSchemas.MintRequest,
          required: false
        ),
      responses: %{
        201 =>
          Operation.response("Invite minted", "application/json", InviteSchemas.InviteResponse),
        200 =>
          Operation.response(
            "Active invite updated in place",
            "application/json",
            InviteSchemas.InviteResponse
          ),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        403 =>
          Operation.response("Not the host", "application/json", ErrorSchemas.error_response()),
        404 =>
          Operation.response(
            "Room or superseded invite not found",
            "application/json",
            ErrorSchemas.not_found_error()
          ),
        409 =>
          Operation.response(
            "Room not waiting or invite limit reached",
            "application/json",
            ErrorSchemas.conflict_error()
          ),
        422 =>
          Operation.response(
            "Invalid seat hint or label",
            "application/json",
            ErrorSchemas.validation_error()
          ),
        429 =>
          Operation.response(
            "Rate limit exceeded; see Retry-After",
            "application/json",
            ErrorSchemas.too_many_requests_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:seat) do
    %Operation{
      summary: "Move a player to a vacant seat",
      description: """
      In a waiting room the host may move any seated player; a seated non-host may
      move only themselves (omit `user_id`). The target position must be vacant.

      Outside `waiting`/`ready` answers 409 `ROOM_NOT_WAITING`; a non-host moving
      somebody else answers 403; a taken target answers 422 `SEAT_TAKEN`.
      """,
      operationId: "RoomController.seat",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      requestBody:
        Operation.request_body(
          "Target position and optional user",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:position],
            properties: %{
              position: position_schema(),
              user_id: %OpenApiSpex.Schema{
                type: :string,
                description: "Player to move; defaults to the caller"
              }
            }
          }
        ),
      responses: host_control_responses()
    }
  end

  @doc false
  def open_api_operation(:lock) do
    %Operation{
      summary: "Lock or unlock the table",
      description: """
      A locked table refuses room joins and invite redemptions with 423
      `TABLE_LOCKED`; reclaiming a held seat still works. Host only, waiting rooms
      only (409 `ROOM_NOT_WAITING` otherwise).
      """,
      operationId: "RoomController.lock",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      requestBody:
        Operation.request_body(
          "Lock state",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:locked],
            properties: %{locked: %OpenApiSpex.Schema{type: :boolean}}
          }
        ),
      responses: host_control_responses()
    }
  end

  @doc false
  def open_api_operation(:kick) do
    %Operation{
      summary: "Kick a seated player",
      description: """
      Vacates the seat at `position`, adds the player to the room's kick list so
      they cannot join, redeem or substitute into this room again, and closes their
      game channel with a `kicked` event. Host only, waiting rooms only.

      The host's own seat, a bot and a vacant seat answer 422 `SEAT_NOT_KICKABLE`.
      """,
      operationId: "RoomController.kick",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      requestBody:
        Operation.request_body(
          "Seat position",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:position],
            properties: %{position: position_schema()}
          }
        ),
      responses: host_control_responses()
    }
  end

  @doc false
  def open_api_operation(:seat_bot) do
    %Operation{
      summary: "Seat a bot in an open seat",
      description: """
      Fills the vacant seat at `position` with a bot at the room's configured
      `bot_difficulty`. Host only, in a waiting or ready room. This is how a table that
      lost a player after a game carries on without leaving the room.

      A seat that is not vacant answers 422 `SEAT_NOT_VACANT`.
      """,
      operationId: "RoomController.seat_bot",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      requestBody:
        Operation.request_body(
          "Seat position",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:position],
            properties: %{position: position_schema()}
          }
        ),
      responses: host_control_responses()
    }
  end

  @doc false
  def open_api_operation(:watch) do
    %Operation{
      summary: "Watch a room as a spectator",
      description: """
      Adds the authenticated user as a spectator of a playing or finished room.
      Spectators see the public game state but cannot act.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.watch",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomResponse),
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
            "Room not spectatable, spectators full or already spectating",
            "application/json",
            ErrorSchemas.validation_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:unwatch) do
    %Operation{
      summary: "Stop watching a room",
      description: """
      Removes the authenticated user from the room's spectators.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.unwatch",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [room_code_parameter()],
      responses: %{
        204 =>
          Operation.response("Stopped spectating", "application/json", %OpenApiSpex.Schema{
            type: :object
          }),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        404 =>
          Operation.response("Not spectating", "application/json", ErrorSchemas.not_found_error())
      }
    }
  end

  @doc false
  def open_api_operation(:open_seat) do
    %Operation{
      summary: "Open a bot seat for a human substitute",
      description: """
      Room owner can open a bot-substitute seat so a stranger can join the
      playing game. The bot is terminated and the seat becomes vacant.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.open_seat",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{type: :string, minLength: 4, maxLength: 4},
          "The unique room code",
          required: true
        )
      ],
      requestBody:
        Operation.request_body(
          "Seat position",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:position],
            properties: %{
              position: %OpenApiSpex.Schema{
                type: :string,
                enum: ["north", "south", "east", "west"]
              }
            }
          }
        ),
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomResponse),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        403 =>
          Operation.response("Not owner", "application/json", ErrorSchemas.validation_error()),
        422 =>
          Operation.response(
            "Invalid request",
            "application/json",
            ErrorSchemas.validation_error()
          )
      }
    }
  end

  @doc false
  def open_api_operation(:close_seat) do
    %Operation{
      summary: "Close a vacant seat back to a bot",
      description: """
      Room owner can close a vacant seat (previously opened via open_seat),
      spawning a new bot to fill the position.

      Requires authentication via Bearer token.
      """,
      operationId: "RoomController.close_seat",
      tags: ["Rooms"],
      security: [%{"bearer_auth" => []}],
      parameters: [
        Operation.parameter(
          :code,
          :path,
          %OpenApiSpex.Schema{type: :string, minLength: 4, maxLength: 4},
          "The unique room code",
          required: true
        )
      ],
      requestBody:
        Operation.request_body(
          "Seat position",
          "application/json",
          %OpenApiSpex.Schema{
            type: :object,
            required: [:position],
            properties: %{
              position: %OpenApiSpex.Schema{
                type: :string,
                enum: ["north", "south", "east", "west"]
              }
            }
          }
        ),
      responses: %{
        200 => Operation.response("Success", "application/json", RoomSchemas.RoomResponse),
        401 =>
          Operation.response(
            "Unauthorized",
            "application/json",
            ErrorSchemas.unauthorized_error()
          ),
        403 =>
          Operation.response("Not owner", "application/json", ErrorSchemas.validation_error()),
        422 =>
          Operation.response(
            "Invalid request",
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
      the game phase, current turn, player hands (hidden for other players), bids,
      tricks, and scores.

      Requires authentication via Bearer token. Other players' hands are hidden
      and only card counts are returned.
      """,
      operationId: "RoomController.state",
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

    rooms =
      RoomManager.list_rooms(filter)
      |> Enum.filter(&RoomManager.visible_in_lobby?/1)

    conn
    |> put_view(RoomJSON)
    |> render(:index, %{rooms: rooms})
  end

  @doc """
  Returns categorized lobby data.

  Returns rooms grouped into four categories:
  - `my_rejoinable` - Playing rooms where the user has a reserved seat
  - `open_tables` - Waiting rooms with vacant seats
  - `substitute_needed` - Playing rooms with vacant seats opened by the owner
  - `spectatable` - Playing rooms with spectator capacity remaining

  Requires authentication via Bearer token.

  Returns HTTP 200 (OK) on success.
  """
  @spec lobby(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lobby(conn, _params) do
    user = conn.assigns[:current_user]
    lobby = RoomManager.list_lobby(user.id)

    conn
    |> put_view(RoomJSON)
    |> render(:lobby, %{lobby: lobby})
  end

  @doc """
  Creates a new game room.

  Creates a new room with the authenticated user as the host. The room is created
  in a "waiting" status and is immediately joinable by other players. The response
  includes the newly created room's details and unique room code.

  Requires authentication via Bearer token.

  Returns HTTP 201 (Created) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned).
      The request body is parsed by `PidroServer.Games.Room.Config.parse_create_params/1`,
      which documents the grammar. Every field is optional:
      - `name` - Room name, at most 60 characters
      - `seats` - `seat_2`, `seat_3` and `seat_4`, each `"ai"` or `"open"`
      - `bot_difficulty` - `"random"`, `"basic"` or `"smart"`; defaults to `"basic"`
    * `_params` - Unused. The merged params also carry query-string keys, which
      must not count as unknown body fields.

  Any other body key, including a `room` wrapper, and any invalid value answers
  HTTP 422 with one error per problem and the field path as its `code`. A
  rejected request creates no room and starts no bot.

  ## Headers Required

      Authorization: Bearer <token>

  ## Request Body Example

      {
        "name": "Fun Game Night",
        "seats": {"seat_2": "ai", "seat_3": "open", "seat_4": "ai"},
        "bot_difficulty": "smart"
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

  ## Response Example (Error - Unknown field)

      {
        "errors": [
          {
            "code": "settings",
            "title": "Settings",
            "detail": "is not an accepted field"
          }
        ]
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
  def create(conn, _params) do
    user = conn.assigns[:current_user]

    # The request body, not the merged params: a query-string key must not trip
    # the unknown-field check. Parsing runs first, so a rejected request creates
    # no room, starts no bot, and never reaches `create_room/2`'s stale-room
    # eviction.
    with {:ok, config, seat_plan} <- Config.parse_create_params(create_body(conn)),
         {:ok, room} <- RoomManager.create_room(user.id, config) do
      start_bots_for_room(room, seat_plan)

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
  at a time. Waiting rooms require explicit readiness before starting. Playing
  rooms admit substitutes only into owner-opened seats. A successful claim ends
  spectator membership; failed admission leaves watching unchanged.

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

  @spec parse_position_strict(String.t() | nil) :: {:ok, atom()} | {:error, :invalid_position}
  defp parse_position_strict("north"), do: {:ok, :north}
  defp parse_position_strict("east"), do: {:ok, :east}
  defp parse_position_strict("south"), do: {:ok, :south}
  defp parse_position_strict("west"), do: {:ok, :west}
  defp parse_position_strict(_), do: {:error, :invalid_position}

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
  Opens a bot-filled seat for a human substitute.

  The room owner can open a bot-substitute seat so a stranger can join the
  playing game. The bot is terminated and the seat becomes vacant.

  Requires authentication via Bearer token.

  Returns HTTP 200 (OK) on success.
  """
  @spec open_seat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def open_seat(conn, %{"code" => code, "position" => position} = params) do
    user = conn.assigns[:current_user]

    with {:ok, pos_atom} <- parse_position_strict(position),
         {:ok, room} <-
           RoomManager.open_seat(code, pos_atom, user.id, Map.get(params, "decision_id")) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  def open_seat(conn, %{"code" => code}) do
    # Position is required
    open_seat(conn, %{"code" => code, "position" => nil})
  end

  @doc """
  Closes a vacant seat back to a bot.

  The room owner can close a vacant seat (previously opened via open_seat),
  spawning a new bot to fill the position.

  Requires authentication via Bearer token.

  Returns HTTP 200 (OK) on success.
  """
  @spec close_seat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def close_seat(conn, %{"code" => code, "position" => position}) do
    user = conn.assigns[:current_user]

    with {:ok, pos_atom} <- parse_position_strict(position),
         {:ok, room} <- RoomManager.close_seat(code, pos_atom, user.id) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  def close_seat(conn, %{"code" => code}) do
    close_seat(conn, %{"code" => code, "position" => nil})
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
  def unwatch(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    with :ok <- RoomManager.leave_spectator(code, user.id) do
      conn
      |> put_status(:no_content)
      |> send_resp(:no_content, "")
    end
  end

  @doc """
  Gets the current game state for a room.

  Retrieves the current game state from the Pidro.Server process. This includes
  the game phase, current turn, bids, tricks, and scores. Other players' hands
  are hidden (only card counts returned) to prevent cheating.

  Requires authentication via Bearer token.

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
            "scores": {
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
      |> render(:state, %{state: game_state, viewer_user_id: conn.assigns[:current_user_id]})
    end
  end

  # ==================== Invites and host controls ====================

  @doc """
  Mints the room's invite link (R1). See `open_api_operation(:create_invite)`.

  Returns HTTP 201 for a new invite and HTTP 200 when the active invite was
  updated in place.
  """
  @spec create_invite(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_invite(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]

    with {:ok, room} <- RoomManager.get_room(code),
         :ok <- ensure_host(room, user.id),
         :ok <- ensure_waiting(room),
         {:ok, superseded} <- fetch_superseded(params["supersedes"], user.id),
         {:ok, invite, status} <- mint_or_update(room, user.id, params, superseded) do
      InviteController.note_invites(room.code, room.id)

      conn
      |> put_status(status)
      |> put_view(InviteJSON)
      |> render(:invite, %{invite: invite, state: InviteController.derive_state(invite)})
    end
  end

  @doc """
  Moves a seated player to a vacant position (R23). See `open_api_operation(:seat)`.
  """
  @spec seat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def seat(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]
    target = params["user_id"] || user.id

    with {:ok, position} <- parse_position_strict(params["position"]),
         {:ok, room} <- RoomManager.move_seat(code, user.id, target, position) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Locks or unlocks the table (R23). See `open_api_operation(:lock)`.
  """
  @spec lock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lock(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]

    with {:ok, locked} <- parse_locked(params["locked"]),
         {:ok, room} <- RoomManager.set_locked(code, user.id, locked) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Kicks the player seated at a position (R23). See `open_api_operation(:kick)`.
  """
  @spec kick(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def kick(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]

    with {:ok, position} <- parse_position_strict(params["position"]),
         {:ok, room} <- RoomManager.kick_player(code, user.id, position) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  @doc """
  Seats a bot in a vacant seat (host only). See `open_api_operation(:seat_bot)`.
  """
  @spec seat_bot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def seat_bot(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]

    with {:ok, position} <- parse_position_strict(params["position"]),
         {:ok, room} <- RoomManager.get_room(code),
         :ok <- ensure_host(room, user.id),
         :ok <- ensure_waiting(room),
         :ok <- ensure_vacant(room, position),
         {:ok, room} <- start_seated_bot(room, position) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room})
    end
  end

  ## Private Helper Functions

  defp ensure_vacant(%Room{seats: seats}, position) do
    case Map.get(seats, position) do
      %{occupant_type: :vacant} -> :ok
      _ -> {:error, :seat_not_vacant}
    end
  end

  # The bot seats itself through `RoomManager.join_bot/4`, which is where the
  # seat is really claimed: the vacancy check above is only a read, and a human
  # or another request may have taken the seat since. This cannot be one
  # RoomManager call: the bot joins from its own `init/1`, which would deadlock
  # a RoomManager that was waiting for it. So cleanup is scoped to the bot this
  # request started, never to whatever holds the slot.
  defp start_seated_bot(%Room{code: code} = room, position, retry? \\ true) do
    case BotManager.start_bot(code, position, room.config.bot_difficulty) do
      {:ok, pid} ->
        confirm_seated_bot(code, position, pid)

      {:error, :already_exists} ->
        # The slot is registered to a bot. One that is gone (it held this seat
        # in an earlier game) is cleared once; a live one means another request
        # is seating a bot here, and that request owns the seat.
        if retry? and stale_bot_slot?(code, position) do
          _ = BotManager.stop_bot(code, position)
          start_seated_bot(room, position, false)
        else
          {:error, :seat_not_vacant}
        end

      {:error, _reason} ->
        {:error, :seat_not_vacant}
    end
  end

  defp confirm_seated_bot(code, position, pid) do
    with {:ok, %Room{} = seated} <- RoomManager.get_room(code),
         %{occupant_type: :bot, bot_pid: ^pid} <- Map.get(seated.seats, position) do
      {:ok, seated}
    else
      {:error, :room_not_found} = gone ->
        gone

      _ ->
        if BotManager.bot_pid(code, position) == pid, do: BotManager.stop_bot(code, position)
        {:error, :seat_not_vacant}
    end
  end

  defp stale_bot_slot?(code, position) do
    case BotManager.bot_pid(code, position) do
      pid when is_pid(pid) -> not Process.alive?(pid)
      nil -> false
    end
  end

  defp ensure_host(%Room{host_id: host_id}, host_id), do: :ok
  defp ensure_host(%Room{}, _user_id), do: {:error, :not_owner}

  defp ensure_waiting(%Room{status: status}) when status in [:waiting, :ready], do: :ok
  defp ensure_waiting(%Room{}), do: {:error, :room_not_waiting}

  defp fetch_superseded(nil, _host_id), do: {:ok, nil}

  defp fetch_superseded(code, host_id) do
    case Invites.get_by_code(code) do
      {:ok, %Invite{host_user_id: ^host_id} = invite} -> {:ok, invite}
      {:ok, %Invite{}} -> {:error, :not_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  # One link per table (KD1): an active invite is updated in place; otherwise a
  # new one is minted under the per-room cap. The context serializes this whole
  # mutation with any supersession for the room.
  defp mint_or_update(%Room{} = room, host_id, params, superseded) do
    attrs = hint_attrs(params)

    with {:ok, invite, status} <-
           Invites.mint_for_room(
             Map.merge(attrs, %{
               room_id: room.id,
               room_code: room.code,
               host_user_id: host_id
             }),
             superseded
           ) do
      if status == :created do
        InviteController.log_event(invite, %{
          kind: "created",
          user_id: host_id,
          platform: params["platform"]
        })
      end

      {:ok, invite, status}
    end
  end

  # Only the keys the body carries, so a second mint without `label` keeps it.
  defp hint_attrs(params) do
    %{}
    |> maybe_take(params, "seat_hint", :seat_hint)
    |> maybe_take(params, "label", :label)
  end

  defp maybe_take(attrs, params, key, atom_key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, atom_key, value)
      :error -> attrs
    end
  end

  defp parse_locked(locked) when is_boolean(locked), do: {:ok, locked}
  defp parse_locked(_locked), do: {:error, :invalid_locked}

  defp room_code_parameter do
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
  end

  defp position_schema do
    %OpenApiSpex.Schema{type: :string, enum: ["north", "east", "south", "west"]}
  end

  defp host_control_responses do
    %{
      200 => Operation.response("Success", "application/json", RoomSchemas.RoomResponse),
      401 =>
        Operation.response("Unauthorized", "application/json", ErrorSchemas.unauthorized_error()),
      403 =>
        Operation.response("Not the host", "application/json", ErrorSchemas.error_response()),
      404 =>
        Operation.response("Room not found", "application/json", ErrorSchemas.not_found_error()),
      409 =>
        Operation.response("Room not waiting", "application/json", ErrorSchemas.conflict_error()),
      422 =>
        Operation.response("Invalid request", "application/json", ErrorSchemas.validation_error())
    }
  end

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

  # The create-room request body as `Plug.Parsers` left it: a string-keyed map,
  # empty when the request has no body. Plug wraps a non-object JSON body as
  # `%{"_json" => value}`; it is unwrapped so the parser names `body`, not a
  # `_json` key the caller never sent. Plug never wraps an object, so a `_json`
  # key holding a map was sent as written and stays for the parser to reject.
  @spec create_body(Plug.Conn.t()) :: term()
  defp create_body(%Plug.Conn{body_params: body}) do
    case body do
      %{"_json" => value} when map_size(body) == 1 and not is_map(value) -> value
      _ -> body
    end
  end

  # Starts a bot for every seat the parsed seat plan marks `:bot`, at the
  # difficulty stored on the room's config. The host holds :north; the plan
  # covers :east, :south and :west. A bot that fails to start is logged and the
  # room stands.
  @spec start_bots_for_room(Room.t(), Config.seat_plan()) :: :ok
  defp start_bots_for_room(%Room{} = room, seat_plan) do
    difficulty = room.config.bot_difficulty

    for position <- [:east, :south, :west], seat_plan[position] == :bot do
      case BotManager.start_bot(room.code, position, difficulty) do
        {:ok, _pid} ->
          Logger.info("Started #{difficulty} bot at #{position} in room #{room.code}")

        {:error, reason} ->
          Logger.warning(
            "Failed to start bot at #{position} in room #{room.code}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end
end
