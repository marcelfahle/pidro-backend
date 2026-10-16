defmodule Pidro.Game.EngineTransitionTest do
  use ExUnit.Case, async: true
  alias Pidro.Core.GameState
  alias Pidro.Core.Types.Player
  alias Pidro.Game.Engine

  test "last hand records applied scores and survives until the next first trick completes" do
    for variant <- [:finnish, :louisiana],
        {bid, scores, made, delta, total, phase} <- [
          {7, %{north_south: 4, east_west: 8}, true, %{north_south: 13, east_west: 1},
           %{north_south: 17, east_west: 9}, :bidding},
          {14, %{north_south: 4, east_west: 8}, false, %{north_south: -14, east_west: 1},
           %{north_south: -10, east_west: 9}, :bidding},
          {7, %{north_south: 50, east_west: 61}, true, %{north_south: 13, east_west: 1},
           %{north_south: 63, east_west: 62}, :complete}
        ] do
      state = final_play_state(variant, bid, scores)
      assert Map.get(state, :last_hand) == nil
      {:ok, scored} = Engine.apply_action(state, :west, {:play_card, {10, :hearts}})

      [first_trick | _] = state.tricks
      [_, final_trick] = scored.last_hand.tricks

      expected = %{
        hand_number: 1,
        bidding_team: :north_south,
        bidder: :south,
        bid: bid,
        captured: %{north_south: 13, east_west: 1},
        made: made,
        delta: delta,
        scores: total,
        point_cards: [
          %{card: {5, :hearts}, points: 5, position: :south, team: :north_south},
          %{card: {5, :diamonds}, points: 5, position: :south, team: :north_south},
          %{card: {14, :hearts}, points: 1, position: :north, team: :north_south},
          %{card: {2, :hearts}, points: 1, position: :east, team: :east_west},
          %{card: {11, :hearts}, points: 1, position: :north, team: :north_south},
          %{card: {10, :hearts}, points: 1, position: :north, team: :north_south}
        ],
        bids: state.bids,
        trump: :hearts,
        tricks: [first_trick, final_trick]
      }

      assert scored.last_hand == expected
      history = [Map.drop(expected, [:bids, :tricks])]
      assert scored.hand_history == history
      assert scored.cumulative_scores == total
      assert scored.phase == phase

      assert Enum.take(scored.events |> Enum.filter(&match?({:hand_scored, _, _}, &1)), -2) ==
               [
                 {:hand_scored, :north_south, delta.north_south},
                 {:hand_scored, :east_west, delta.east_west}
               ]

      if phase == :complete do
        assert scored.winner == :north_south
      else
        assert scored.hand_number == 2
        assert scored.hand_points == %{north_south: 0, east_west: 0}
        assert scored.tricks == []

        before_first_trick =
          Pidro.Test.DeterministicGame.play_until(scored, fn next ->
            assert next.last_hand == expected
            next.current_trick != nil and length(next.current_trick.plays) == 1
          end)

        after_first_trick =
          Pidro.Test.DeterministicGame.play_until(before_first_trick, &(&1.tricks != []))

        assert after_first_trick.last_hand == nil
        assert after_first_trick.hand_history == history
      end
    end
  end

  test "last hand keeps the finished hand's bids, trump and every trick, including the final one" do
    for variant <- [:finnish, :louisiana] do
      state = final_play_state(variant, 7, %{north_south: 4, east_west: 8})
      {:ok, next} = Engine.apply_action(state, :west, {:play_card, {10, :hearts}})

      assert next.hand_number == 2
      assert next.tricks == []
      assert next.bids == []
      assert next.trump_suit == nil

      assert next.last_hand.bids == state.bids
      assert next.last_hand.trump == :hearts

      [cold_trick, final_trick] = next.last_hand.tricks

      # East and north had gone cold, so the first trick has two plays.
      assert cold_trick.number == 1
      assert cold_trick.plays == [{:south, {5, :hearts}}, {:west, {5, :diamonds}}]

      assert final_trick.number == 2

      assert final_trick.plays == [
               {:north, {14, :hearts}},
               {:east, {2, :hearts}},
               {:south, {11, :hearts}},
               {:west, {10, :hearts}}
             ]

      assert final_trick.winner == :north
      assert final_trick.points == 3
      assert final_trick.two_of_trump == %{position: :east, points: 1}
    end
  end

  defp final_play_state(variant, bid, scores) do
    state = GameState.new(seed: 1, variant: variant)

    players =
      Map.new(state.players, fn {position, player} ->
        {position, %{player | hand: if(position == :west, do: [{10, :hearts}], else: [])}}
      end)

    %{
      state
      | phase: :playing,
        players: players,
        trump_suit: :hearts,
        current_turn: :west,
        current_dealer: :north,
        highest_bid: {:south, bid},
        bids: [
          %Pidro.Core.Types.Bid{position: :east, amount: :pass, timestamp: 0},
          %Pidro.Core.Types.Bid{position: :south, amount: bid, timestamp: 1},
          %Pidro.Core.Types.Bid{position: :west, amount: :pass, timestamp: 2},
          %Pidro.Core.Types.Bid{position: :north, amount: :pass, timestamp: 3}
        ],
        bidding_team: :north_south,
        cumulative_scores: scores,
        trick_number: 2,
        tricks: [
          %Pidro.Core.Types.Trick{
            number: 1,
            leader: :south,
            plays: [{:south, {5, :hearts}}, {:west, {5, :diamonds}}]
          }
        ],
        current_trick: %Pidro.Core.Types.Trick{
          number: 2,
          leader: :north,
          plays: [{:north, {14, :hearts}}, {:east, {2, :hearts}}, {:south, {11, :hearts}}]
        }
    }
  end

  test "playing phase automatically transitions to scoring when all hands are empty" do
    # Setup: Game in playing phase, all players eliminated/empty except one who plays last card

    trump = :hearts

    players = %{
      west: %Player{position: :west, team: :east_west, hand: [], eliminated?: true},
      north: %Player{position: :north, team: :north_south, hand: [], eliminated?: true},
      east: %Player{position: :east, team: :east_west, hand: [], eliminated?: true},
      # South has one card left
      south: %Player{
        position: :south,
        team: :north_south,
        hand: [{2, :hearts}],
        eliminated?: false
      }
    }

    # Built from `GameState.new/1` rather than as a bare struct literal: this
    # fixture is played through `:hand_complete`, which shuffles the next
    # hand's deck from `state.chance`. A literal would carry `chance: nil` and
    # fail there.
    state = %{
      GameState.new(seed: 1)
      | phase: :playing,
        trump_suit: trump,
        current_turn: :south,
        players: players,
        current_trick: nil,
        trick_number: 1,
        tricks: [],
        hand_points: %{north_south: 0, east_west: 0},
        events: [],
        highest_bid: {:south, 6},
        bidding_team: :north_south,
        # Needs a dealer for rotation after hand_complete
        current_dealer: :north,
        # Mock deck for this hand; the next hand's deck is shuffled from chance
        deck: Enum.to_list(1..36) |> Enum.map(fn _ -> {2, :hearts} end)
    }

    # South plays the last card
    # This should trigger:
    # 1. play_card -> empty hand -> complete_trick
    # 2. apply_action -> maybe_auto_transition -> handle_automatic_phase(:playing)
    # 3. handle_automatic_phase SHOULD see hands empty -> transition to :scoring
    # 4. handle_automatic_phase(:scoring) -> score the hand -> transition to :hand_complete or :complete

    {:ok, new_state} = Engine.apply_action(state, :south, {:play_card, {2, :hearts}})

    # Verify transitions happened
    # Scoring should have run, hand complete, dealer rotated, new cards dealt, and transitioned to bidding
    assert new_state.phase == :bidding

    # Verify scoring happened (South gets 1 pt for 2H)
    # hand_points were 0, should now be at least 1
    # But actually, `hand_scored` event should be present
    assert Enum.any?(new_state.events, fn
             {:hand_scored, _, _} -> true
             _ -> false
           end)
  end
end
