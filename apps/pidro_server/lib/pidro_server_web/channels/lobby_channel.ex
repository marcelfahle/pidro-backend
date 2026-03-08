defmodule PidroServerWeb.LobbyChannel do
  @moduledoc """
  LobbyChannel handles real-time updates for the game lobby.

  The lobby shows available rooms, active games, and player presence.
  All authenticated users can join the lobby channel to see live updates
  when rooms are created, updated, or closed.

  ## Channel Topic

  * `"lobby"` - Global lobby channel

  ## Incoming Events (from client)

  Currently, the lobby is read-only from the client perspective.
  Room creation and joining is done via REST API endpoints.

  ## Outgoing Events (to clients)

  * `"room_created"` - New room available: `%{room: room_data}`
  * `"room_updated"` - Room state changed: `%{room: room_data}`
  * `"room_closed"` - Room no longer available: `%{room_code: code}`
  * `"presence_state"` - Presence information (who's online in lobby)
  * `"presence_diff"` - Presence changes

  ## Examples

      # Join the lobby
      channel.join("lobby", {})
        .receive("ok", ({rooms}) => console.log("Current rooms:", rooms))

      # Listen for new rooms
      channel.on("room_created", ({room}) => addRoomToList(room))

      # Listen for room updates
      channel.on("room_updated", ({room}) => updateRoomInList(room))

      # Listen for room closures
      channel.on("room_closed", ({room_code}) => removeRoomFromList(room_code))
  """

  use PidroServerWeb, :channel
  require Logger

  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.Room.Seat
  alias PidroServerWeb.Presence
  alias PidroServer.Accounts.Auth
  alias PidroServer.Accounts.User

  @doc """
  Joins the lobby channel.

  Any authenticated user can join the lobby. On join:
  - Subscribes to lobby update events via PubSub
  - Tracks user presence in the lobby
  - Returns current list of available rooms
  """
  @impl true
  def join("lobby", _params, socket) do
    # Subscribe to lobby updates
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    user_id = socket.assigns.user_id

    # Get current available room list (excludes finished and closed)
    rooms = RoomManager.list_rooms(:available)

    # Get categorized lobby data for this user
    lobby = RoomManager.list_lobby(user_id)

    # Track presence after join
    send(self(), :after_join)

    {:ok,
     %{
       rooms: serialize_rooms(rooms),
       lobby: serialize_lobby(lobby)
     }, socket}
  end

  @doc """
  Handles internal messages.

  Processes the following events:
  - `:lobby_update` - Room list changed
  - `:after_join` - Presence tracking after join
  """
  @impl true
  def handle_info(msg, socket)

  def handle_info({:lobby_update, rooms}, socket) do
    user_id = socket.assigns.user_id
    lobby = RoomManager.list_lobby(user_id)

    push(socket, "lobby_update", %{
      rooms: serialize_rooms(rooms),
      lobby: serialize_lobby(lobby)
    })

    {:noreply, socket}
  end

  def handle_info({:room_created, room}, socket) do
    serialized = serialize_room_with_users(room)
    category = determine_category(room, socket.assigns.user_id)

    push(socket, "room_created", %{
      room: serialized,
      category: category,
      action: "added"
    })

    {:noreply, socket}
  end

  def handle_info({:room_updated, room}, socket) do
    serialized = serialize_room_with_users(room)
    category = determine_category(room, socket.assigns.user_id)

    push(socket, "room_updated", %{
      room: serialized,
      category: category,
      action: "updated"
    })

    {:noreply, socket}
  end

  def handle_info({:room_closed, room_code}, socket) do
    push(socket, "room_closed", %{
      room_code: room_code,
      action: "removed"
    })

    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    {:ok, _} =
      Presence.track(socket, user_id, %{
        online_at: DateTime.utc_now() |> DateTime.to_unix()
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  ## Private Helpers

  defp serialize_room_with_users(room) do
    alias PidroServer.Games.Room.Positions
    player_ids = Positions.player_ids(room)
    user_map = Auth.get_users_map(player_ids)
    serialize_room(room, user_map)
  end

  @spec serialize_rooms([RoomManager.Room.t()]) :: [map()]
  defp serialize_rooms(rooms) do
    alias PidroServer.Games.Room.Positions
    # Bulk fetch all users involved in these rooms to avoid N+1 queries
    all_player_ids =
      rooms
      |> Enum.flat_map(&Positions.player_ids/1)
      |> Enum.uniq()

    user_map = Auth.get_users_map(all_player_ids)

    Enum.map(rooms, &serialize_room(&1, user_map))
  end

  @spec serialize_room(RoomManager.Room.t(), map()) :: map()
  defp serialize_room(room, user_map) do
    alias PidroServer.Games.Room.Positions

    %{
      code: room.code,
      host_id: room.host_id,
      player_count: Positions.count(room),
      max_players: room.max_players,
      status: room.status,
      created_at: DateTime.to_iso8601(room.created_at),
      metadata: room.metadata,
      seats: serialize_seats(room, user_map)
    }
  end

  defp serialize_seats(room, user_map) do
    [:north, :east, :south, :west]
    |> Enum.with_index()
    |> Enum.map(fn {position, index} ->
      seat = Map.get(room.seats, position)
      player_id = room.positions[position]

      player_data =
        if player_id do
          get_player_summary(player_id, user_map)
        else
          nil
        end

      base = %{
        position: position,
        seat_index: index,
        status: if(player_id, do: "occupied", else: "free"),
        player: player_data
      }

      case seat do
        %Seat{} ->
          seat_data = Seat.serialize(seat)

          Map.merge(base, %{
            occupant_type: seat_data.occupant_type,
            lifecycle_status: seat_data.status,
            is_owner: seat_data.is_owner,
            disconnected_at: seat_data.disconnected_at,
            grace_expires_at: seat_data.grace_expires_at,
            reserved_for: seat_data.reserved_for,
            joined_at: seat_data.joined_at
          })

        nil ->
          base
      end
    end)
  end

  defp serialize_lobby(lobby) do
    %{
      my_rejoinable: serialize_rooms(lobby.my_rejoinable),
      open_tables: serialize_rooms(lobby.open_tables),
      substitute_needed: serialize_rooms(lobby.substitute_needed),
      spectatable: serialize_rooms(lobby.spectatable)
    }
  end

  defp determine_category(room, user_id) do
    cond do
      room.status == :waiting ->
        "open_tables"

      room.status == :playing && has_reserved_seat?(room, user_id) ->
        "my_rejoinable"

      room.status == :playing && has_vacant_seat?(room) ->
        "substitute_needed"

      room.status == :playing ->
        "spectatable"

      true ->
        nil
    end
  end

  defp has_reserved_seat?(room, user_id) do
    Enum.any?(room.seats, fn {_pos, seat} ->
      case seat do
        %Seat{status: :reconnecting, user_id: ^user_id} -> true
        %Seat{reserved_for: ^user_id} when not is_nil(user_id) -> true
        _ -> false
      end
    end)
  end

  defp has_vacant_seat?(room) do
    Enum.any?(room.seats, fn {_pos, seat} ->
      match?(%Seat{occupant_type: :vacant}, seat)
    end)
  end

  defp get_player_summary(player_id, user_map) do
    case Map.get(user_map, player_id) do
      %User{} = user ->
        %{
          id: user.id,
          username: user.username,
          is_bot: false,
          # Placeholder for future avatar implementation
          avatar_url: nil
        }

      nil ->
        # If user not found in DB, assume it's a bot or dev/test user
        %{
          id: player_id,
          username: "Bot/User #{String.slice(player_id, 0..5)}",
          is_bot: true,
          avatar_url: nil
        }
    end
  end
end
