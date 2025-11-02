defmodule Pidro.Game.BiddingLegalActionsTest do
  @moduledoc """
  Tests that legal_actions only returns actions that will actually succeed.
  """
  use ExUnit.Case, async: true

  alias Pidro.Core.Types
  alias Pidro.Core.GameState
  alias Pidro.Game.Bidding

  describe "legal_actions/2 - dealer must bid rule" do
    test "dealer when all others passed cannot pass" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          bids: [
            %Types.Bid{position: :east, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1001},
            %Types.Bid{position: :west, amount: :pass, timestamp: 1002}
          ]
      }

      actions = Bidding.legal_actions(state, :north)

      # Should have bids 6-14 but NOT :pass
      assert {:bid, 6} in actions
      assert {:bid, 14} in actions
      refute :pass in actions
      # Just the 9 bid amounts
      assert length(actions) == 9
    end

    test "dealer when someone bid can pass" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          highest_bid: {:east, 6},
          bids: [
            %Types.Bid{position: :east, amount: 6, timestamp: 1000},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1001},
            %Types.Bid{position: :west, amount: :pass, timestamp: 1002}
          ]
      }

      actions = Bidding.legal_actions(state, :north)

      # Can bid higher or pass
      assert {:bid, 7} in actions
      assert {:bid, 14} in actions
      assert :pass in actions
    end

    test "non-dealer can always pass" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          bids: [
            %Types.Bid{position: :east, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1001}
          ]
      }

      # West is not dealer, can pass
      actions = Bidding.legal_actions(state, :west)

      assert :pass in actions
    end
  end

  describe "legal_actions/2 - bid validation" do
    test "returns bids from min to 14" do
      state = %{
        GameState.new()
        | phase: :bidding,
          bids: []
      }

      actions = Bidding.legal_actions(state, :north)

      # Should have bids 6-14 plus pass
      assert {:bid, 6} in actions
      assert {:bid, 7} in actions
      assert {:bid, 14} in actions
      assert :pass in actions
      # 9 bids + 1 pass
      assert length(actions) == 10
    end

    test "returns bids higher than current bid" do
      state = %{
        GameState.new()
        | phase: :bidding,
          highest_bid: {:east, 10},
          bids: [
            %Types.Bid{position: :east, amount: 10, timestamp: 1000}
          ]
      }

      actions = Bidding.legal_actions(state, :south)

      # Should only have bids 11-14 plus pass
      refute {:bid, 10} in actions
      assert {:bid, 11} in actions
      assert {:bid, 14} in actions
      assert :pass in actions
      # 4 bids (11-14) + 1 pass
      assert length(actions) == 5
    end

    test "returns empty when player already acted" do
      state = %{
        GameState.new()
        | phase: :bidding,
          highest_bid: {:north, 6},
          bids: [
            %Types.Bid{position: :north, amount: 6, timestamp: 1000}
          ]
      }

      # North already bid
      actions = Bidding.legal_actions(state, :north)

      assert actions == []
    end

    test "returns empty when player already passed" do
      state = %{
        GameState.new()
        | phase: :bidding,
          bids: [
            %Types.Bid{position: :north, amount: :pass, timestamp: 1000}
          ]
      }

      # North already passed
      actions = Bidding.legal_actions(state, :north)

      assert actions == []
    end
  end

  describe "legal_actions/2 - property: all returned actions succeed" do
    test "every legal action can be successfully applied" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          bids: []
      }

      # Get legal actions for east
      actions = Bidding.legal_actions(state, :east)

      # Every action should succeed
      for action <- actions do
        result =
          case action do
            {:bid, amount} -> Bidding.apply_bid(state, :east, amount)
            :pass -> Bidding.apply_pass(state, :east)
          end

        assert {:ok, _new_state} = result,
               "Action #{inspect(action)} should succeed but got #{inspect(result)}"
      end
    end

    test "dealer-must-bid scenario: all returned actions succeed" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          bids: [
            %Types.Bid{position: :east, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1001},
            %Types.Bid{position: :west, amount: :pass, timestamp: 1002}
          ]
      }

      # Get legal actions for dealer
      actions = Bidding.legal_actions(state, :north)

      # :pass should NOT be in actions
      refute :pass in actions

      # Every returned action (all bids) should succeed
      for action <- actions do
        {:bid, amount} = action
        result = Bidding.apply_bid(state, :north, amount)
        assert {:ok, _new_state} = result
      end

      # Verify that :pass would fail
      result = Bidding.apply_pass(state, :north)
      assert {:error, :dealer_must_bid} = result
    end
  end
end
