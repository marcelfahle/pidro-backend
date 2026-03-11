defmodule PidroServer.Games.Bots.TimeoutStrategy do
  @moduledoc """
  Deterministic timeout auto-play strategy for connected human turn expirations.
  """

  @behaviour PidroServer.Games.Bots.Strategy

  alias Pidro.Core.Card
  alias Pidro.Core.Types

  @impl true
  @spec pick_action([term()], map()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, game_state) do
    action =
      case Map.get(game_state, :phase) do
        :bidding ->
          :pass

        :declaring ->
          pick_declared_trump(legal_actions, game_state)

        :playing ->
          pick_lowest_legal_trump(legal_actions, game_state)

        :second_deal ->
          {:select_hand, :choose_6_cards}

        :dealer_selection ->
          :select_dealer
      end

    {:ok, action, "timeout auto-play"}
  end

  @spec pick_declared_trump([term()], map()) :: term()
  defp pick_declared_trump(legal_actions, game_state) do
    player = Map.get(game_state.players, Map.get(game_state, :current_turn), %{})
    hand = Map.get(player, :hand, [])

    legal_actions
    |> Enum.filter(&match?({:declare_trump, _}, &1))
    |> Enum.max_by(fn {:declare_trump, suit} ->
      {count_suit(hand, suit), total_point_value(hand, suit), suit_rank(suit)}
    end)
  end

  @spec pick_lowest_legal_trump([term()], map()) :: term()
  defp pick_lowest_legal_trump(legal_actions, game_state) do
    trump_suit = Map.fetch!(game_state, :trump_suit)

    legal_actions
    |> Enum.filter(&match?({:play_card, _}, &1))
    |> Enum.map(fn {:play_card, card} -> card end)
    |> lowest_card(trump_suit)
    |> then(&{:play_card, &1})
  end

  @spec lowest_card([Types.card()], Types.suit()) :: Types.card()
  defp lowest_card([first | rest], trump_suit) do
    Enum.reduce(rest, first, fn card, current_lowest ->
      case Card.compare(card, current_lowest, trump_suit) do
        :lt -> card
        _ -> current_lowest
      end
    end)
  end

  @spec count_suit([Types.card()], Types.suit()) :: non_neg_integer()
  defp count_suit(hand, suit) do
    Enum.count(hand, &Card.is_trump?(&1, suit))
  end

  @spec total_point_value([Types.card()], Types.suit()) :: non_neg_integer()
  defp total_point_value(hand, suit) do
    Enum.reduce(hand, 0, fn card, total ->
      total + Card.point_value(card, suit)
    end)
  end

  @spec suit_rank(Types.suit()) :: non_neg_integer()
  defp suit_rank(suit) do
    Types.all_suits()
    |> Enum.find_index(&(&1 == suit))
    |> Kernel.*(-1)
  end
end
