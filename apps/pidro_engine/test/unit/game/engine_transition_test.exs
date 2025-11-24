defmodule Pidro.Game.EngineTransitionTest do
  use ExUnit.Case, async: true
  alias Pidro.Core.Types.{Player, GameState}
  alias Pidro.Game.Engine

  test "playing phase automatically transitions to scoring when all hands are empty" do
    # Setup: Game in playing phase, all players eliminated/empty except one who plays last card
    
    trump = :hearts
    players = %{
      west: %Player{position: :west, team: :east_west, hand: [], eliminated?: true},
      north: %Player{position: :north, team: :north_south, hand: [], eliminated?: true},
      east: %Player{position: :east, team: :east_west, hand: [], eliminated?: true},
      # South has one card left
      south: %Player{position: :south, team: :north_south, hand: [{2, :hearts}], eliminated?: false}
    }

    state = %GameState{
      phase: :playing,
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
      current_dealer: :north, # Needs a dealer for rotation after hand_complete
      deck: Enum.to_list(1..36) |> Enum.map(fn _ -> {2, :hearts} end) # Mock deck for next deal
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
