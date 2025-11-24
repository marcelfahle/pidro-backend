defmodule Pidro.Game.PlayTrickLeaderTest do
  use ExUnit.Case, async: true
  alias Pidro.Core.Types.{Player, Trick, GameState}
  alias Pidro.Game.Play

  describe "setting next trick leader" do
    test "if trick winner is eliminated (goes cold), lead passes to next active player clockwise" do
      # Setup:
      # East wins trick but goes cold
      # South is next active player (clockwise from East)
      # West is active
      # North is eliminated

      trump = :hearts

      # East plays winning card (Ace of Hearts) and has no more trumps
      east_hand = [] # Assuming card was just removed
      
      # South has trumps
      south_hand = [{10, :hearts}]

      players = %{
        east: %Player{position: :east, team: :east_west, hand: east_hand, eliminated?: true},
        south: %Player{position: :south, team: :north_south, hand: south_hand, eliminated?: false},
        west: %Player{position: :west, team: :east_west, hand: [{9, :hearts}], eliminated?: false},
        north: %Player{position: :north, team: :north_south, hand: [], eliminated?: true}
      }

      # Trick won by East
      trick = %Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {2, :hearts}}, 
          {:east, {14, :hearts}}, 
          {:south, {5, :hearts}}, # Right 5 (5 pts)
          {:west, {3, :hearts}}
        ]
      }

      state = %GameState{
        phase: :playing,
        trump_suit: trump,
        current_turn: :west, # irrelevant for this test, will be updated
        players: players,
        current_trick: trick,
        trick_number: 1,
        tricks: [],
        hand_points: %{north_south: 0, east_west: 0},
        events: []
      }

      # Calling complete_trick triggers set_next_trick_leader
      {:ok, new_state} = Play.complete_trick(state)

      # East won (Ace beats Right 5 in rank: 14 > 5)
      # But East is eliminated
      # Next active player clockwise from East is South
      
      assert new_state.current_turn == :south
      
      # Verify East got the points
      # Ace(1) + 2(1) + Right5(5) + 3(0) = 7 points
      assert new_state.hand_points.east_west == 7
    end
  end
end
