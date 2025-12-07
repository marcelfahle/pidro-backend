defmodule PidroServerWeb.API.RoomJSON do
  @moduledoc """
  JSON view module for rendering room data in API responses.

  This module provides functions to serialize room data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  single room responses, room lists, and room creation responses.
  """

  alias PidroServer.Games.Room.Positions
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
    data = %{room: room(assigns)}
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
    %{data: %{rooms: Enum.map(rooms, &room/1)}}
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
    %{data: %{room: room(room), code: room.code}}
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
    %{data: %{state: GameStateSerializer.serialize(game_state)}}
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
      created_at: DateTime.to_iso8601(room.created_at)
    }
  end

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
