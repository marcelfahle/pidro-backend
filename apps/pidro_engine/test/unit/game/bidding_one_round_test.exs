defmodule Pidro.Game.BiddingOneRoundTest do
  @moduledoc """
  Tests for CORRECT Finnish Pidro bidding rules:

  - Bidding goes around the table ONCE
  - Each player gets ONE chance to bid or pass
  - Dealer bids last
  - When dealer is done, bidding is complete
  - Special rule: If all 3 players pass, dealer MUST bid 6 (cannot pass)
  """
  use ExUnit.Case, async: true

  alias Pidro.Core.Types
  alias Pidro.Core.GameState
  alias Pidro.Game.Bidding

  describe "One-round bidding (correct Finnish rules)" do
    test "bidding completes after dealer's turn (all 4 players acted)" do
      # Dealer is west, so order is: north, east, south, west (dealer last)
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :north,
          bids: []
      }

      # North bids 6
      {:ok, state} = Bidding.apply_bid(state, :north, 6)
      assert state.phase == :bidding
      assert state.current_turn == :east

      # East passes
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :east}, :east)
      assert state.phase == :bidding
      assert state.current_turn == :south

      # South passes
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :south}, :south)
      assert state.phase == :bidding
      assert state.current_turn == :west

      # West (dealer) passes - should complete bidding
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :west}, :west)

      assert state.phase == :declaring,
             "Bidding should complete after dealer's turn"

      assert state.highest_bid == {:north, 6}
    end

    test "player cannot bid twice (one round only)" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :north,
          bids: [
            %Types.Bid{position: :north, amount: 6, timestamp: 1000}
          ],
          highest_bid: {:north, 6}
      }

      # North already bid, cannot bid again
      result = Bidding.apply_bid(state, :north, 7)
      assert {:error, {:already_acted, :north}} = result
    end

    test "player cannot pass twice (one round only)" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :north,
          bids: [
            %Types.Bid{position: :north, amount: :pass, timestamp: 1000}
          ]
      }

      # North already passed, cannot pass again
      result = Bidding.apply_pass(state, :north)
      assert {:error, {:already_acted, :north}} = result
    end

    test "player who bid cannot pass later (one action per player)" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :north,
          bids: [
            %Types.Bid{position: :north, amount: 6, timestamp: 1000}
          ],
          highest_bid: {:north, 6}
      }

      # North already bid, cannot pass
      result = Bidding.apply_pass(state, :north)
      assert {:error, {:already_acted, :north}} = result
    end
  end

  describe "Dealer must bid 6 rule" do
    test "if all 3 players pass, dealer cannot pass" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :west,
          bids: [
            %Types.Bid{position: :north, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :east, amount: :pass, timestamp: 1001},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1002}
          ]
      }

      # Dealer cannot pass when all others passed
      result = Bidding.apply_pass(state, :west)
      assert {:error, :dealer_must_bid} = result
    end

    test "dealer can pass if someone else bid" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :west,
          bids: [
            %Types.Bid{position: :north, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :east, amount: 6, timestamp: 1001},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1002}
          ],
          highest_bid: {:east, 6}
      }

      # Dealer CAN pass because someone else bid
      {:ok, new_state} = Bidding.apply_pass(state, :west)
      assert new_state.phase == :declaring
      assert new_state.highest_bid == {:east, 6}
    end

    test "if all pass, dealer is forced to bid 6" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :west,
          current_turn: :west,
          bids: [
            %Types.Bid{position: :north, amount: :pass, timestamp: 1000},
            %Types.Bid{position: :east, amount: :pass, timestamp: 1001},
            %Types.Bid{position: :south, amount: :pass, timestamp: 1002}
          ]
      }

      # Dealer must bid 6
      {:ok, new_state} = Bidding.apply_bid(state, :west, 6)
      assert new_state.phase == :declaring
      assert new_state.highest_bid == {:west, 6}
    end
  end

  describe "Full one-round scenarios" do
    test "scenario: first player bids, others pass, dealer passes" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :south,
          current_turn: :west,
          bids: []
      }

      {:ok, state} = Bidding.apply_bid(state, :west, 8)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :north}, :north)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :east}, :east)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :south}, :south)

      assert state.phase == :declaring
      assert state.highest_bid == {:west, 8}
    end

    test "scenario: bidding war, highest bidder wins after dealer's turn" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          current_turn: :east,
          bids: []
      }

      {:ok, state} = Bidding.apply_bid(state, :east, 6)
      {:ok, state} = Bidding.apply_bid(%{state | current_turn: :south}, :south, 8)
      {:ok, state} = Bidding.apply_bid(%{state | current_turn: :west}, :west, 10)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :north}, :north)

      assert state.phase == :declaring
      assert state.highest_bid == {:west, 10}
    end

    test "scenario: all pass, dealer forced to bid 6" do
      state = %{
        GameState.new()
        | phase: :bidding,
          current_dealer: :north,
          current_turn: :east,
          bids: []
      }

      {:ok, state} = Bidding.apply_pass(state, :east)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :south}, :south)
      {:ok, state} = Bidding.apply_pass(%{state | current_turn: :west}, :west)

      # Dealer cannot pass - must bid 6
      # This should be automatic or return error if they try to pass
      assert state.current_turn == :north
      assert state.phase == :bidding

      # Trying to pass should fail
      result = Bidding.apply_pass(%{state | current_turn: :north}, :north)
      assert {:error, :dealer_must_bid} = result

      # Must bid at least 6
      {:ok, state} = Bidding.apply_bid(%{state | current_turn: :north}, :north, 6)
      assert state.phase == :declaring
      assert state.highest_bid == {:north, 6}
    end
  end
end
