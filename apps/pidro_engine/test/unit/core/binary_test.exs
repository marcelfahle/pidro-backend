defmodule Pidro.Core.BinaryTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Binary
  alias Pidro.Core.GameState

  describe "card decoding" do
    test "rejects the unused rank bit patterns" do
      for rank_bits <- 13..15 do
        assert {:error, :invalid_binary} = Binary.decode_card(<<rank_bits::4, 0::2>>)
      end
    end
  end

  describe "game-state encoding" do
    test "round-trips every field carried by the compact format" do
      state = supported_state()

      assert {:ok, decoded} = state |> Binary.to_binary() |> Binary.from_binary()

      assert decoded.phase == :playing
      assert decoded.hand_number == 12
      assert decoded.current_dealer == :east
      assert decoded.current_turn == :south
      assert decoded.trump_suit == :clubs
      assert decoded.highest_bid == {:west, 11}
      assert decoded.bidding_team == :east_west
      assert decoded.deck == [{10, :clubs}, {2, :spades}]
      assert decoded.cumulative_scores == %{north_south: -7, east_west: 65}

      assert decoded.players.north.hand == [{14, :hearts}, {5, :diamonds}]
      assert decoded.players.north.eliminated?
      assert decoded.players.east.hand == []
      refute decoded.players.east.eliminated?
      assert decoded.players.south.hand == [{9, :clubs}]
      assert decoded.players.west.hand == [{2, :hearts}, {13, :spades}, {6, :diamonds}]
    end

    test "decoding is explicitly lossy and never invents a chance stream" do
      state = supported_state()

      assert {:ok, decoded} = state |> Binary.to_binary() |> Binary.from_binary()

      assert decoded.chance == nil
      assert decoded.bids == []
      assert decoded.tricks == []
      assert decoded.events == []
      assert decoded.dealer_selection_cuts == nil

      assert decoded.config == %{
               min_bid: 6,
               max_bid: 14,
               winning_score: 62,
               initial_deal_count: 9,
               final_hand_size: 6,
               allow_negative_scores: true,
               auto_dealer_rob: true
             }
    end

    test "rejects every truncated prefix" do
      encoded = supported_state() |> Binary.to_binary()

      for size <- 0..(bit_size(encoded) - 1) do
        <<prefix::bitstring-size(^size), _::bitstring>> = encoded
        assert {:error, _reason} = Binary.from_binary(prefix)
      end
    end

    test "rejects invalid header values without raising" do
      <<phase::4, hand_number::8, _dealer::3, rest::bitstring>> =
        supported_state() |> Binary.to_binary()

      invalid_dealer = <<phase::4, hand_number::8, 7::3, rest::bitstring>>

      assert {:error, _reason} = Binary.from_binary(invalid_dealer)
    end

    test "rejects trailing data" do
      encoded = supported_state() |> Binary.to_binary()

      assert {:error, _reason} = Binary.from_binary(<<encoded::bitstring, 1::1>>)
    end
  end

  defp supported_state do
    state = GameState.new(seed: 42)

    players = %{
      state.players
      | north: %{
          state.players.north
          | hand: [{14, :hearts}, {5, :diamonds}],
            eliminated?: true,
            revealed_cards: [{3, :clubs}],
            tricks_won: 2
        },
        south: %{state.players.south | hand: [{9, :clubs}]},
        west: %{
          state.players.west
          | hand: [{2, :hearts}, {13, :spades}, {6, :diamonds}]
        }
    }

    %{
      state
      | phase: :playing,
        hand_number: 12,
        current_dealer: :east,
        current_turn: :south,
        players: players,
        deck: [{10, :clubs}, {2, :spades}],
        highest_bid: {:west, 11},
        bidding_team: :east_west,
        trump_suit: :clubs,
        cumulative_scores: %{north_south: -7, east_west: 65},
        dealer_selection_cuts: %{north: {7, :hearts}},
        events: [{:trump_declared, :clubs}],
        config: %{state.config | winning_score: 100}
    }
  end
end
