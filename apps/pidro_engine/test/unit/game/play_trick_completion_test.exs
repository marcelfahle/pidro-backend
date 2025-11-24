defmodule Pidro.Game.PlayTrickCompletionTest do
  use ExUnit.Case, async: true
  alias Pidro.Core.Types.{Player, GameState}
  alias Pidro.Game.Play

  describe "trick completion with eliminated players" do
    test "trick continues if non-eliminated player hasn't played, even if play count equals active count" do
      # Regression test for bug where trick ended early because:
      # plays (3) >= active_players (3)
      # But the plays included an eliminated player, and excluded an active player.

      # Setup:
      # West: plays and goes cold (eliminated)
      # North: plays
      # East: plays
      # South: active, hasn't played yet

      trump = :hearts
      players = %{
        west: %Player{position: :west, team: :east_west, hand: [], eliminated?: true},
        north: %Player{position: :north, team: :north_south, hand: [{8, :hearts}], eliminated?: false},
        east: %Player{position: :east, team: :east_west, hand: [{10, :hearts}], eliminated?: false},
        south: %Player{position: :south, team: :north_south, hand: [{7, :hearts}], eliminated?: false}
      }

      # Trick history: West (cold), North, East
      current_trick = %Pidro.Core.Types.Trick{
        number: 1,
        leader: :west,
        plays: [
          {:west, {9, :hearts}},
          {:north, {8, :hearts}},
          {:east, {10, :hearts}}
        ]
      }

      state = %GameState{
        phase: :playing,
        trump_suit: trump,
        current_turn: :south, # Should be South's turn
        players: players,
        current_trick: current_trick,
        trick_number: 1,
        tricks: [],
        events: []
      }

      # Verify the trick is NOT considered complete by attempting to play for South
      # If trick was complete, South wouldn't be able to play or it would start a new trick.
      # We'll call the private function indirectly or just verify behavior via play_card.

      {:ok, new_state} = Play.play_card(state, :south, {7, :hearts})

      # Now it should be complete
      assert new_state.current_trick == nil
      assert length(new_state.tricks) == 1
    end
  end
end
