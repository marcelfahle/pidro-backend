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

  @max_players 4
  @room_code_length 4

  # Room struct representing a game room
  defmodule Room do
    @moduledoc """
    Struct representing a game room.

    ## Fields

    - `:code` - Unique 4-character alphanumeric room code
    - `:host_id` - User ID of the room host (creator)
    - `:player_ids` - List of user IDs currently in the room
    - `:status` - Current room status (`:waiting`, `:ready`, `:playing`, `:finished`, or `:closed`)
    - `:max_players` - Maximum number of players (default: 4)
    - `:created_at` - DateTime when the room was created
    - `:metadata` - Additional room metadata (e.g., room name)
    - `:disconnected_players` - Map of disconnected players with their disconnect timestamps (%{user_id => DateTime.t()})
    """

    @type status :: :waiting | :ready | :playing | :finished | :closed
    @type t :: %__MODULE__{
            code: String.t(),
            host_id: String.t(),
            player_ids: [String.t()],
            status: status(),
            max_players: integer(),
            created_at: DateTime.t(),
            metadata: map(),
            disconnected_players: %{String.t() => DateTime.t()}
          }

    defstruct [
      :code,
      :host_id,
      :player_ids,
      :status,
      :max_players,
      :created_at,
      :metadata,
      disconnected_players: %{}
    ]
  end

  # Internal state struct
  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            rooms: %{String.t() => Room.t()},
            player_rooms: %{String.t() => String.t()}
          }

    defstruct rooms: %{},
              player_rooms: %{}
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

  ## Returns

  - `{:ok, room}` - Successfully joined room
  - `{:error, :room_not_found}` - Room code doesn't exist
  - `{:error, :room_full}` - Room already has 4 players
  - `{:error, :already_in_room}` - Player is already in another room
  - `{:error, :already_in_this_room}` - Player is already in this room

  ## Examples

      {:ok, room} = RoomManager.join_room("A1B2", "user456")
  """
  @spec join_room(String.t(), String.t()) ::
          {:ok, Room.t()}
          | {:error, :room_not_found | :room_full | :already_in_room | :already_in_this_room}
  def join_room(room_code, player_id) do
    GenServer.call(__MODULE__, {:join_room, String.upcase(room_code), player_id})
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

  ## GenServer Callbacks

  @impl true
  def init(:ok) do
    Logger.info("RoomManager started")
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:create_room, host_id, metadata}, _from, %State{} = state) do
    cond do
      Map.has_key?(state.player_rooms, host_id) ->
        {:reply, {:error, :already_in_room}, state}

      true ->
        room_code = generate_room_code()

        room = %Room{
          code: room_code,
          host_id: host_id,
          player_ids: [host_id],
          status: :waiting,
          max_players: @max_players,
          created_at: DateTime.utc_now(),
          metadata: metadata
        }

        %State{} =
          new_state = %State{
            state
            | rooms: Map.put(state.rooms, room_code, room),
              player_rooms: Map.put(state.player_rooms, host_id, room_code)
          }

        Logger.info("Room created: #{room_code} by host: #{host_id}")
        broadcast_lobby(new_state)

        {:reply, {:ok, room}, new_state}
    end
  end

  @impl true
  def handle_call({:join_room, room_code, player_id}, _from, %State{} = state) do
    cond do
      not Map.has_key?(state.rooms, room_code) ->
        {:reply, {:error, :room_not_found}, state}

      Map.has_key?(state.player_rooms, player_id) ->
        # Check if already in this specific room
        if state.player_rooms[player_id] == room_code do
          {:reply, {:error, :already_in_this_room}, state}
        else
          {:reply, {:error, :already_in_room}, state}
        end

      true ->
        %Room{} = room = state.rooms[room_code]

        cond do
          room.status not in [:waiting, :ready] ->
            {:reply, {:error, :room_not_available}, state}

          length(room.player_ids) >= room.max_players ->
            {:reply, {:error, :room_full}, state}

          true ->
            updated_player_ids = room.player_ids ++ [player_id]
            player_count = length(updated_player_ids)

            # Auto-start game when 4th player joins
            new_status = if player_count == @max_players, do: :ready, else: :waiting

            %Room{} =
              updated_room = %Room{
                room
                | player_ids: updated_player_ids,
                  status: new_status
              }

            %State{} =
              new_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room),
                  player_rooms: Map.put(state.player_rooms, player_id, room_code)
              }

            Logger.info(
              "Player #{player_id} joined room #{room_code} (#{player_count}/#{@max_players})"
            )

            broadcast_room(room_code, updated_room)
            broadcast_lobby(new_state)

            # Start game if room is ready
            final_state =
              if new_status == :ready do
                start_game_for_room(updated_room, new_state)
              else
                new_state
              end

            {:reply, {:ok, updated_room}, final_state}
        end
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

          %State{} =
            new_state = %State{
              state
              | rooms: Map.delete(state.rooms, room_code),
                player_rooms: Map.drop(state.player_rooms, room.player_ids)
            }

          broadcast_room(room_code, nil)
          broadcast_lobby(new_state)

          {:reply, :ok, new_state}
        else
          # Remove player from room
          updated_player_ids = List.delete(room.player_ids, player_id)

          # If room becomes empty, delete it
          if Enum.empty?(updated_player_ids) do
            Logger.info("Room #{room_code} is now empty, deleting")

            %State{} =
              new_state = %State{
                state
                | rooms: Map.delete(state.rooms, room_code),
                  player_rooms: Map.delete(state.player_rooms, player_id)
              }

            broadcast_room(room_code, nil)
            broadcast_lobby(new_state)

            {:reply, :ok, new_state}
          else
            %Room{} =
              updated_room = %Room{
                room
                | player_ids: updated_player_ids,
                  status: :waiting
              }

            %State{} =
              new_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room),
                  player_rooms: Map.delete(state.player_rooms, player_id)
              }

            Logger.info("Player #{player_id} left room #{room_code}")

            broadcast_room(room_code, updated_room)
            broadcast_lobby(new_state)

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
        %Room{} = updated_room = %Room{room | status: new_status}

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

        Logger.info("Room #{room_code} status updated: #{room.status} -> #{new_status}")

        broadcast_room(room_code, updated_room)
        broadcast_lobby(new_state)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:close_room, room_code}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      room ->
        # Remove room and all player mappings
        new_rooms = Map.delete(state.rooms, room_code)

        new_player_rooms =
          Enum.reduce(room.player_ids, state.player_rooms, fn player_id, acc ->
            Map.delete(acc, player_id)
          end)

        %State{} =
          new_state = %State{
            state
            | rooms: new_rooms,
              player_rooms: new_player_rooms
          }

        Logger.info("Room #{room_code} closed")

        broadcast_room(room_code, nil)
        broadcast_lobby(new_state)

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:player_disconnect, room_code, user_id}, _from, %State{} = state) do
    case Map.get(state.rooms, room_code) do
      nil ->
        {:reply, {:error, :room_not_found}, state}

      %Room{} = room ->
        # Only track disconnect if player is actually in the room
        if user_id in room.player_ids do
          %Room{} =
            updated_room = %Room{
              room
              | disconnected_players: Map.put(room.disconnected_players, user_id, DateTime.utc_now())
            }

          %State{} =
            updated_state = %State{state | rooms: Map.put(state.rooms, room_code, updated_room)}

          Logger.info("Player #{user_id} disconnected from room #{room_code}, grace period started")

          # Broadcast room update
          broadcast_room(room_code, updated_room)

          # Schedule cleanup check after grace period (2 minutes = 120,000 milliseconds)
          Process.send_after(self(), {:check_disconnect_timeout, room_code, user_id}, 120_000)

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
          grace_period_seconds = 120

          if DateTime.diff(DateTime.utc_now(), disconnect_time) <= grace_period_seconds do
            # Remove from disconnected list
            %Room{} =
              updated_room = %Room{
                room
                | disconnected_players: Map.delete(room.disconnected_players, user_id)
              }

            %State{} =
              updated_state = %State{
                state
                | rooms: Map.put(state.rooms, room_code, updated_room)
              }

            Logger.info("Player #{user_id} reconnected to room #{room_code}")

            # Broadcast reconnection
            broadcast_room(room_code, updated_room)

            {:reply, {:ok, updated_room}, updated_state}
          else
            {:reply, {:error, :grace_period_expired}, state}
          end
        else
          {:reply, {:error, :player_not_disconnected}, state}
        end
    end
  end

  @impl true
  def handle_call(:reset_for_test, _from, _state) do
    Logger.info("RoomManager state reset for testing")
    {:reply, :ok, %State{}}
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
            if DateTime.diff(DateTime.utc_now(), disconnect_time) >= 120 do
              Logger.info(
                "Player #{user_id} grace period expired for room #{room_code}, removing from room"
              )

              # Remove player from room entirely
              %Room{} =
                updated_room = %Room{
                  room
                  | player_ids: List.delete(room.player_ids, user_id),
                    disconnected_players: Map.delete(room.disconnected_players, user_id)
                }

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
    Logger.info("Starting game for room #{room.code} with players: #{inspect(room.player_ids)}")

    case GameSupervisor.start_game(room.code) do
      {:ok, _pid} ->
        Logger.info("Game started successfully for room #{room.code}")
        # Update room status to :playing
        %Room{} = updated_room = %Room{room | status: :playing}

        %State{} =
          new_state = %State{state | rooms: Map.put(state.rooms, room.code, updated_room)}

        broadcast_room(room.code, updated_room)
        broadcast_lobby(new_state)

        new_state

      {:error, reason} ->
        Logger.error("Failed to start game for room #{room.code}: #{inspect(reason)}")
        state
    end
  end
end
