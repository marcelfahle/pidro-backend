defmodule PidroServerWeb.Api.RoomJSON do
  @moduledoc """
  JSON view module for rendering room data in API responses.

  This module provides functions to serialize room data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  single room responses, room lists, and room creation responses.
  """

  @doc """
  Renders a single room response.

  Takes a map with a :room key and returns the serialized room data
  wrapped in a data envelope.

  ## Examples

      iex> show(%{room: room})
      %{data: %{room: room_data}}
  """
  def show(%{room: room}) do
    %{data: %{room: data(room)}}
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
    %{data: %{rooms: Enum.map(rooms, &data/1)}}
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
    %{data: %{room: data(room), code: room.code}}
  end

  @doc false
  # Private function to transform a Room struct into a JSON-serializable map.
  #
  # Serializes all room fields including:
  # - code: Unique room code
  # - host_id: User ID of the room host
  # - player_ids: List of player user IDs
  # - status: Current room status (:waiting or :ready)
  # - max_players: Maximum number of players allowed
  # - created_at: Room creation timestamp in ISO8601 format
  defp data(room) do
    %{
      code: room.code,
      host_id: room.host_id,
      player_ids: room.player_ids,
      status: room.status,
      max_players: room.max_players,
      created_at: DateTime.to_iso8601(room.created_at)
    }
  end
end
