defmodule PidroServerWeb.Serializers.GameStateSerializer do
  @moduledoc """
  Serializes Pidro game state structs into JSON-safe maps.

  Used by both REST API controllers and WebSocket channels to ensure
  consistent game state representation across all interfaces.
  """

  @doc """
  Serializes a Pidro game state struct into a JSON-safe map.

  Converts complex Elixir structs and tuples (cards, bids, tricks) into
  JSON-compatible formats (maps, lists, strings).

  ## Examples

      iex> serialize(game_state)
      %{phase: :bidding, players: %{...}, ...}
  """
  @spec serialize(map()) :: map()
  def serialize(state) when is_map(state) do
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
      current_trick: serialize_current_trick(Map.get(state, :current_trick)),
      trick_number: Map.get(state, :trick_number),
      hand_points: Map.get(state, :hand_points, %{}),
      scores: Map.get(state, :cumulative_scores, %{}),
      winner: Map.get(state, :winner)
    }
  end

  @doc """
  Serializes a map of players keyed by position.
  """
  @spec serialize_players(map()) :: map()
  def serialize_players(players) when is_map(players) do
    players
    |> Enum.map(fn {position, player} ->
      {position, serialize_player(player)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Serializes a single player struct.
  """
  @spec serialize_player(map()) :: map()
  def serialize_player(player) when is_map(player) do
    %{
      position: Map.get(player, :position),
      team: Map.get(player, :team),
      hand: serialize_cards(Map.get(player, :hand, [])),
      tricks_won: Map.get(player, :tricks_won, 0),
      eliminated: Map.get(player, :eliminated?, false)
    }
  end

  @doc """
  Serializes a list of cards (tuples) into JSON-safe maps.
  """
  @spec serialize_cards(list()) :: list()
  def serialize_cards(cards) when is_list(cards) do
    Enum.map(cards, &serialize_card/1)
  end

  @doc """
  Serializes a card tuple into a map.
  """
  @spec serialize_card({integer(), atom()}) :: map()
  def serialize_card({rank, suit}) do
    %{rank: rank, suit: suit}
  end

  @doc """
  Serializes a list of bids.
  """
  @spec serialize_bids(list()) :: list()
  def serialize_bids(bids) when is_list(bids) do
    Enum.map(bids, &serialize_bid/1)
  end

  @doc """
  Serializes a single bid.
  """
  @spec serialize_bid(map() | any()) :: map() | nil
  def serialize_bid(%{position: position, amount: amount}) do
    %{position: position, amount: amount}
  end

  def serialize_bid(_), do: nil

  @doc """
  Serializes the highest bid tuple.
  """
  @spec serialize_highest_bid({atom(), integer()} | nil) :: map() | nil
  def serialize_highest_bid(nil), do: nil

  def serialize_highest_bid({position, amount}) do
    %{position: position, amount: amount}
  end

  @doc """
  Serializes a list of completed tricks.

  Frontend expects: `[%{cards: [%{player: position, card: card}], winner: position}]`
  """
  @spec serialize_tricks(list()) :: list()
  def serialize_tricks(tricks) when is_list(tricks) do
    Enum.map(tricks, &serialize_trick/1)
  end

  @spec serialize_trick(map() | nil) :: map() | nil
  def serialize_trick(nil), do: nil

  def serialize_trick(trick) when is_map(trick) do
    %{
      cards: serialize_plays(Map.get(trick, :plays, [])),
      winner: Map.get(trick, :winner)
    }
  end

  @doc """
  Serializes the current trick as a flat array of plays.

  Frontend expects: `[%{player: position, card: card}]`
  """
  @spec serialize_current_trick(map() | nil) :: list()
  def serialize_current_trick(nil), do: []

  def serialize_current_trick(trick) when is_map(trick) do
    serialize_plays(Map.get(trick, :plays, []))
  end

  @spec serialize_plays(list()) :: list()
  def serialize_plays(plays) when is_list(plays) do
    plays
    |> Enum.map(&serialize_play/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec serialize_play(tuple() | map() | any()) :: map() | nil
  def serialize_play({position, card}) do
    %{player: position, card: serialize_card(card)}
  end

  def serialize_play(%{position: position, card: card}) do
    %{player: position, card: serialize_card(card)}
  end

  def serialize_play(_), do: nil

  @doc """
  Serializes a list of legal actions from the engine into JSON-safe maps.

  ## Examples

      iex> serialize_legal_actions([{:bid, 7}, :pass])
      [%{type: "bid", amount: 7}, %{type: "pass"}]
  """
  @spec serialize_legal_actions(list()) :: list()
  def serialize_legal_actions(actions) when is_list(actions) do
    Enum.map(actions, &serialize_legal_action/1)
  end

  defp serialize_legal_action({:bid, amount}), do: %{type: "bid", amount: amount}
  defp serialize_legal_action(:pass), do: %{type: "pass"}

  defp serialize_legal_action({:declare_trump, suit}),
    do: %{type: "declare_trump", suit: suit}

  defp serialize_legal_action({:play_card, {rank, suit}}),
    do: %{type: "play_card", card: %{rank: rank, suit: suit}}

  defp serialize_legal_action({:select_hand, _}), do: %{type: "select_hand"}
  defp serialize_legal_action(:select_dealer), do: %{type: "select_dealer"}
  defp serialize_legal_action(action), do: %{type: inspect(action)}
end
