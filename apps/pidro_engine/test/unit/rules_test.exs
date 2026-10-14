defmodule Pidro.RulesTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Game.Bidding
  alias Pidro.Rules.Finnish

  test "Finnish plays only trumps, including the left five, regardless of lead" do
    hand = [{13, :clubs}, {5, :diamonds}, {4, :hearts}, {14, :diamonds}]

    for lead <- [nil, :clubs, :hearts, :diamonds] do
      assert Finnish.legal_plays(hand, :hearts, lead) == [{5, :diamonds}, {4, :hearts}]
    end
  end

  test "Finnish winner ranks the right five above the left five above four" do
    plays = [{:north, {4, :hearts}}, {:east, {5, :diamonds}}, {:south, {5, :hearts}}]
    assert Finnish.winner(plays, :hearts) == :south
    assert Finnish.winner(Enum.take(plays, 2), :hearts) == :east
    assert Finnish.winner(plays ++ [{:west, {6, :hearts}}], :hearts) == :west
  end

  test "Finnish eliminates precisely hands without trumps" do
    assert Finnish.eliminate?([], :hearts)
    assert Finnish.eliminate?([{14, :clubs}], :hearts)
    refute Finnish.eliminate?([{5, :diamonds}], :hearts)
    refute Finnish.eliminate?([{2, :hearts}], :hearts)
  end

  test "Finnish is the default and explicit config overrides win" do
    default = GameState.new(seed: 1)
    assert GameState.new(seed: 1, variant: :finnish) == default
    assert default.config.min_bid == 6

    state = GameState.new(seed: 1, variant: :finnish, config: %{min_bid: 8, max_bid: 10})
    assert state.config == %{default.config | min_bid: 8, max_bid: 10}
    assert Bidding.legal_actions(state, :north) == [{:bid, 8}, {:bid, 9}, {:bid, 10}, :pass]
    assert {:error, {:invalid_bid_amount, 7}} = Bidding.validate_bid(state, :north, 7)
    assert {:error, {:invalid_bid_amount, 11}} = Bidding.validate_bid(state, :north, 11)
  end

  test "three passes force the dealer to bid at least the configured minimum" do
    state = %{GameState.new(seed: 1, config: %{min_bid: 8}) | current_dealer: :north}

    state =
      Enum.reduce([:east, :south, :west], state, fn position, state ->
        {:ok, state} = Bidding.apply_pass(state, position)
        state
      end)

    refute :pass in Bidding.legal_actions(state, :north)
    assert hd(Bidding.legal_actions(state, :north)) == {:bid, 8}
    assert {:error, :dealer_must_bid} = Bidding.apply_pass(state, :north)

    assert {:ok, %{highest_bid: {:north, 8}, phase: :declaring}} =
             Bidding.apply_bid(state, :north, 8)
  end

  test "the configured winning score controls the boundary and bidding-team tie break" do
    state = %{
      GameState.new(seed: 1, config: %{winning_score: 70})
      | cumulative_scores: %{north_south: 69, east_west: 62},
        bidding_team: :east_west
    }

    assert {:error, :game_not_over} = Pidro.Finnish.Scorer.determine_winner(state)

    assert {:ok, :north_south} =
             Pidro.Finnish.Scorer.determine_winner(%{
               state
               | cumulative_scores: %{north_south: 70, east_west: 62}
             })

    assert {:ok, :east_west} =
             Pidro.Finnish.Scorer.determine_winner(%{
               state
               | cumulative_scores: %{north_south: 74, east_west: 70}
             })
  end
end
