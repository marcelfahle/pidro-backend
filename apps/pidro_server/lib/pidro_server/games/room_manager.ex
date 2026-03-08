defmodule PidroServer.Games.RoomManager do
  @moduledoc """
  GenServer for managing game rooms in the Pidro application.

  The RoomManager handles the lifecycle of game rooms, including:
  - Creating new rooms with unique codes
  - Managing player joins and leaves
  - Auto-starting games when rooms reach 4 players
  - Broadcasting room and lobby updates via PubSub
  - Tracking player-to-room mappings to prevent duplicate room membership

  ## Room Lifecycle

  1. **Creation**: A host creates a room with a unique 4-character alphanumeric code
  2. **Waiting**: Room status is `:waiting` while players join (1-3 players)
  3. **Ready**: When 4 players join, status changes to `:ready` and game auto-starts
  4. **Closed**: Room closes when host leaves or all players leave

  ## PubSub Events

  The RoomManager broadcasts events on two topics:
  - `lobby:updates` - Notifies all clients about room list changes
  - `room:<room_code>` - Notifies players in a specific room about room changes

  ## Examples

      # Create a new room
      {:ok, room} = RoomManager.create_room("user123", %{name: "Fun Game"})

      # Join an existing room
      {:ok, room} = RoomManager.join_room("ABCD", "user456")

      # Leave a room
      :ok = RoomManager.leave_room("user123")

      # List all waiting rooms
      rooms = RoomManager.list_rooms(:waiting)

      # Get specific room details
      {:ok, room} = RoomManager.get_room("ABCD")
  """

  use GenServer
  require Logger

  alias PidroServer.Games.Bots.SubstituteBot
  alias PidroServer.Games.GameSupervisor
  alias PidroServer.Games.Lifecycle
  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.Room.Seat

  @max_players 4
  @room_code_length 4

  # Room struct representing a game room
  defmodule Room do
    @moduledoc """
    Struct representing a game room.

    ## Fields

    - `:code` - Unique 4-character alphanumeric room code
    - `:host_id` - User ID of the room host (creator)
    - `:positions` - Map of positions to player IDs (%{north: "user1", east: nil, ...}) - SINGLE SOURCE OF TRUTH
    - `:spectator_ids` - List of user IDs currently spectating the room
    - `:status` - Current room status (`:waiting`, `:ready`, `:playing`, `:finished`, or `:closed`)
    - `:max_players` - Maximum number of players (default: 4)
    - `:max_spectators` - Maximum number of spectators (default: 10)
    - `:created_at` - DateTime when the room was created
    - `:metadata` - Additional room metadata (e.g., room name)
    - `:disconnected_players` - Map of disconnected players with their disconnect timestamps (%{user_id => DateTime.t()})
    - `:phase_timers` - Map of position to timer reference for the disconnect cascade (%{position => reference()})

    ## Derived Data

    DO NOT store player_ids separately. Use `Positions.player_ids(room)` to derive the list.
    """

    @type position :: :north | :east | :south | :west
    @type positions_map :: %{position() => String.t() | nil}
    @type status :: :waiting | :ready | :playing | :finished | :closed
    @type t :: %__MODULE__{
            code: String.t(),
            host_id: String.t(),
            positions: positions_map(),
            spectator_ids: [String.t()],
            status: status(),
            max_players: integer(),
            max_spectators: integer(),
            created_at: DateTime.t(),
            metadata: map(),
            disconnected_players: %{String.t() => DateTime.t()},
            phase_timers: %{Positions.position() => reference()},
            seats: map(),
            last_activity: DateTime.t()
          }

    defstruct [
      :code,
      :host_id,
      :status,
      :max_players,
      :created_at,
      :metadata,
      :last_activity,
      positions: %{north: nil, east: nil, south: nil, west: nil},
      spectator_ids: [],
      max_spectators: 10,
      disconnected_players: %{},
      phase_timers: %{},
      seats: %{}
    ]
  end

  # Internal state struct
  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            rooms: %{String.t() => Room.t()},
            player_rooms: %{String.t() => String.t()},
            spectator_rooms: %{String.t() => String.t()}
          }

    defstruct rooms: %{},
              player_rooms: %{},
              spectator_rooms: %{}
  end

  ## Client API

  @doc """
  Starts the RoomManager GenServer.

  ## Options

  Standard GenServer options can be passed.

  ## Examples

      {:ok, pid} = RoomManager.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Creates a new game room.

  The creator becomes the host of the room. A unique 4-character alphanumeric
  room code is generated. The room starts in `:waiting` status.

  ## Parameters

  - `host_id` - User ID of the room creator
  - `metadata` - Optional metadata map (e.g., `%{name: "My Game"}`)

  ## Returns

  - `{:ok, room}` - Successfully created room
  - `{:error, :already_in_room}` - Host is already in another room

  ## Examples

      {:ok, room} = RoomManager.create_room("user123", %{name: "Fun Game"})
      room.code #=> "A1B2"
      room.status #=> :waiting
  """
  @spec create_room(String.t(), map()) :: {:ok, Room.t()} | {:error, :already_in_room}
  def create_room(host_id, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:create_room, host_id, metadata})
  end

  @doc """
  Joins an existing room.

  A player can only be in one room at a time. When the 4th player joins,
  the room status changes to `:ready` and a game is automatically started.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)
  - `player_id` - User ID of the joining player
  - `position` - Optional position preference (`:north`, `:east`, `:south`, `:west`, `:north_south`, `:east_west`, or `nil` for auto)

  ## Returns

  - `{:ok, room, assigned_position}` - Successfully joined room with assigned position
  - `{:error, :room_not_found}` - Room code doesn't exist
  - `{:error, :room_full}` - Room already has 4 players
  - `{:error, :already_in_room}` - Player is already in another room
  - `{:error, :seat_taken}` - Requested specific seat is already occupied
  - `{:error, :team_full}` - Requested team is fully occupied
  - `{:error, :invalid_position}` - Invalid position parameter

  ## Examples

      {:ok, room, :north} = RoomManager.join_room("A1B2", "user456", :north)
      {:ok, room, :south} = RoomManager.join_room("A1B2", "user789", :north_south)
      {:ok, room, :east} = RoomManager.join_room("A1B2", "user999")
  """
  @spec join_room(String.t(), String.t(), Positions.choice()) ::
          {:ok, Room.t(), Positions.position()}
          | {:error,
             :room_not_found
             | :room_full
             | :already_in_room
             | :seat_taken
             | :team_full
             | :invalid_position}
  def join_room(room_code, player_id, position \\ nil) do
    GenServer.call(__MODULE__, {:join_room, String.upcase(room_code), player_id, position})
  end

  @doc """
  Removes a player from their current room.

  If the player is the host, the room is closed and all players are removed.
  If the room becomes empty, it is automatically deleted.

  ## Parameters

  - `player_id` - User ID of the leaving player

  ## Returns

  - `:ok` - Successfully left room
  - `{:error, :not_in_room}` - Player is not in any room

  ## Examples

      :ok = RoomManager.leave_room("user123")
  """
  @spec leave_room(String.t()) :: :ok | {:error, :not_in_room}
  def leave_room(player_id) do
    GenServer.call(__MODULE__, {:leave_room, player_id})
  end

  @doc """
  Lists all rooms, optionally filtered by status.

  ## Parameters

  - `filter` - Optional filter (`:all`, `:waiting`, `:ready`, `:playing`, `:available`). Defaults to `:all`.
    - `:available` returns all rooms except `:finished` and `:closed` (useful for lobby)

  ## Returns

  List of rooms matching the filter criteria.

  ## Examples

      # List all rooms
      all_rooms = RoomManager.list_rooms()

      # List only waiting rooms
      waiting_rooms = RoomManager.list_rooms(:waiting)

      # List available rooms (waiting, ready, or playing)
      available_rooms = RoomManager.list_rooms(:available)
  """
  @spec list_rooms(:all | :waiting | :ready | :playing | :available) :: [Room.t()]
  def list_rooms(filter \\ :all) do
    GenServer.call(__MODULE__, {:list_rooms, filter})
  end

  @doc """
  Returns categorized lobby data for the given user.

  ## Categories

  - `:my_rejoinable` - Playing rooms where the user has a reserved seat (can reclaim)
  - `:open_tables` - Waiting rooms with vacant seats
  - `:substitute_needed` - Playing rooms with vacant seats opened by owner
  - `:spectatable` - Playing rooms with spectator capacity remaining

  Rooms with zero connected humans appear in no category.

  ## Parameters

  - `user_id` - The user's ID (can be nil for anonymous browsing)

  ## Returns

  A map with four category keys, each containing a list of room structs.

  ## Examples

      lobby = RoomManager.list_lobby("user-123")
      lobby.my_rejoinable  # rooms where user can reclaim their seat
      lobby.open_tables    # waiting rooms to join
  """
  @spec list_lobby(String.t() | nil) :: %{
          my_rejoinable: [Room.t()],
          open_tables: [Room.t()],
          substitute_needed: [Room.t()],
          spectatable: [Room.t()]
        }
  def list_lobby(user_id \\ nil) do
    GenServer.call(__MODULE__, {:list_lobby, user_id})
  end

  @doc """
  Gets details of a specific room.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)

  ## Returns

  - `{:ok, room}` - Room details
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      {:ok, room} = RoomManager.get_room("A1B2")
  """
  @spec get_room(String.t()) :: {:ok, Room.t()} | {:error, :room_not_found}
  def get_room(room_code) do
    GenServer.call(__MODULE__, {:get_room, String.upcase(room_code)})
  end

  @doc """
  Updates the status of a room.

  ## Parameters

  - `room_code` - The unique room code
  - `status` - New status (`:waiting`, `:ready`, `:playing`, `:finished`, or `:closed`)

  ## Returns

  - `:ok` - Status updated successfully
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      :ok = RoomManager.update_room_status("A1B2", :playing)
  """
  @spec update_room_status(String.t(), Room.status()) :: :ok | {:error, :room_not_found}
  def update_room_status(room_code, status) do
    GenServer.call(__MODULE__, {:update_room_status, String.upcase(room_code), status})
  end

  @doc """
  Closes a room and removes it from the room list.

  ## Parameters

  - `room_code` - The unique room code

  ## Returns

  - `:ok` - Room closed successfully
  - `{:error, :room_not_found}` - Room doesn't exist

  ## Examples

      :ok = RoomManager.close_room("A1B2")
  """
  @spec close_room(String.t()) :: :ok | {:error, :room_not_found}
  def close_room(room_code) do
    GenServer.call(__MODULE__, {:close_room, String.upcase(room_code)})
  end

  @doc """
  Joins a room as a spectator.

  Spectators can only join rooms that are currently `:playing` or `:finished`.
  They can watch the game but cannot participate.

  ## Parameters

  - `room_code` - The unique room code (case-insensitive)
  - `spectator_id` - User ID of the spectator

  ## Returns

  - `{:ok, room}` - Successfully joined as spectator
  - `{:error, :room_not_found}` - Room code doesn't exist
  - `{:error, :room_not_available_for_spectators}` - Room is not playing or finished
  - `{:error, :spectators_full}` - Maximum spectators reached
  - `{:error, :already_spectating}` - User is already spectating this room
  - `{:error, :already_in_room}` - User is a player in another room

  ## Examples

      {:ok, room} = RoomManager.join_spectator_room("A1B2", "user789")
  """
  @spec join_spectator_room(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error,
             :room_not_found
             | :room_not_available_for_spectators
             | :spectators_full
             | :already_spectating
             | :already_in_room}
  def join_spectator_room(room_code, spectator_id) do
    GenServer.call(__MODULE__, {:join_spectator_room, String.upcase(room_code), spectator_id})
  end

  @doc """
  Removes a spectator from a room.

  ## Parameters

  - `spectator_id` - User ID of the spectator

  ## Returns

  - `:ok` - Successfully left room
  - `{:error, :not_spectating}` - User is not spectating any room

  ## Examples

      :ok = RoomManager.leave_spectator("user789")
  """
  @spec leave_spectator(String.t()) :: :ok | {:error, :not_spectating}
  def leave_spectator(spectator_id) do
    GenServer.call(__MODULE__, {:leave_spectator, spectator_id})
  end

  @doc """
  Checks if a user is a spectator in a specific room.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID to check

  ## Returns

  - `true` - User is spectating the room
  - `false` - User is not spectating the room

  ## Examples

      is_spectator = RoomManager.is_spectator?("A1B2", "user789")
  """
  @spec is_spectator?(String.t(), String.t()) :: boolean()
  def is_spectator?(room_code, user_id) do
    GenServer.call(__MODULE__, {:is_spectator, String.upcase(room_code), user_id})
  end

  @doc """
  Dev-only function to directly set a position without join validation.

  Used by dev UI to populate test scenarios with specific players.
  Allows position changes at any time (waiting, ready, playing, finished).
  Set user_id to nil to clear a seat.

  ## Parameters

  - `room_code` - The unique room code
  - `position` - Position to set (:north, :east, :south, :west)
  - `user_id` - User ID to assign, or nil to clear the seat

  ## Returns

  - `{:ok, room}` - Successfully updated position
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :invalid_position}` - Invalid position atom

  ## Examples

      {:ok, room} = RoomManager.dev_set_position("A1B2", :north, "user123")
      {:ok, room} = RoomManager.dev_set_position("A1B2", :south, nil)
  """
  @spec dev_set_position(String.t(), Positions.position(), String.t() | nil) ::
          {:ok, Room.t()} | {:error, :room_not_found | :invalid_position}
  def dev_set_position(room_code, position, user_id)
      when position in [:north, :east, :south, :west] do
    GenServer.call(__MODULE__, {:dev_set_position, String.upcase(room_code), position, user_id})
  end

  def dev_set_position(_room_code, _position, _user_id) do
    {:error, :invalid_position}
  end

  @doc """
  Handles a player disconnect and starts the reconnection grace period.

  When a player disconnects, they are tracked in the disconnected_players map
  with a timestamp. The player has a 2-minute grace period to reconnect before
  being removed from the room entirely.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID of the disconnected player

  ## Returns

  - `:ok` - Disconnect tracked successfully
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :player_not_in_room}` - Player is not in this room

  ## Examples

      :ok = RoomManager.handle_player_disconnect("A1B2", "user123")
  """
  @spec handle_player_disconnect(String.t(), String.t()) ::
          :ok | {:error, :room_not_found | :player_not_in_room}
  def handle_player_disconnect(room_code, user_id) do
    GenServer.call(__MODULE__, {:player_disconnect, String.upcase(room_code), user_id})
  end

  @doc """
  Handles a player reconnection within the grace period.

  Supports all three phases of the disconnect cascade:
  - Phase 1 (Hiccup): Seat is `:reconnecting` — cancels timer, reclaims seat
  - Phase 2 (Grace): Seat is `:bot_substitute` with `reserved_for` — terminates bot, reclaims seat
  - Phase 3 (Gone): Seat is `:bot_substitute` without `reserved_for` — rejects with `:seat_permanently_filled`

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID of the reconnecting player

  ## Returns

  - `{:ok, room}` - Successfully reconnected
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :player_not_disconnected}` - Player was not marked as disconnected
  - `{:error, :grace_period_expired}` - Grace period has expired (player already removed)
  - `{:error, :seat_permanently_filled}` - Bot is permanent, player must return to lobby

  ## Examples

      {:ok, room} = RoomManager.handle_player_reconnect("A1B2", "user123")
  """
  @spec handle_player_reconnect(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error,
             :room_not_found
             | :player_not_disconnected
             | :grace_period_expired
             | :seat_permanently_filled}
  def handle_player_reconnect(room_code, user_id) do
    GenServer.call(__MODULE__, {:player_reconnect, String.upcase(room_code), user_id})
  end

  @doc """
  Resets the RoomManager state for testing purposes.

  This function is only intended for use in tests to clear all rooms and
  player mappings between test runs.

  ## Returns

  - `:ok` - State reset successfully

  ## Examples

      :ok = RoomManager.reset_for_test()
  """
  @spec reset_for_test() :: :ok
  def reset_for_test do
    GenServer.call(__MODULE__, :reset_for_test)
  end

  if Mix.env() == :test do
    def set_last_activity_for_test(room_code, datetime) do
      GenServer.call(__MODULE__, {:set_last_activity_for_test, room_code, datetime})
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok) do
    Logger.info("RoomManager started")
    schedule_cleanup()
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:create_room, host_id, metadata}, _from, %State{} = state) do
    with :ok <- ensure_not_in_other_room(state, host_id, nil) do
      room_code = generate_room_code()
      now = DateTime.utc_now()

      room = %Room{
        code: room_code,
        host_id: host_id,
        positions: Positions.empty(),
        seats: init_seats(),
        status: :waiting,
        max_players: @max_players,
        created_at: now,
        last_activity: now,
        metadata: metadata
      }

      # Auto-assign host to first available position
      {:ok, room_with_host, host_pos} = Positions.assign(room, host_id, :auto)

      # Update seat for host
      room_with_host = %{
        room_with_host
        | seats:
            Map.put(
              room_with_host.seats,
              host_pos,
              Seat.new_human(host_pos, host_id, is_owner: true)
            )
      }

      %State{} =
        new_state = %State{
          state
          | rooms: Map.put(state.rooms, room_code, room_with_host),
            player_rooms: Map.put(state.player_rooms, host_id, room_code)
        }

      Logger.info("Room created: #{room_code} by host: #{host_id}")
      broadcast_lobby_event({:room_created, room_with_host})

      {:reply, {:ok, room_with_host}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:join_room, room_code, player_id, position}, _from, %State{} = state) do
    with {:ok, room} <- fetch_room(state, room_code),
         :ok <- ensure_not_in_other_room(state, player_id, room_code),
         :ok <- ensure_room_joinable(room),
         {:ok, updated_room, assigned_position} <- Positions.assign(room, player_id, position) do
      # Update seat for the joining player
      {:ok, filled_seat} = Seat.fill_seat(updated_room.seats[assigned_position], player_id)

      updated_room = %{
        updated_room
        | seats: Map.put(updated_room.seats, assigned_position, filled_seat)
      }

      # Update room status and last activity
      final_room =
        updated_room
        |> maybe_set_ready()
        |> touch_last_activity()

      # Update state
      new_state = put_room_and_player(state, final_room, player_id)

      # Log and broadcast
      player_count = Positions.count(final_room)

      Logger.info(
        "Player #{player_id} joined room #{room_code} at position #{assigned_position} (#{player_count}/#{@max_players})"
      )

      broadcast_room(room_code, final_room)
      broadcast_lobby_event({:room_updated, final_room})

      # Auto-start game if room is now ready
      final_state =
        if final_room.status == :ready do
          start_game_for_room(final_room, new_state)
        else
          new_state
        end

      {:reply, {:ok, final_room, assigned_position}, final_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:leave_room, player_id}, _from, %State{} = state) do
    case Map.get(state.player_rooms, player_id) do
      nil ->
        {:reply, {:error, :not_in_room}, state}

      room_code ->
        %Room{} = room = state.rooms[room_code]

        cond do
          # Owner leaving a :playing room — promote ownership, then handle leave
          room.host_id == player_id && room.status == :playing ->
            {room_after_promote, promoted?} =
              case promote_owner(room) do
                {:ok, promoted_room} -> {promoted_room, true}
                {:no_humans, same_room} -> {same_room, false}
              end

            if promoted? do
              # Broadcast owner change
              new_owner_seat =
                Enum.find_value(room_after_promote.seats, fn {pos, s} ->
                  if Seat.owner?(s), do: {pos, s}
                end)

              if new_owner_seat do
                {new_pos, new_seat} = new_owner_seat

                Phoenix.PubSub.broadcast(
                  PidroServer.PubSub,
                  "game:#{room_code}",
                  {:owner_changed, %{new_owner_id: new_seat.user_id, new_owner_position: new_pos}}
                )
              end

              # Remove leaving player from position and vacate seat
              player_position = Positions.get_position(room_after_promote, player_id)
              updated_room = Positions.remove(room_after_promote, player_id)
              updated_room = vacate_seat(updated_room, player_position)
              updated_room = touch_last_activity(updated_room)

              new_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room),
                  player_rooms: Map.delete(state.player_rooms, player_id)
              }

              Logger.info(
                "Owner #{player_id} left :playing room #{room_code}, ownership promoted to #{room_after_promote.host_id}"
              )

              broadcast_room(room_code, updated_room)
              broadcast_lobby_event({:room_updated, updated_room})

              {:reply, :ok, new_state}
            else
              # No humans left, close the room
              Logger.info(
                "Owner #{player_id} left room #{room_code}, no humans remaining, closing room"
              )

              new_state = remove_room(state, room_code)
              {:reply, :ok, new_state}
            end

          # Host leaves non-playing room — close the room entirely
          room.host_id == player_id ->
            Logger.info("Host #{player_id} left room #{room_code}, closing room")
            new_state = remove_room(state, room_code)
            {:reply, :ok, new_state}

          true ->
            # Find player's position and remove them
            player_position = Positions.get_position(room, player_id)
            updated_room = Positions.remove(room, player_id)
            updated_room = vacate_seat(updated_room, player_position)

            # If room becomes empty, delete it
            if Positions.count(updated_room) == 0 do
              Logger.info("Room #{room_code} is now empty, deleting")
              new_state = remove_room(state, room_code)
              {:reply, :ok, new_state}
            else
              # Update room status back to waiting and touch activity
              final_room =
                updated_room
                |> Map.put(:status, :waiting)
                |> touch_last_activity()

              %State{} =
                new_state = %State{
                  state
                  | rooms: Map.put(state.rooms, room_code, final_room),
                    player_rooms: Map.delete(state.player_rooms, player_id)
                }

              Logger.info("Player #{player_id} left room #{room_code}")

              broadcast_room(room_code, final_room)
              broadcast_lobby_event({:room_updated, final_room})

              {:reply, :ok, new_state}
            end
        end
    end
  end

  @impl true
  def handle_call({:list_rooms, filter}, _from, %State{} = state) do
    rooms =
      state.rooms
      |> Map.values()
      |> filter_rooms(filter)

    {:reply, rooms, state}
  end

  @impl true
  def handle_call({:list_lobby, user_id}, _from, %State{} = state) do
    rooms = Map.values(state.rooms)
    lobby = categorize_lobby(rooms, user_id)
    {:reply, lobby, state}
  end

  @impl true
  def handle_call({:get_room, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil -> {:reply, {:error, :room_not_found}, state}
      room -> {:reply, {:ok, room}, state}
    end
  end

  @impl true
  def handle_call({:update_room_status, room_code, new_status}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        %Room{} =
          updated_room = %Room{room | status: new_status, last_activity: DateTime.utc_now()}

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

        Logger.info("Room #{room_code} status updated: #{room.status} -> #{new_status}")

        broadcast_room(room_code, updated_room)
        broadcast_lobby_event({:room_updated, updated_room})

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:close_room, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      _room ->
        Logger.info("Room #{room_code} closed")
        new_state = remove_room(state, room_code)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:join_spectator_room, room_code, spectator_id}, _from, %State{} = state) do
    cond do
      not Map.has_key?(state.rooms, room_code) ->
        {:reply, {:error, :room_not_found}, state}

      Map.has_key?(state.player_rooms, spectator_id) ->
        {:reply, {:error, :already_in_room}, state}

      Map.has_key?(state.spectator_rooms, spectator_id) ->
        # Check if already spectating this specific room
        if state.spectator_rooms[spectator_id] == room_code do
          {:reply, {:error, :already_spectating}, state}
        else
          {:reply, {:error, :already_spectating}, state}
        end

      true ->
        %Room{} = room = state.rooms[room_code]

        cond do
          room.status not in [:playing, :finished] ->
            {:reply, {:error, :room_not_available_for_spectators}, state}

          length(room.spectator_ids) >= room.max_spectators ->
            {:reply, {:error, :spectators_full}, state}

          true ->
            updated_spectator_ids = room.spectator_ids ++ [spectator_id]

            %Room{} =
              updated_room = %Room{
                room
                | spectator_ids: updated_spectator_ids,
                  last_activity: DateTime.utc_now()
              }

            %State{} =
              new_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room),
                  spectator_rooms: Map.put(state.spectator_rooms, spectator_id, room_code)
              }

            Logger.info("Spectator #{spectator_id} joined room #{room_code}")

            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})

            {:reply, {:ok, updated_room}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:leave_spectator, spectator_id}, _from, %State{} = state) do
    case Map.get(state.spectator_rooms, spectator_id) do
      nil ->
        {:reply, {:error, :not_spectating}, state}

      room_code ->
        %Room{} = room = state.rooms[room_code]

        updated_spectator_ids = List.delete(room.spectator_ids, spectator_id)

        %Room{} =
          updated_room = %Room{
            room
            | spectator_ids: updated_spectator_ids,
              last_activity: DateTime.utc_now()
          }

        %State{} =
          new_state = %State{
            state
            | rooms: Map.put(state.rooms, room_code, updated_room),
              spectator_rooms: Map.delete(state.spectator_rooms, spectator_id)
          }

        Logger.info("Spectator #{spectator_id} left room #{room_code}")

        broadcast_room(room_code, updated_room)
        broadcast_lobby_event({:room_updated, updated_room})

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:is_spectator, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, false, state}

      %Room{} = room ->
        is_spectating = user_id in room.spectator_ids
        {:reply, is_spectating, state}
    end
  end

  @impl true
  def handle_call({:dev_set_position, room_code, position, user_id}, _from, %State{} = state) do
    with {:ok, room} <- fetch_room(state, room_code) do
      # Get previous player at this position (if any)
      previous_player = Map.get(room.positions, position)

      # Clear user from any other positions in this room (prevent occupying multiple seats)
      positions_with_user_cleared =
        if user_id do
          room.positions
          |> Enum.map(fn {pos, id} ->
            if id == user_id && pos != position, do: {pos, nil}, else: {pos, id}
          end)
          |> Enum.into(%{})
        else
          room.positions
        end

      # Set the user at the new position
      updated_positions = Map.put(positions_with_user_cleared, position, user_id)

      # Sync seats with updated positions
      updated_seats = build_seats_from_positions(updated_positions, room.host_id)

      # Update room with new positions, seats, and touch activity
      # Note: Only auto-set to :ready if room is in :waiting status
      # This preserves :playing, :finished, etc. statuses for dev testing
      updated_room =
        %{room | positions: updated_positions, seats: updated_seats}
        |> dev_maybe_set_ready()
        |> touch_last_activity()

      # Update player_rooms mapping
      # Remove previous player's mapping if they were replaced
      new_player_rooms =
        if previous_player && previous_player != user_id do
          Map.delete(state.player_rooms, previous_player)
        else
          state.player_rooms
        end

      # Add new player's mapping if not nil
      new_player_rooms =
        if user_id do
          Map.put(new_player_rooms, user_id, room_code)
        else
          new_player_rooms
        end

      new_state = %State{
        state
        | rooms: Map.put(state.rooms, room_code, updated_room),
          player_rooms: new_player_rooms
      }

      Logger.info(
        "Dev set position #{position} in room #{room_code}: #{inspect(previous_player)} -> #{inspect(user_id)}"
      )

      # Broadcast using established pattern
      broadcast_room(room_code, updated_room)
      broadcast_lobby_event({:room_updated, updated_room})

      # Auto-start game if room is now ready (4 players)
      final_state =
        if updated_room.status == :ready do
          start_game_for_room(updated_room, new_state)
        else
          new_state
        end

      # Return the final room from final_state (may have :playing status if auto-started)
      final_room = Map.get(final_state.rooms, room_code, updated_room)

      {:reply, {:ok, final_room}, final_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:player_disconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Only track disconnect if player is actually in the room
        if Positions.has_player?(room, user_id) do
          now = DateTime.utc_now()

          %Room{} =
            updated_room = %Room{
              room
              | disconnected_players: Map.put(room.disconnected_players, user_id, now),
                last_activity: now
            }

          # For :playing rooms, also update seat and start hiccup cascade
          updated_room =
            if room.status == :playing do
              start_hiccup_cascade(updated_room, room_code, user_id)
            else
              updated_room
            end

          %State{} =
            updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          Logger.info(
            "Player #{user_id} disconnected from room #{room_code}, grace period started"
          )

          # Broadcast room update
          broadcast_room(room_code, updated_room)
          broadcast_lobby_event({:room_updated, updated_room})

          # Schedule cleanup check after full grace period (legacy fallback)
          grace_period = get_grace_period_ms()

          Process.send_after(
            self(),
            {:check_disconnect_timeout, room_code, user_id},
            grace_period
          )

          {:reply, :ok, updated_state}
        else
          {:reply, {:error, :player_not_in_room}, state}
        end
    end
  end

  @impl true
  def handle_call({:player_reconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Look up the player's seat across all seats — check both user_id
        # (Phase 1: still on seat) and reserved_for (Phase 2/3: bot took over)
        seat_entry = find_seat_for_user(room, user_id)

        cond do
          # Phase 1 or Phase 2: seat found via user_id or reserved_for
          seat_entry != nil ->
            {position, seat} = seat_entry
            handle_seat_reconnection(room, room_code, user_id, position, seat, state)

          # Phase 3: seat permanently botted — player's position has a bot with no reserved_for
          has_permanently_botted_position?(room, user_id) ->
            Logger.info(
              "Player #{user_id} rejected from room #{room_code} — seat permanently filled"
            )

            {:reply, {:error, :seat_permanently_filled}, state}

          # Legacy fallback: check disconnected_players map
          Map.has_key?(room.disconnected_players, user_id) ->
            disconnect_time = Map.get(room.disconnected_players, user_id)
            grace_period_ms = get_grace_period_ms()

            if DateTime.diff(DateTime.utc_now(), disconnect_time, :millisecond) <= grace_period_ms do
              updated_room = %Room{
                room
                | disconnected_players: Map.delete(room.disconnected_players, user_id),
                  last_activity: DateTime.utc_now()
              }

              updated_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room)
              }

              Logger.info("Player #{user_id} reconnected to room #{room_code} (legacy)")

              broadcast_room(room_code, updated_room)
              broadcast_lobby_event({:room_updated, updated_room})

              {:reply, {:ok, updated_room}, updated_state}
            else
              {:reply, {:error, :grace_period_expired}, state}
            end

          true ->
            {:reply, {:error, :player_not_disconnected}, state}
        end
    end
  end

  if Mix.env() == :test do
    @impl true
    def handle_call({:set_last_activity_for_test, room_code, datetime}, _from, %State{} = state) do
      case Map.get(state.rooms, room_code) do
        nil ->
          {:reply, {:error, :room_not_found}, state}

        %Room{} = room ->
          updated_room = %Room{room | last_activity: datetime}
          updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}
          {:reply, :ok, updated_state}
      end
    end
  end

  @impl true
  def handle_call(:reset_for_test, _from, _state) do
    Logger.info("RoomManager state reset for testing")
    {:reply, :ok, %State{}}
  end

  @impl true
  def handle_info(:cleanup_abandoned_rooms, state) do
    now = DateTime.utc_now()
    grace_period_minutes = 5

    # Check based on internal state only (no Presence dependency)
    # Abandoned = :waiting status + inactive for 5 mins + NO active players/spectators
    updated_state =
      state.rooms
      |> Enum.filter(fn {_code, room} ->
        is_abandoned?(room, now, grace_period_minutes)
      end)
      |> Enum.reduce(state, fn {code, _room}, acc_state ->
        Logger.info("Removing abandoned room #{code}")
        remove_room(acc_state, code)
      end)

    schedule_cleanup()
    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:check_disconnect_timeout, room_code, user_id}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        # Room no longer exists
        {:noreply, state}

      %Room{} = room ->
        # Check if player is still disconnected
        case Map.get(room.disconnected_players, user_id) do
          nil ->
            # Already reconnected, nothing to do
            {:noreply, state}

          disconnect_time ->
            # Check if grace period expired
            grace_period_ms = get_grace_period_ms()

            if DateTime.diff(DateTime.utc_now(), disconnect_time, :millisecond) >= grace_period_ms do
              Logger.info(
                "Player #{user_id} grace period expired for room #{room_code}, removing from room"
              )

              # Remove player from their position and from disconnected list
              updated_room =
                room
                |> Positions.remove(user_id)
                |> Map.put(:disconnected_players, Map.delete(room.disconnected_players, user_id))

              # Update player_rooms
              updated_player_rooms = Map.delete(state.player_rooms, user_id)

              updated_rooms = Map.put(state.rooms, room_code, updated_room)

              %State{} =
                updated_state = %State{
                  state
                  | rooms: updated_rooms,
                    player_rooms: updated_player_rooms
                }

              # Broadcast player removed
              broadcast_room(room_code, updated_room)
              broadcast_lobby(updated_state)
              broadcast_lobby_event({:room_updated, updated_room})

              {:noreply, updated_state}
            else
              # Grace period hasn't expired yet (edge case, shouldn't happen)
              {:noreply, state}
            end
        end
    end
  end

  # Phase 2 handler — hiccup timer fired, spawn substitute bot and start grace countdown.
  @impl true
  def handle_info({:phase2_start, room_code, position}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      %Room{} = room ->
        seat = Map.get(room.seats, position)

        if seat && seat.status == :reconnecting do
          # Calculate remaining grace duration (total grace minus hiccup already elapsed)
          grace_ms = Lifecycle.config(:grace_timeout_ms)
          hiccup_ms = Lifecycle.config(:hiccup_timeout_ms)
          remaining_grace_ms = grace_ms - hiccup_ms
          grace_expires_at = DateTime.add(DateTime.utc_now(), remaining_grace_ms, :millisecond)

          # Transition seat: reconnecting -> grace -> bot_substitute
          {:ok, grace_seat} = Seat.start_grace(seat, grace_expires_at)

          # Spawn substitute bot to play moves for the disconnected player
          {:ok, bot_pid} = SubstituteBot.start(room_code, position)
          {:ok, bot_seat} = Seat.substitute_bot(grace_seat, bot_pid)

          # Schedule Phase 3 (gone/permanent) timer
          timer_ref =
            Process.send_after(self(), {:phase3_gone, room_code, position}, remaining_grace_ms)

          updated_room = %{
            room
            | seats: Map.put(room.seats, position, bot_seat),
              phase_timers: Map.put(room.phase_timers, position, timer_ref)
          }

          updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          # Broadcast bot substitution event
          Phoenix.PubSub.broadcast(
            PidroServer.PubSub,
            "game:#{room_code}",
            {:bot_substitute_active, %{position: position, user_id: seat.user_id}}
          )

          Logger.info(
            "Phase 2 (Grace): Bot substituted at #{position} in room #{room_code} for user #{seat.user_id}"
          )

          {:noreply, updated_state}
        else
          # Player already reconnected or seat state changed, skip
          {:noreply, state}
        end
    end
  end

  # Phase 3 handler — grace period expired, make bot permanent.
  @impl true
  def handle_info({:phase3_gone, room_code, position}, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:noreply, state}

      %Room{} = room ->
        seat = Map.get(room.seats, position)

        if seat && seat.status == :bot_substitute && seat.reserved_for != nil do
          # Make bot permanent — player can no longer reclaim
          {:ok, permanent_seat} = Seat.make_permanent_bot(seat)

          # Clean up phase timer for this position
          updated_room = %{
            room
            | seats: Map.put(room.seats, position, permanent_seat),
              phase_timers: Map.delete(room.phase_timers, position)
          }

          # If this seat was the owner, promote ownership to next connected human
          updated_room =
            if seat.is_owner do
              case promote_owner(updated_room) do
                {:ok, promoted_room} ->
                  Phoenix.PubSub.broadcast(
                    PidroServer.PubSub,
                    "game:#{room_code}",
                    {:owner_changed,
                     %{
                       new_owner_id: promoted_room.host_id,
                       new_owner_position:
                         Enum.find_value(promoted_room.seats, fn {pos, s} ->
                           if Seat.owner?(s), do: pos
                         end)
                     }}
                  )

                  Logger.info(
                    "Ownership promoted to #{promoted_room.host_id} in room #{room_code}"
                  )

                  promoted_room

                {:no_humans, room} ->
                  Logger.info(
                    "No connected humans remaining in room #{room_code} for ownership promotion"
                  )

                  room
              end
            else
              updated_room
            end

          updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          # Broadcast seat permanently botted
          Phoenix.PubSub.broadcast(
            PidroServer.PubSub,
            "game:#{room_code}",
            {:seat_permanently_botted, %{position: position}}
          )

          Logger.info(
            "Phase 3 (Gone): Seat at #{position} in room #{room_code} permanently bot-filled"
          )

          # If the current owner is a connected human, notify them they can open the seat
          maybe_notify_owner_decision(updated_room, room_code, position)

          {:noreply, updated_state}
        else
          # Player already reclaimed or seat state changed, skip
          {:noreply, state}
        end
    end
  end

  ## Private Helper Functions

  @doc false
  defp fetch_room(%State{rooms: rooms}, code) do
    case Map.get(rooms, code) do
      nil -> {:error, :room_not_found}
      room -> {:ok, room}
    end
  end

  @doc false
  defp ensure_not_in_other_room(%State{player_rooms: pr}, player_id, room_code) do
    case Map.get(pr, player_id) do
      nil -> :ok
      ^room_code -> {:error, :already_seated}
      _other -> {:error, :already_in_room}
    end
  end

  @doc false
  defp ensure_room_joinable(%Room{status: status}) when status in [:waiting, :ready], do: :ok
  defp ensure_room_joinable(_), do: {:error, :room_not_available}

  @doc false
  defp maybe_set_ready(%Room{} = room) do
    if Positions.count(room) == @max_players do
      %{room | status: :ready}
    else
      room
    end
  end

  @doc false
  # Dev version that only sets to :ready if currently :waiting
  # This preserves :playing, :finished, etc. for dev testing
  defp dev_maybe_set_ready(%Room{status: :waiting} = room) do
    if Positions.count(room) == @max_players do
      %{room | status: :ready}
    else
      room
    end
  end

  defp dev_maybe_set_ready(%Room{} = room), do: room

  @doc false
  defp touch_last_activity(%Room{} = room) do
    %{room | last_activity: DateTime.utc_now()}
  end

  # Disconnect cascade helpers

  @doc false
  # Starts the hiccup cascade for a disconnected player in a :playing room.
  # Updates the seat to :reconnecting and schedules the Phase 2 timer.
  defp start_hiccup_cascade(%Room{} = room, room_code, user_id) do
    position = Positions.get_position(room, user_id)
    seat = Map.get(room.seats, position)

    case seat && Seat.disconnect(seat) do
      {:ok, disconnected_seat} ->
        hiccup_ms = Lifecycle.config(:hiccup_timeout_ms)

        timer_ref =
          Process.send_after(self(), {:phase2_start, room_code, position}, hiccup_ms)

        # Broadcast player_reconnecting on game PubSub topic
        Phoenix.PubSub.broadcast(
          PidroServer.PubSub,
          "game:#{room_code}",
          {:player_reconnecting, %{user_id: user_id, position: position}}
        )

        %{
          room
          | seats: Map.put(room.seats, position, disconnected_seat),
            phase_timers: Map.put(room.phase_timers, position, timer_ref)
        }

      _ ->
        # Seat not in :connected state or missing, skip cascade
        room
    end
  end

  @doc false
  # Finds a seat that belongs to a user, checking both user_id (Phase 1)
  # and reserved_for (Phase 2/3 where user_id was cleared by bot substitution).
  # Returns {position, seat} or nil.
  defp find_seat_for_user(%Room{seats: seats}, user_id) do
    Enum.find_value(seats, fn {position, seat} ->
      cond do
        seat.user_id == user_id && seat.status == :reconnecting ->
          {position, seat}

        seat.reserved_for == user_id && seat.status in [:grace, :bot_substitute] ->
          {position, seat}

        true ->
          nil
      end
    end)
  end

  @doc false
  # Checks if the user's position (from room.positions) has a permanently-botted seat
  # (Phase 3: :bot_substitute with reserved_for == nil).
  defp has_permanently_botted_position?(%Room{} = room, user_id) do
    case Positions.get_position(room, user_id) do
      nil ->
        false

      position ->
        seat = Map.get(room.seats, position)
        seat != nil && seat.status == :bot_substitute && seat.reserved_for == nil
    end
  end

  @doc false
  # Handles reconnection based on the seat's current cascade phase.
  # Phase 1 (:reconnecting) — cancel timer, reclaim seat
  # Phase 2 (:bot_substitute with reserved_for) — terminate bot, cancel timer, reclaim seat
  # Phase 3 (:bot_substitute without reserved_for) — reject, seat permanently filled
  defp handle_seat_reconnection(room, room_code, user_id, position, seat, %State{} = state) do
    case seat.status do
      :reconnecting ->
        # Phase 1: Cancel timer, reclaim seat
        room = cancel_phase_timer(room, position)

        case Seat.reclaim(seat, user_id) do
          {:ok, reclaimed} ->
            updated_room =
              %{
                room
                | seats: Map.put(room.seats, position, reclaimed),
                  disconnected_players: Map.delete(room.disconnected_players, user_id),
                  last_activity: DateTime.utc_now()
              }

            updated_state = %State{
              state
              | rooms: Map.put(state.rooms, room_code, updated_room)
            }

            Logger.info(
              "Player #{user_id} reconnected during Phase 1 (hiccup) at #{position} in room #{room_code}"
            )

            Phoenix.PubSub.broadcast(
              PidroServer.PubSub,
              "game:#{room_code}",
              {:player_reconnected, %{user_id: user_id, position: position}}
            )

            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})

            {:reply, {:ok, updated_room}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :bot_substitute when seat.reserved_for == user_id ->
        # Phase 2: Terminate bot, cancel timer, reclaim seat
        room = cancel_phase_timer(room, position)

        # Terminate the substitute bot process
        if seat.bot_pid && Process.alive?(seat.bot_pid) do
          DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, seat.bot_pid)
        end

        case Seat.reclaim(seat, user_id) do
          {:ok, reclaimed} ->
            updated_room =
              %{
                room
                | seats: Map.put(room.seats, position, reclaimed),
                  disconnected_players: Map.delete(room.disconnected_players, user_id),
                  last_activity: DateTime.utc_now()
              }

            updated_state = %State{
              state
              | rooms: Map.put(state.rooms, room_code, updated_room)
            }

            Logger.info(
              "Player #{user_id} reclaimed seat from bot during Phase 2 (grace) at #{position} in room #{room_code}"
            )

            Phoenix.PubSub.broadcast(
              PidroServer.PubSub,
              "game:#{room_code}",
              {:player_reclaimed_seat, %{user_id: user_id, position: position}}
            )

            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})

            {:reply, {:ok, updated_room}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :bot_substitute ->
        # Phase 3: Bot is permanent (reserved_for is nil), reject reconnection
        Logger.info(
          "Player #{user_id} rejected from room #{room_code} — seat at #{position} permanently filled"
        )

        {:reply, {:error, :seat_permanently_filled}, state}

      _ ->
        {:reply, {:error, :player_not_disconnected}, state}
    end
  end

  @doc false
  # Cancels the phase timer for a given position if one exists.
  defp cancel_phase_timer(%Room{} = room, position) do
    case Map.get(room.phase_timers, position) do
      nil ->
        room

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{room | phase_timers: Map.delete(room.phase_timers, position)}
    end
  end

  @doc false
  # Notifies the room owner that they can open a permanently-botted seat for a
  # human substitute. Only broadcasts if the owner is a different connected human.
  defp maybe_notify_owner_decision(%Room{} = room, room_code, botted_position) do
    owner_seat =
      room.seats
      |> Map.values()
      |> Enum.find(&Seat.owner?/1)

    if owner_seat &&
         Seat.connected_human?(owner_seat) &&
         owner_seat.position != botted_position do
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:owner_decision_available, %{position: botted_position, owner_id: owner_seat.user_id}}
      )
    end

    :ok
  end

  # Ownership promotion helpers

  @doc false
  # Promotes ownership to the next connected human when the current owner
  # is no longer available (permanently botted or explicitly left).
  #
  # Candidate order: partner first (N↔S, E↔W), then remaining positions
  # sorted by joined_at.
  #
  # Returns {:ok, updated_room} or {:no_humans, room}.
  defp promote_owner(%Room{} = room) do
    owner_entry = Enum.find(room.seats, fn {_pos, seat} -> Seat.owner?(seat) end)

    case owner_entry do
      nil ->
        {:no_humans, room}

      {owner_pos, _owner_seat} ->
        partner_pos = partner_position(owner_pos)
        other_positions = [:north, :east, :south, :west] -- [owner_pos, partner_pos]

        # Sort remaining positions by joined_at (earliest first, nils last)
        sorted_others =
          Enum.sort_by(other_positions, fn pos ->
            case Map.get(room.seats, pos) do
              %{joined_at: %DateTime{} = dt} -> DateTime.to_unix(dt, :microsecond)
              _ -> :infinity
            end
          end)

        candidates = [partner_pos | sorted_others]

        new_owner_pos =
          Enum.find(candidates, fn pos ->
            seat = Map.get(room.seats, pos)
            seat != nil && Seat.connected_human?(seat)
          end)

        case new_owner_pos do
          nil ->
            {:no_humans, room}

          pos ->
            old_owner_seat = Map.get(room.seats, owner_pos)
            new_owner_seat = Map.get(room.seats, pos)

            updated_seats =
              room.seats
              |> Map.put(owner_pos, %{old_owner_seat | is_owner: false})
              |> Map.put(pos, %{new_owner_seat | is_owner: true})

            {:ok, %{room | seats: updated_seats, host_id: new_owner_seat.user_id}}
        end
    end
  end

  @doc false
  defp partner_position(:north), do: :south
  defp partner_position(:south), do: :north
  defp partner_position(:east), do: :west
  defp partner_position(:west), do: :east

  # Seat management helpers

  @doc false
  defp init_seats do
    %{
      north: Seat.new_vacant(:north),
      east: Seat.new_vacant(:east),
      south: Seat.new_vacant(:south),
      west: Seat.new_vacant(:west)
    }
  end

  @doc false
  defp vacate_seat(%Room{seats: seats} = room, position) do
    %{room | seats: Map.put(seats, position, Seat.new_vacant(position))}
  end

  @doc false
  defp build_seats_from_positions(positions, host_id) do
    Map.new(positions, fn {pos, user_id} ->
      seat =
        if user_id do
          Seat.new_human(pos, user_id, is_owner: user_id == host_id)
        else
          Seat.new_vacant(pos)
        end

      {pos, seat}
    end)
  end

  @doc false
  defp put_room_and_player(%State{} = state, %Room{code: code} = room, player_id) do
    %State{
      state
      | rooms: Map.put(state.rooms, code, room),
        player_rooms: Map.put(state.player_rooms, player_id, code)
    }
  end

  @doc false
  defp get_grace_period_ms do
    Application.get_env(:pidro_server, PidroServer.Games.RoomManager)[:grace_period_ms] || 120_000
  end

  @doc false
  @spec remove_room(State.t(), String.t()) :: State.t()
  defp remove_room(%State{} = state, room_code) do
    case Map.get(state.rooms, room_code) do
      nil ->
        state

      room ->
        # Remove room and all player/spectator mappings
        new_rooms = Map.delete(state.rooms, room_code)

        player_ids = Positions.player_ids(room)

        new_player_rooms =
          Enum.reduce(player_ids, state.player_rooms, fn player_id, acc ->
            Map.delete(acc, player_id)
          end)

        new_spectator_rooms =
          Enum.reduce(room.spectator_ids, state.spectator_rooms, fn spectator_id, acc ->
            Map.delete(acc, spectator_id)
          end)

        %State{} =
          new_state = %State{
            state
            | rooms: new_rooms,
              player_rooms: new_player_rooms,
              spectator_rooms: new_spectator_rooms
          }

        broadcast_room(room_code, nil)
        broadcast_lobby_event({:room_closed, room_code})

        new_state
    end
  end

  @doc false
  @spec broadcast_lobby_event(any()) :: :ok
  defp broadcast_lobby_event(event) do
    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "lobby:updates",
      event
    )
  end

  @doc false
  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))
  end

  defp is_abandoned?(room, now, grace_period_minutes) do
    # Check if room is idle
    grace_period_seconds = grace_period_minutes * 60
    is_idle = DateTime.diff(now, room.last_activity, :second) > grace_period_seconds

    # Check if room is effectively empty (all players disconnected or room empty)
    # Note: disconnected players are in positions, so we filter them out
    active_player_count =
      Positions.player_ids(room)
      |> Enum.count(fn id -> !Map.has_key?(room.disconnected_players, id) end)

    active_spectator_count = length(room.spectator_ids)

    room.status == :waiting && is_idle && active_player_count == 0 && active_spectator_count == 0
  end

  @doc false
  @spec generate_room_code() :: String.t()
  defp generate_room_code do
    # Generate a 4-character alphanumeric code
    alphabet = Enum.concat([?A..?Z, ?0..?9])

    1..@room_code_length
    |> Enum.map(fn _ -> Enum.random(alphabet) end)
    |> List.to_string()
  end

  @doc false
  @spec filter_rooms([Room.t()], :all | :waiting | :ready | :playing | :available) :: [Room.t()]
  defp filter_rooms(rooms, :all), do: rooms
  defp filter_rooms(rooms, :waiting), do: Enum.filter(rooms, &(&1.status == :waiting))
  defp filter_rooms(rooms, :ready), do: Enum.filter(rooms, &(&1.status == :ready))
  defp filter_rooms(rooms, :playing), do: Enum.filter(rooms, &(&1.status == :playing))

  defp filter_rooms(rooms, :available) do
    Enum.filter(rooms, &(&1.status in [:waiting, :ready, :playing]))
  end

  @spec categorize_lobby([Room.t()], String.t() | nil) :: %{
          my_rejoinable: [Room.t()],
          open_tables: [Room.t()],
          substitute_needed: [Room.t()],
          spectatable: [Room.t()]
        }
  defp categorize_lobby(rooms, user_id) do
    # Only consider rooms with at least one connected human
    active_rooms = Enum.filter(rooms, &has_connected_human?/1)

    %{
      my_rejoinable: lobby_rejoinable(active_rooms, user_id),
      open_tables: lobby_open_tables(active_rooms),
      substitute_needed: lobby_substitute_needed(active_rooms),
      spectatable: lobby_spectatable(active_rooms)
    }
  end

  defp has_connected_human?(%Room{seats: seats}) when map_size(seats) == 0, do: false

  defp has_connected_human?(%Room{seats: seats}) do
    Enum.any?(seats, fn {_pos, seat} -> Seat.connected_human?(seat) end)
  end

  # Playing rooms where the user has a reserved seat (reconnecting or grace)
  defp lobby_rejoinable(_rooms, nil), do: []

  defp lobby_rejoinable(rooms, user_id) do
    Enum.filter(rooms, fn room ->
      room.status == :playing and
        Enum.any?(room.seats, fn {_pos, seat} ->
          seat_reserved_for_user?(seat, user_id)
        end)
    end)
  end

  # Phase 1: seat is :reconnecting with user_id still set (reserved_for not yet assigned)
  # Phase 2/3: seat is :bot_substitute with reserved_for set by start_grace
  defp seat_reserved_for_user?(%Seat{status: :reconnecting, user_id: uid}, user_id)
       when uid == user_id,
       do: true

  defp seat_reserved_for_user?(%Seat{reserved_for: rf, status: status}, user_id)
       when rf == user_id and status in [:grace, :bot_substitute],
       do: true

  defp seat_reserved_for_user?(_, _), do: false

  # Waiting rooms with vacant seats
  defp lobby_open_tables(rooms) do
    Enum.filter(rooms, fn room ->
      room.status == :waiting and
        Enum.any?(room.seats, fn {_pos, seat} -> Seat.vacant?(seat) end)
    end)
  end

  # Playing rooms with vacant seats (explicitly opened by owner)
  defp lobby_substitute_needed(rooms) do
    Enum.filter(rooms, fn room ->
      room.status == :playing and
        Enum.any?(room.seats, fn {_pos, seat} -> Seat.vacant?(seat) end)
    end)
  end

  # Playing rooms with spectator capacity remaining
  defp lobby_spectatable(rooms) do
    Enum.filter(rooms, fn room ->
      room.status == :playing and
        length(room.spectator_ids) < room.max_spectators
    end)
  end

  @doc false
  @spec broadcast_lobby(State.t()) :: :ok
  defp broadcast_lobby(state) do
    # Broadcast available rooms (excludes finished and closed)
    available_rooms = filter_rooms(Map.values(state.rooms), :available)

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "lobby:updates",
      {:lobby_update, available_rooms}
    )

    :ok
  end

  @doc false
  @spec broadcast_room(String.t(), Room.t() | nil) :: :ok
  defp broadcast_room(room_code, room) do
    event = if room, do: {:room_update, room}, else: {:room_closed}

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "room:#{room_code}",
      event
    )

    :ok
  end

  @doc false
  @spec start_game_for_room(Room.t(), State.t()) :: State.t()
  defp start_game_for_room(%Room{} = room, %State{} = state) do
    player_ids = Positions.player_ids(room)
    Logger.info("Starting game for room #{room.code} with players: #{inspect(player_ids)}")

    case GameSupervisor.start_game(room.code) do
      {:ok, pid} ->
        Logger.info("Game started successfully for room #{room.code}")
        # Update room status to :playing
        %Room{} = updated_room = %Room{room | status: :playing}

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room.code, updated_room)}

        broadcast_room(room.code, updated_room)
        broadcast_lobby_event({:room_updated, updated_room})

        # Broadcast initial game state so bots and channels that joined
        # before the game started receive the first state update.
        broadcast_initial_game_state(room.code, pid)

        new_state

      {:error, reason} ->
        Logger.error("Failed to start game for room #{room.code}: #{inspect(reason)}")
        state
    end
  end

  @spec broadcast_initial_game_state(String.t(), pid()) :: :ok
  defp broadcast_initial_game_state(room_code, pid) do
    try do
      game_state = Pidro.Server.get_state(pid)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, game_state}
      )
    rescue
      e ->
        Logger.error(
          "Failed to broadcast initial game state for room #{room_code}: #{Exception.message(e)}"
        )

        :ok
    end
  end
end
