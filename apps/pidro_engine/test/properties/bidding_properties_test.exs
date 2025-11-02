defmodule Pidro.Properties.BiddingPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.Types
  alias Pidro.Core.GameState
  alias Pidro.Game.Bidding

  @positions [:north, :east, :south, :west]

  # Generator for a valid bid amount (6-14 or :pass)
  defp bid_amount_gen do
    frequency([
      {7, integer(6..14)},
      {3, constant(:pass)}
    ])
  end

  # Generator for a bid record
  defp bid_gen(position, amount, timestamp) do
    %Types.Bid{
      position: position,
      amount: amount,
      timestamp: timestamp
    }
  end

  # Generator for a sequence of bids (exactly 4 bids - one per player in Finnish Pidro)
  defp bid_sequence_gen do
    gen all(
          # Generate a random starting position
          start_pos <- member_of(@positions),
          # Generate amounts for each of the 4 players
          amounts <- list_of(bid_amount_gen(), length: 4)
        ) do
      # Get positions in clockwise order starting from start_pos
      start_idx = Enum.find_index(@positions, &(&1 == start_pos))
      positions = Enum.map(0..3, fn i -> Enum.at(@positions, rem(start_idx + i, 4)) end)

      # Create bids for each position
      positions
      |> Enum.zip(amounts)
      |> Enum.with_index()
      |> Enum.map(fn {{pos, amt}, idx} ->
        bid_gen(pos, amt, 1000 + idx)
      end)
    end
  end

  describe "Property: bidding completion invariants" do
    property "bidding is never complete with no bids" do
      check all(_irrelevant <- integer()) do
        state = %{GameState.new() | bids: [], highest_bid: nil}
        refute Bidding.bidding_complete?(state)
      end
    end

    property "bidding is always complete when highest bid is 14" do
      check all(bids <- bid_sequence_gen()) do
        state = %{GameState.new() | bids: bids, highest_bid: {:north, 14}}
        assert Bidding.bidding_complete?(state)
      end
    end

    property "bidding is complete when all 4 players have acted" do
      check all(
              bids <- bid_sequence_gen(),
              max_runs: 50
            ) do
        # Get highest bid from bids list
        highest_bid_entry =
          bids
          |> Enum.filter(fn b -> b.amount != :pass end)
          |> Enum.max_by(fn b -> b.amount end, fn -> nil end)

        highest_bid =
          if highest_bid_entry do
            {highest_bid_entry.position, highest_bid_entry.amount}
          else
            nil
          end

        state = %{GameState.new() | bids: bids, highest_bid: highest_bid}

        # With exactly 4 bids, bidding should always be complete
        assert Bidding.bidding_complete?(state),
               """
               Bidding should be complete with 4 bids:
               Bids: #{inspect(bids)}
               Highest bid: #{inspect(highest_bid)}
               """
      end
    end

    property "bidding is not complete with fewer than 4 bids" do
      check all(
              bid_amount <- integer(6..13),
              bid_count <- integer(1..3),
              max_runs: 20
            ) do
        # Generate bid_count bids in clockwise order starting from north
        positions = [:north, :east, :south, :west]

        bids =
          Enum.map(0..(bid_count - 1), fn i ->
            pos = Enum.at(positions, i)
            # First bid is the actual bid, rest are passes
            amount = if i == 0, do: bid_amount, else: :pass
            bid_gen(pos, amount, 1000 + i)
          end)

        highest = {:north, bid_amount}
        state = %{GameState.new() | bids: bids, highest_bid: highest}

        refute Bidding.bidding_complete?(state),
               "Should not be complete with only #{bid_count} bids (need 4)"
      end
    end

    property "bidding is complete with exactly 3 trailing passes" do
      check all(
              bid_amount <- integer(6..13),
              max_runs: 20
            ) do
        bids = [
          bid_gen(:north, bid_amount, 1000),
          bid_gen(:east, :pass, 1001),
          bid_gen(:south, :pass, 1002),
          bid_gen(:west, :pass, 1003)
        ]

        state = %{GameState.new() | bids: bids, highest_bid: {:north, bid_amount}}

        assert Bidding.bidding_complete?(state),
               "Should be complete with 3 consecutive passes"
      end
    end

    property "bidding completion is order-based, not timestamp-based" do
      check all(
              bid_amount <- integer(6..13),
              # Generate random timestamps that may not be in order
              ts1 <- integer(1..10000),
              ts2 <- integer(1..10000),
              ts3 <- integer(1..10000),
              ts4 <- integer(1..10000),
              max_runs: 20
            ) do
        # List order determines completion, not timestamp order
        bids = [
          bid_gen(:north, bid_amount, ts1),
          bid_gen(:east, :pass, ts2),
          bid_gen(:south, :pass, ts3),
          bid_gen(:west, :pass, ts4)
        ]

        state = %{GameState.new() | bids: bids, highest_bid: {:north, bid_amount}}

        # Should be complete regardless of timestamp values
        assert Bidding.bidding_complete?(state),
               """
               Should be complete based on list order, not timestamps:
               Timestamps: [#{ts1}, #{ts2}, #{ts3}, #{ts4}]
               """
      end
    end
  end

  describe "Property: apply_bid transition behavior" do
    property "applying first bid never completes bidding (unless bid is 14)" do
      check all(
              bid_amount <- integer(6..13),
              position <- member_of(@positions),
              max_runs: 20
            ) do
        state = %{
          GameState.new()
          | phase: :bidding,
            current_turn: position,
            bids: [],
            highest_bid: nil,
            current_dealer: :west
        }

        {:ok, new_state} = Bidding.apply_bid(state, position, bid_amount)

        assert new_state.phase == :bidding,
               "First bid should not complete bidding (bid: #{bid_amount})"

        assert new_state.highest_bid == {position, bid_amount}
      end
    end

    property "bidding transitions to declaring after 3 consecutive passes" do
      check all(
              first_bidder <- member_of(@positions),
              bid_amount <- integer(6..13),
              max_runs: 10
            ) do
        # Build state with one bid and advance through 3 passes
        initial_state = %{
          GameState.new()
          | phase: :bidding,
            current_dealer: :west,
            bids: []
        }

        # First bid
        {:ok, state1} =
          Bidding.apply_bid(
            %{initial_state | current_turn: first_bidder},
            first_bidder,
            bid_amount
          )

        assert state1.phase == :bidding

        # First pass
        next_pos1 = Types.next_position(first_bidder)
        {:ok, state2} = Bidding.apply_pass(%{state1 | current_turn: next_pos1}, next_pos1)
        assert state2.phase == :bidding

        # Second pass
        next_pos2 = Types.next_position(next_pos1)
        {:ok, state3} = Bidding.apply_pass(%{state2 | current_turn: next_pos2}, next_pos2)
        assert state3.phase == :bidding

        # Third pass - should complete
        next_pos3 = Types.next_position(next_pos2)
        {:ok, state4} = Bidding.apply_pass(%{state3 | current_turn: next_pos3}, next_pos3)

        assert state4.phase == :declaring,
               "After 3 passes, phase should be :declaring"
      end
    end
  end
end
