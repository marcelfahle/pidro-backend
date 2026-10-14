defmodule Pidro.Properties.LouisianaPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.Card
  alias Pidro.Game.Engine
  alias Pidro.Test.GameTrace

  property "every Louisiana hand has six four-seat tricks, nobody goes cold, and legal plays follow suit" do
    check all(seed <- integer(1..1_000_000), auto_rob <- boolean(), max_runs: 100) do
      trace = GameTrace.states(seed, variant: :louisiana, auto_dealer_rob: auto_rob)
      final = List.last(trace)
      assert final.phase == :complete
      assert final.cumulative_scores[final.winner] >= 62

      for state <- trace do
        assert Enum.all?(state.players, fn {_seat, player} -> not player.eliminated? end)

        if state.phase == :playing do
          hand = state.players[state.current_turn].hand
          legal = Engine.legal_actions(state, state.current_turn)
          assert legal != []

          led =
            case state.current_trick do
              %{plays: [{_, card} | _]} -> effective_suit(card, state.trump_suit)
              _ -> nil
            end

          eligible =
            Enum.filter(hand, &(effective_suit(&1, state.trump_suit) in [led, state.trump_suit]))

          for {:play_card, card} <- legal do
            assert card in hand

            assert is_nil(led) or eligible == [] or
                     effective_suit(card, state.trump_suit) in [led, state.trump_suit]
          end
        end
      end

      {[], 6} =
        Enum.reduce(final.events, {[], 0}, fn
          {:bidding_complete, _, _}, {[], tricks} ->
            assert tricks in [0, 6]
            {[], 0}

          {:card_played, position, _}, {seats, tricks} ->
            {[position | seats], tricks}

          {:trick_won, _, _}, {seats, tricks} ->
            assert Enum.sort(seats) == [:east, :north, :south, :west]
            {[], tricks + 1}

          {:player_went_cold, _, _}, _ ->
            flunk("Louisiana emitted an elimination event")

          _, acc ->
            acc
        end)
    end
  end

  defp effective_suit({_rank, suit} = card, trump) do
    if Card.is_trump?(card, trump), do: trump, else: suit
  end
end
