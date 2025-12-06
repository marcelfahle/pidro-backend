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

  alias PidroServer.Games.GameSupervisor
  alias PidroServer.Games.Room.Positions

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
      disconnected_players: %{}
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

  If a player reconnects within the 2-minute grace period, they are removed
  from the disconnected_players map and remain in the room.

  ## Parameters

  - `room_code` - The unique room code
  - `user_id` - User ID of the reconnecting player

  ## Returns

  - `{:ok, room}` - Successfully reconnected
  - `{:error, :room_not_found}` - Room doesn't exist
  - `{:error, :player_not_disconnected}` - Player was not marked as disconnected
  - `{:error, :grace_period_expired}` - Grace period has expired (player already removed)

  ## Examples

      {:ok, room} = RoomManager.handle_player_reconnect("A1B2", "user123")
  """
  @spec handle_player_reconnect(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error, :room_not_found | :player_not_disconnected | :grace_period_expired}
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
        status: :waiting,
        max_players: @max_players,
        created_at: now,
        last_activity: now,
        metadata: metadata
      }

      # Auto-assign host to first available position
      {:ok, room_with_host, _pos} = Positions.assign(room, host_id, :auto)

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

        # If host leaves, close the room entirely
        if room.host_id == player_id do
          Logger.info("Host #{player_id} left room #{room_code}, closing room")
          new_state = remove_room(state, room_code)
          {:reply, :ok, new_state}
        else
          # Remove player from their position
          updated_room = Positions.remove(room, player_id)

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
  def handle_call({:player_disconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Only track disconnect if player is actually in the room
        if Positions.has_player?(room, user_id) do
          %Room{} =
            updated_room = %Room{
              room
              | disconnected_players:
                  Map.put(room.disconnected_players, user_id, DateTime.utc_now()),
                last_activity: DateTime.utc_now()
            }

          %State{} =
            updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          Logger.info(
            "Player #{user_id} disconnected from room #{room_code}, grace period started"
          )

          # Broadcast room update
          broadcast_room(room_code, updated_room)
          broadcast_lobby_event({:room_updated, updated_room})

          # Schedule cleanup check after grace period
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
        # Check if player was disconnected
        if Map.has_key?(room.disconnected_players, user_id) do
          # Check if grace period hasn't expired
          disconnect_time = Map.get(room.disconnected_players, user_id)
          grace_period_ms = get_grace_period_ms()

          if DateTime.diff(DateTime.utc_now(), disconnect_time, :millisecond) <= grace_period_ms do
            # Remove from disconnected list
            %Room{} =
              updated_room = %Room{
                room
                | disconnected_players: Map.delete(room.disconnected_players, user_id),
                  last_activity: DateTime.utc_now()
              }

            %State{} =
              updated_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room)
              }

            Logger.info("Player #{user_id} reconnected to room #{room_code}")

            # Broadcast reconnection
            broadcast_room(room_code, updated_room)
            broadcast_lobby_event({:room_updated, updated_room})

            {:reply, {:ok, updated_room}, updated_state}
          else
            {:reply, {:error, :grace_period_expired}, state}
          end
        else
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
  defp touch_last_activity(%Room{} = room) do
    %{room | last_activity: DateTime.utc_now()}
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
      {:ok, _pid} ->
        Logger.info("Game started successfully for room #{room.code}")
        # Update room status to :playing
        %Room{} = updated_room = %Room{room | status: :playing}

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room.code, updated_room)}

        broadcast_room(room.code, updated_room)
        broadcast_lobby_event({:room_updated, updated_room})

        new_state

      {:error, reason} ->
        Logger.error("Failed to start game for room #{room.code}: #{inspect(reason)}")
        state
    end
  end
end
