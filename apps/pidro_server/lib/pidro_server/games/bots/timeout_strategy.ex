defmodule PidroServer.Games.Bots.TimeoutStrategy do
  @moduledoc """
  Deterministic timeout auto-play strategy for connected human turn expirations.

  It decides from the timed-out seat's `Pidro.Core.SeatView`, like every
  strategy, and plays passively on purpose: a connected human who goes AFK
  should not have their hand played well for them.
  """

  @behaviour PidroServer.Games.Bots.Strategy

  alias Pidro.Core.{Card, SeatView}
  alias Pidro.Core.Types

  @impl true
  @spec pick_action([term()], SeatView.t()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, %SeatView{} = view) do
    action =
      case view.state.phase do
        :bidding ->
          pick_bid_action(legal_actions)

        :declaring ->
          pick_declared_trump(legal_actions, view)

        :playing ->
          pick_lowest_legal_trump(legal_actions, view.state.trump_suit)

        :second_deal ->
          {:select_hand, :choose_6_cards}

        :dealer_selection ->
          :select_dealer
      end

    {:ok, action, "timeout auto-play"}
  end

  # The dealer cannot pass once the other three players have passed
  # (:dealer_must_bid), so passing is only safe when the engine offers it.
  # Otherwise take the minimum forced bid — never discard the turn.
  @spec pick_bid_action([term()]) :: term()
  defp pick_bid_action(legal_actions) do
    if :pass in legal_actions do
      :pass
    else
      legal_actions
      |> Enum.filter(&match?({:bid, _}, &1))
      |> Enum.min_by(fn {:bid, amount} -> amount end)
    end
  end

  @spec pick_declared_trump([term()], SeatView.t()) :: term()
  defp pick_declared_trump(legal_actions, %SeatView{position: position, state: state}) do
    hand = state.players[position].hand

    legal_actions
    |> Enum.filter(&match?({:declare_trump, _}, &1))
    |> Enum.max_by(fn {:declare_trump, suit} ->
      {count_suit(hand, suit), total_point_value(hand, suit), suit_rank(suit)}
    end)
  end

  @spec pick_lowest_legal_trump([term()], Types.suit()) :: term()
  defp pick_lowest_legal_trump(legal_actions, trump_suit) do
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
