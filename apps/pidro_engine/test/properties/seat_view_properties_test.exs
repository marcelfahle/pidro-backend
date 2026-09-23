defmodule Pidro.Properties.SeatViewPropertiesTest do
  @moduledoc """
  Leak-freedom of the seat view, checked in every state of seeded random games.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.SeatView
  alias Pidro.Core.Types.GameState
  alias Pidro.Test.GameTrace

  @positions [:north, :east, :south, :west]

  @tag :property
  property "no hidden card appears anywhere in any seat's view" do
    check all(
            seed <- StreamData.integer(1..1_000_000),
            auto_rob <- StreamData.boolean(),
            max_runs: 200
          ) do
      for state <- GameTrace.states(seed, auto_dealer_rob: auto_rob),
          position <- @positions do
        view = SeatView.for_seat(state, position)
        leaked = MapSet.intersection(hidden_cards(state, position), visible_cards(view))

        assert MapSet.size(leaked) == 0,
               "#{position} sees #{inspect(MapSet.to_list(leaked))} in #{state.phase}"
      end
    end
  end

  @tag :property
  property "states that differ only in hidden cards give equal views" do
    check all(seed <- StreamData.integer(1..1_000_000), max_runs: 200) do
      for state <- GameTrace.states(seed, auto_dealer_rob: rem(seed, 2) == 0),
          position <- @positions do
        reshuffled = reshuffle_hidden(state, position)

        assert SeatView.for_seat(state, position) == SeatView.for_seat(reshuffled, position)
      end
    end
  end

  # Cards the seat must not see: other hands, the deck and the discards. The
  # dealer legitimately sees the deck while robbing manually.
  defp hidden_cards(%GameState{} = state, position) do
    other_hands =
      for {pos, player} <- state.players, pos != position, card <- player.hand, do: card

    deck = if dealer_sees_deck?(state, position), do: [], else: state.deck

    MapSet.new(other_hands ++ deck ++ state.discarded_cards)
  end

  # Dealer-selection cuts are drawn independently of the deck, so they can
  # equal a hidden card by coincidence. They are public and are left out.
  defp visible_cards(%SeatView{} = view) do
    collect_cards(%{view | dealer_selection_cuts: nil}, MapSet.new())
  end

  defp collect_cards({rank, suit} = card, acc)
       when rank in 2..14 and suit in [:hearts, :diamonds, :clubs, :spades],
       do: MapSet.put(acc, card)

  defp collect_cards(term, acc) when is_struct(term),
    do: term |> Map.from_struct() |> collect_cards(acc)

  defp collect_cards(term, acc) when is_map(term),
    do:
      Enum.reduce(term, acc, fn {key, value}, inner ->
        collect_cards(value, collect_cards(key, inner))
      end)

  defp collect_cards(term, acc) when is_list(term), do: Enum.reduce(term, acc, &collect_cards/2)

  defp collect_cards(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_cards(acc)

  defp collect_cards(_term, acc), do: acc

  # Deals the hidden cards out again at random, keeping every pile's size.
  defp reshuffle_hidden(%GameState{} = state, position) do
    others = for {pos, _player} <- state.players, pos != position, do: pos
    keep_deck? = dealer_sees_deck?(state, position)
    deck = if keep_deck?, do: [], else: state.deck

    pool =
      Enum.shuffle(
        Enum.flat_map(others, &state.players[&1].hand) ++ deck ++ state.discarded_cards
      )

    {players, pool} =
      Enum.reduce(others, {state.players, pool}, fn pos, {players, rest} ->
        {hand, rest} = Enum.split(rest, length(players[pos].hand))
        {put_in(players[pos].hand, hand), rest}
      end)

    {new_deck, discards} =
      if keep_deck?, do: {state.deck, pool}, else: Enum.split(pool, length(state.deck))

    %{state | players: players, deck: new_deck, discarded_cards: discards}
  end

  defp dealer_sees_deck?(%GameState{} = state, position) do
    state.phase == :second_deal and state.current_dealer == position and
      not Map.get(state.config, :auto_dealer_rob, true)
  end
end
