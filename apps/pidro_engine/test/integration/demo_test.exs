defmodule Pidro.DemoTest do
  @moduledoc """
  Integration tests for IEx demo functions.
  """
  use ExUnit.Case, async: true

  alias Pidro.Core.Types
  alias Pidro.Game.Engine
  alias Pidro.IEx

  describe "demo_game/0" do
    test "completes without crashing" do
      # Capture IO to prevent test output clutter
      ExUnit.CaptureIO.capture_io(fn ->
        # Run demo game - should not crash
        state = IEx.demo_game()

        # Verify we get a valid game state back
        assert %Types.GameState{} = state

        # Game should reach some phase (not necessarily complete)
        assert state.phase in [
                 :dealer_selection,
                 :dealing,
                 :bidding,
                 :declaring,
                 :discarding,
                 :second_deal,
                 :playing,
                 :scoring,
                 :complete
               ]
      end)
    end

    test "handles edge cases during bidding" do
      # This test specifically targets the bug where legal_actions might be empty
      ExUnit.CaptureIO.capture_io(fn ->
        # Start a new game
        state = IEx.new_game()

        # Verify we're in bidding phase
        assert state.phase == :bidding

        # For each position, legal_actions should never be empty during their turn
        positions = [:north, :east, :south, :west]

        Enum.each(positions, fn pos ->
          if pos == state.current_turn do
            actions = Engine.legal_actions(state, pos)
            # Should have at least one action (bid or pass)
            assert length(actions) > 0, "No legal actions for #{pos} on their turn"
          end
        end)
      end)
    end

    test "legal_actions returns empty list when not player's turn" do
      ExUnit.CaptureIO.capture_io(fn ->
        state = IEx.new_game()

        # Get positions that are NOT current turn
        other_positions = [:north, :east, :south, :west] -- [state.current_turn]

        # All other positions should have no legal actions
        Enum.each(other_positions, fn pos ->
          actions = Engine.legal_actions(state, pos)

          assert actions == [],
                 "Expected no actions for #{pos} when not their turn, got: #{inspect(actions)}"
        end)
      end)
    end
  end

  describe "new_game/0" do
    test "creates a valid initial game state" do
      ExUnit.CaptureIO.capture_io(fn ->
        state = IEx.new_game()

        # Should be a valid game state
        assert %Types.GameState{} = state

        # Should have selected dealer
        assert state.current_dealer in [:north, :east, :south, :west]

        # Should be in bidding phase
        assert state.phase == :bidding

        # All players should have 9 cards
        assert map_size(state.players) == 4

        Enum.each(state.players, fn {_pos, player} ->
          assert length(player.hand) == 9
        end)
      end)
    end
  end
end
