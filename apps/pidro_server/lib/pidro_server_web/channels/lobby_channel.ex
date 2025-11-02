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
  alias PidroServerWeb.Presence

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

    # Get current available room list (excludes finished and closed)
    rooms = RoomManager.list_rooms(:available)

    # Track presence after join
    send(self(), :after_join)

    {:ok, %{rooms: serialize_rooms(rooms)}, socket}
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
    broadcast(socket, "lobby_update", %{rooms: serialize_rooms(rooms)})
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

  @spec serialize_rooms([RoomManager.Room.t()]) :: [map()]
  defp serialize_rooms(rooms) do
    Enum.map(rooms, &serialize_room/1)
  end

  @spec serialize_room(RoomManager.Room.t()) :: map()
  defp serialize_room(room) do
    %{
      code: room.code,
      host_id: room.host_id,
      player_count: length(room.player_ids),
      max_players: room.max_players,
      status: room.status,
      created_at: DateTime.to_iso8601(room.created_at),
      metadata: room.metadata
    }
  end
end
