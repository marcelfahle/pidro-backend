defmodule PidroServerWeb.API.RoomJSON do
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
    %{data: %{state: serialize_game_state(game_state)}}
  end

  @doc false
  # Private function to transform a Room struct into a JSON-serializable map.
  #
  # Serializes all room fields including:
  # - code: Unique room code
  # - host_id: User ID of the room host
  # - player_ids: List of player user IDs
  # - spectator_ids: List of spectator user IDs
  # - status: Current room status (:waiting, :ready, :playing, :finished, or :closed)
  # - max_players: Maximum number of players allowed
  # - max_spectators: Maximum number of spectators allowed
  # - created_at: Room creation timestamp in ISO8601 format
  defp data(room) do
    %{
      code: room.code,
      host_id: room.host_id,
      player_ids: room.player_ids,
      spectator_ids: room.spectator_ids || [],
      status: room.status,
      max_players: room.max_players,
      max_spectators: room.max_spectators || 10,
      created_at: DateTime.to_iso8601(room.created_at)
    }
  end

  @doc false
  # Serializes a Pidro game state struct into a JSON-safe map.
  #
  # The game state contains complex Elixir structs and tuples that need to be
  # converted to JSON-safe formats (maps, lists, strings).
  defp serialize_game_state(state) when is_map(state) do
    %{
      phase: state.phase,
      hand_number: Map.get(state, :hand_number),
      variant: Map.get(state, :variant),
      current_turn: Map.get(state, :current_turn),
      current_dealer: Map.get(state, :current_dealer),
      players: serialize_players(Map.get(state, :players, %{})),
      bids: serialize_bids(Map.get(state, :bids, [])),
      highest_bid: serialize_highest_bid(Map.get(state, :highest_bid)),
      bidding_team: Map.get(state, :bidding_team),
      trump_suit: Map.get(state, :trump_suit),
      tricks: serialize_tricks(Map.get(state, :tricks, [])),
      current_trick: serialize_trick(Map.get(state, :current_trick)),
      trick_number: Map.get(state, :trick_number),
      hand_points: Map.get(state, :hand_points, %{}),
      cumulative_scores: Map.get(state, :cumulative_scores, %{}),
      winner: Map.get(state, :winner)
    }
  end

  @doc false
  defp serialize_players(players) when is_map(players) do
    players
    |> Enum.map(fn {position, player} ->
      {position, serialize_player(player)}
    end)
    |> Enum.into(%{})
  end

  @doc false
  defp serialize_player(player) when is_map(player) do
    %{
      position: Map.get(player, :position),
      team: Map.get(player, :team),
      hand: serialize_cards(Map.get(player, :hand, [])),
      tricks_won: Map.get(player, :tricks_won, 0),
      eliminated: Map.get(player, :eliminated?, false)
    }
  end

  @doc false
  defp serialize_cards(cards) when is_list(cards) do
    Enum.map(cards, &serialize_card/1)
  end

  @doc false
  defp serialize_card({rank, suit}) do
    %{rank: rank, suit: suit}
  end

  @doc false
  defp serialize_bids(bids) when is_list(bids) do
    Enum.map(bids, &serialize_bid/1)
  end

  @doc false
  defp serialize_bid(%{position: position, amount: amount}) do
    %{position: position, amount: amount}
  end

  defp serialize_bid(_), do: nil

  @doc false
  defp serialize_highest_bid(nil), do: nil

  defp serialize_highest_bid({position, amount}) do
    %{position: position, amount: amount}
  end

  @doc false
  defp serialize_tricks(tricks) when is_list(tricks) do
    Enum.map(tricks, &serialize_trick/1)
  end

  @doc false
  defp serialize_trick(nil), do: nil

  defp serialize_trick(trick) when is_map(trick) do
    %{
      number: Map.get(trick, :number),
      leader: Map.get(trick, :leader),
      plays: serialize_plays(Map.get(trick, :plays, [])),
      winner: Map.get(trick, :winner),
      points: Map.get(trick, :points, 0)
    }
  end

  @doc false
  defp serialize_plays(plays) when is_list(plays) do
    Enum.map(plays, &serialize_play/1)
  end

  @doc false
  defp serialize_play(%{position: position, card: card}) do
    %{position: position, card: serialize_card(card)}
  end

  defp serialize_play(_), do: nil
end
