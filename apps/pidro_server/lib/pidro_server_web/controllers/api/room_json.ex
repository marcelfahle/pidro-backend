defmodule PidroServerWeb.API.RoomJSON do
  @moduledoc """
  JSON view module for rendering room data in API responses.

  This module provides functions to serialize room data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  single room responses, room lists, and room creation responses.
  """

  alias PidroServer.Accounts.Auth
  alias PidroServer.Games.Room.{Positions, Seat}
  alias PidroServerWeb.Serializers.GameStateSerializer

  @doc """
  Renders a single room response.

  Takes a map with a :room key and returns the serialized room data
  wrapped in a data envelope. Optionally includes assigned_position if provided.

  ## Examples

      iex> show(%{room: room})
      %{data: %{room: room_data}}

      iex> show(%{room: room, assigned_position: :north})
      %{data: %{room: room_data, assigned_position: "north"}}
  """
  def show(assigns) do
    data = %{room: room(assigns.room, users_for_rooms([assigns.room]))}
    data = maybe_add_assigned_position(data, assigns)
    %{data: data}
  end

  @doc """
  Renders a list of rooms.

  Takes a map with a :rooms key (list) and returns all serialized room data
  wrapped in a data envelope.

  ## Examples

      iex> index(%{rooms: [room1, room2]})
      %{data: %{rooms: [room_data1, room_data2]}}
  """
  def index(%{rooms: rooms}) do
    %{data: %{rooms: serialize_rooms(rooms)}}
  end

  @doc """
  Renders a room created response with the room code.

  Takes a map with a :room key and returns the serialized room data
  including the room code for quick reference, wrapped in a data envelope.

  ## Examples

      iex> created(%{room: room})
      %{data: %{room: room_data, code: "A1B2"}}
  """
  def created(%{room: room}) do
    %{data: %{room: room(room, users_for_rooms([room])), code: room.code}}
  end

  @doc """
  Renders categorized lobby data.

  Returns rooms grouped into four categories: my_rejoinable, open_tables,
  substitute_needed, and spectatable. Each category contains serialized room data.
  """
  def lobby(%{lobby: lobby}) do
    rooms =
      lobby.my_rejoinable ++ lobby.open_tables ++ lobby.substitute_needed ++ lobby.spectatable

    users = users_for_rooms(rooms)

    %{
      data: %{
        my_rejoinable: serialize_rooms(lobby.my_rejoinable, users),
        open_tables: serialize_rooms(lobby.open_tables, users),
        substitute_needed: serialize_rooms(lobby.substitute_needed, users),
        spectatable: serialize_rooms(lobby.spectatable, users)
      }
    }
  end

  @doc """
  Renders the game state for a room.

  Takes a map with a :state key and returns the serialized game state
  wrapped in a data envelope. The game state is a complex Elixir struct
  from Pidro.Server that contains all game information.

  ## Examples

      iex> state(%{state: game_state})
      %{data: %{state: serialized_state}}
  """
  def state(%{state: game_state}) do
    %{data: %{state: GameStateSerializer.serialize_public(game_state)}}
  end

  @doc """
  Transforms a Room struct into a JSON-serializable map.

  Serializes all room fields including:
  - code: Unique room code
  - host_id: User ID of the room host
  - positions: Map of positions to player IDs
  - available_positions: List of unoccupied positions
  - player_count: Number of seated players
  - spectator_ids: List of spectator user IDs
  - status: Current room status (:waiting, :ready, :playing, :finished, or :closed)
  - max_players: Maximum number of players allowed
  - max_spectators: Maximum number of spectators allowed
  - created_at: Room creation timestamp in ISO8601 format
  """
  def room(%{room: room}), do: room(room)

  def room(room) when is_map(room) do
    room(room, users_for_rooms([room]))
  end

  defp room(room, users) do
    %{
      code: room.code,
      host_id: room.host_id,
      # New fields for position selection feature
      positions: serialize_positions(room.positions),
      available_positions: Positions.available(room),
      player_count: Positions.count(room),
      # Legacy field for backward compatibility - derive from positions
      player_ids: Positions.player_ids(room),
      spectator_ids: room.spectator_ids || [],
      status: room.status,
      max_players: room.max_players,
      max_spectators: room.max_spectators || 10,
      created_at: DateTime.to_iso8601(room.created_at),
      seats: serialize_room_seats(Map.get(room, :seats, %{}), users)
    }
  end

  defp serialize_rooms(rooms), do: serialize_rooms(rooms, users_for_rooms(rooms))
  defp serialize_rooms(rooms, users), do: Enum.map(rooms, &room(&1, users))

  defp users_for_rooms(rooms) do
    rooms
    |> Enum.flat_map(&Positions.player_ids/1)
    |> Enum.uniq()
    |> Auth.get_users_map()
  end

  defp serialize_room_seats(seats, _users) when map_size(seats) == 0, do: %{}

  defp serialize_room_seats(seats, users) do
    Map.new(seats, fn {position, seat} ->
      {position, seat |> Seat.serialize() |> Map.put(:username, seat_username(seat, users))}
    end)
  end

  defp seat_username(%Seat{occupant_type: :bot}, _users), do: "Bot"

  defp seat_username(%Seat{user_id: "bot_" <> _}, _users), do: "Bot"

  defp seat_username(%Seat{user_id: user_id}, users) when is_binary(user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.username
    end
  end

  defp seat_username(_seat, _users), do: nil

  @doc false
  defp serialize_positions(positions) do
    Map.new(positions, fn {pos, player_id} ->
      {pos, player_id}
    end)
  end

  @doc false
  defp maybe_add_assigned_position(data, %{assigned_position: pos}) when not is_nil(pos) do
    Map.put(data, :assigned_position, pos)
  end

  defp maybe_add_assigned_position(data, _), do: data
end
