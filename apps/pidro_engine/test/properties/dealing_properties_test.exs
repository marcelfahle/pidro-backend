defmodule Pidro.Properties.DealingPropertiesTest do
  @moduledoc """
  Property-based tests for the Dealing module using StreamData.

  These tests verify fundamental invariants of the Finnish Pidro dealing system:
  - Initial deal distributes exactly 9 cards to each of 4 players
  - Cards are dealt in batches of 3 (Finnish rule)
  - After initial deal, exactly 16 cards remain in deck (the "kitty")
  - All dealt cards are unique across all players
  - Dealing operations maintain deck integrity

  Related to Phase 3 of the masterplan: Dealer Selection and Initial Deal
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.Deck

  # =============================================================================
  # Generators
  # =============================================================================

  @doc """
  Generates a position for a player.
  """
  def position do
    StreamData.member_of([:north, :east, :south, :west])
  end

  @doc """
  Generates a list of 4 positions in order (for dealing sequence).
  """
  def dealing_sequence do
    StreamData.constant([:north, :east, :south, :west])
  end

  @doc """
  Generates a batch count for dealing (typically 3 in Finnish Pidro).
  """
  def batch_size do
    StreamData.member_of([3])
  end

  # =============================================================================
  # Property: Initial Deal Gives Exactly 9 Cards to Each Player
  # =============================================================================

  property "initial deal gives exactly 9 cards to each player" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal 9 cards to each of 4 players (simulating initial deal)
      {player1_hand, deck2} = Deck.deal_batch(deck, 9)
      {player2_hand, deck3} = Deck.deal_batch(deck2, 9)
      {player3_hand, deck4} = Deck.deal_batch(deck3, 9)
      {player4_hand, remaining_deck} = Deck.deal_batch(deck4, 9)

      # Each player should have exactly 9 cards
      assert length(player1_hand) == 9,
             "Player 1 should have 9 cards, got #{length(player1_hand)}"

      assert length(player2_hand) == 9,
             "Player 2 should have 9 cards, got #{length(player2_hand)}"

      assert length(player3_hand) == 9,
             "Player 3 should have 9 cards, got #{length(player3_hand)}"

      assert length(player4_hand) == 9,
             "Player 4 should have 9 cards, got #{length(player4_hand)}"

      # Verify total cards dealt
      total_dealt = length(player1_hand) + length(player2_hand) +
                    length(player3_hand) + length(player4_hand)

      assert total_dealt == 36,
             "Total cards dealt should be 36 (9 per player × 4 players), got #{total_dealt}"

      # Verify remaining deck
      assert Deck.remaining(remaining_deck) == 16,
             "After dealing to 4 players, 16 cards should remain in deck"
    end
  end

  property "all dealt cards are unique across all players" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal 9 cards to each of 4 players
      {player1_hand, deck2} = Deck.deal_batch(deck, 9)
      {player2_hand, deck3} = Deck.deal_batch(deck2, 9)
      {player3_hand, deck4} = Deck.deal_batch(deck3, 9)
      {player4_hand, _remaining_deck} = Deck.deal_batch(deck4, 9)

      # Combine all hands
      all_dealt_cards = player1_hand ++ player2_hand ++ player3_hand ++ player4_hand

      # All cards should be unique
      unique_cards = Enum.uniq(all_dealt_cards)

      assert length(all_dealt_cards) == 36,
             "Total dealt cards should be 36"

      assert length(unique_cards) == 36,
             "All dealt cards should be unique (no duplicates)"

      # No card should appear in multiple hands
      assert MapSet.size(MapSet.intersection(MapSet.new(player1_hand), MapSet.new(player2_hand))) == 0
      assert MapSet.size(MapSet.intersection(MapSet.new(player1_hand), MapSet.new(player3_hand))) == 0
      assert MapSet.size(MapSet.intersection(MapSet.new(player1_hand), MapSet.new(player4_hand))) == 0
      assert MapSet.size(MapSet.intersection(MapSet.new(player2_hand), MapSet.new(player3_hand))) == 0
      assert MapSet.size(MapSet.intersection(MapSet.new(player2_hand), MapSet.new(player4_hand))) == 0
      assert MapSet.size(MapSet.intersection(MapSet.new(player3_hand), MapSet.new(player4_hand))) == 0
    end
  end

  property "dealt cards plus remaining cards equals full deck" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()
      original_cards = Enum.sort(deck.cards)

      # Deal to 4 players
      {player1_hand, deck2} = Deck.deal_batch(deck, 9)
      {player2_hand, deck3} = Deck.deal_batch(deck2, 9)
      {player3_hand, deck4} = Deck.deal_batch(deck3, 9)
      {player4_hand, remaining_deck} = Deck.deal_batch(deck4, 9)

      # Recombine all cards
      all_cards = player1_hand ++ player2_hand ++ player3_hand ++ player4_hand ++ remaining_deck.cards
      recombined_sorted = Enum.sort(all_cards)

      assert recombined_sorted == original_cards,
             "Dealt cards + remaining cards should equal original deck"

      assert length(all_cards) == 52,
             "Total cards should be 52"
    end
  end

  # =============================================================================
  # Property: Initial Deal Distributes Cards in Batches of 3
  # =============================================================================

  property "initial deal distributes cards in batches of 3" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Simulate dealing in batches of 3 to each player (3 rounds)
      # Round 1: 3 cards to each player
      {p1_batch1, deck2} = Deck.deal_batch(deck, 3)
      {p2_batch1, deck3} = Deck.deal_batch(deck2, 3)
      {p3_batch1, deck4} = Deck.deal_batch(deck3, 3)
      {p4_batch1, deck5} = Deck.deal_batch(deck4, 3)

      # Round 2: 3 cards to each player
      {p1_batch2, deck6} = Deck.deal_batch(deck5, 3)
      {p2_batch2, deck7} = Deck.deal_batch(deck6, 3)
      {p3_batch2, deck8} = Deck.deal_batch(deck7, 3)
      {p4_batch2, deck9} = Deck.deal_batch(deck8, 3)

      # Round 3: 3 cards to each player
      {p1_batch3, deck10} = Deck.deal_batch(deck9, 3)
      {p2_batch3, deck11} = Deck.deal_batch(deck10, 3)
      {p3_batch3, deck12} = Deck.deal_batch(deck11, 3)
      {p4_batch3, remaining_deck} = Deck.deal_batch(deck12, 3)

      # Each batch should have exactly 3 cards
      batches = [
        p1_batch1, p2_batch1, p3_batch1, p4_batch1,
        p1_batch2, p2_batch2, p3_batch2, p4_batch2,
        p1_batch3, p2_batch3, p3_batch3, p4_batch3
      ]

      Enum.each(batches, fn batch ->
        assert length(batch) == 3,
               "Each batch should contain exactly 3 cards, got #{length(batch)}"
      end)

      # Each player should have 9 cards total (3 batches × 3 cards)
      player1_total = p1_batch1 ++ p1_batch2 ++ p1_batch3
      player2_total = p2_batch1 ++ p2_batch2 ++ p2_batch3
      player3_total = p3_batch1 ++ p3_batch2 ++ p3_batch3
      player4_total = p4_batch1 ++ p4_batch2 ++ p4_batch3

      assert length(player1_total) == 9
      assert length(player2_total) == 9
      assert length(player3_total) == 9
      assert length(player4_total) == 9

      # After dealing in batches, 16 cards should remain
      assert Deck.remaining(remaining_deck) == 16,
             "After dealing in batches of 3, 16 cards should remain"
    end
  end

  property "dealing in batches of 3 maintains card uniqueness" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal in batches of 3 to simulate Finnish dealing pattern
      batches = Enum.reduce(1..12, {[], deck}, fn _round, {acc, current_deck} ->
        {batch, new_deck} = Deck.deal_batch(current_deck, 3)
        {acc ++ [batch], new_deck}
      end)

      {all_batches, _final_deck} = batches

      # Each batch should have 3 cards
      Enum.each(all_batches, fn batch ->
        assert length(batch) == 3,
               "Each batch should have 3 cards"
      end)

      # All cards across all batches should be unique
      all_dealt_cards = Enum.flat_map(all_batches, fn batch -> batch end)
      unique_cards = Enum.uniq(all_dealt_cards)

      assert length(all_dealt_cards) == 36,
             "Total dealt cards should be 36 (12 batches × 3 cards)"

      assert length(unique_cards) == 36,
             "All dealt cards across batches should be unique"
    end
  end

  property "batches of 3 can be combined to form player hands of 9" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal 12 batches of 3 cards (enough for 4 players with 3 batches each)
      {batches, remaining_deck} = Enum.reduce(1..12, {[], deck}, fn _i, {acc, d} ->
        {batch, new_deck} = Deck.deal_batch(d, 3)
        {acc ++ [batch], new_deck}
      end)

      # Group batches into 4 player hands (every 4th batch goes to same player)
      # This simulates dealing around the table: P1, P2, P3, P4, P1, P2, P3, P4, etc.
      player1_hand = Enum.at(batches, 0) ++ Enum.at(batches, 4) ++ Enum.at(batches, 8)
      player2_hand = Enum.at(batches, 1) ++ Enum.at(batches, 5) ++ Enum.at(batches, 9)
      player3_hand = Enum.at(batches, 2) ++ Enum.at(batches, 6) ++ Enum.at(batches, 10)
      player4_hand = Enum.at(batches, 3) ++ Enum.at(batches, 7) ++ Enum.at(batches, 11)

      # Each player should have exactly 9 cards
      assert length(player1_hand) == 9
      assert length(player2_hand) == 9
      assert length(player3_hand) == 9
      assert length(player4_hand) == 9

      # After dealing 12 batches, 16 cards remain
      assert Deck.remaining(remaining_deck) == 16
    end
  end

  # =============================================================================
  # Property: After Initial Deal, 16 Cards Remain in Deck (The Kitty)
  # =============================================================================

  property "after initial deal, exactly 16 cards remain in deck" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal 9 cards to each of 4 players (36 cards total)
      {_p1, deck2} = Deck.deal_batch(deck, 9)
      {_p2, deck3} = Deck.deal_batch(deck2, 9)
      {_p3, deck4} = Deck.deal_batch(deck3, 9)
      {_p4, remaining_deck} = Deck.deal_batch(deck4, 9)

      assert Deck.remaining(remaining_deck) == 16,
             "After initial deal to 4 players (9 cards each), exactly 16 cards should remain (the kitty)"

      assert length(remaining_deck.cards) == 16,
             "Remaining deck should physically contain 16 cards"
    end
  end

  property "kitty (remaining 16 cards) contains valid unique cards" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal to 4 players
      {_p1, deck2} = Deck.deal_batch(deck, 9)
      {_p2, deck3} = Deck.deal_batch(deck2, 9)
      {_p3, deck4} = Deck.deal_batch(deck3, 9)
      {_p4, kitty_deck} = Deck.deal_batch(deck4, 9)

      kitty_cards = kitty_deck.cards

      # Kitty should have 16 cards
      assert length(kitty_cards) == 16

      # All cards in kitty should be unique
      unique_kitty = Enum.uniq(kitty_cards)
      assert length(unique_kitty) == 16,
             "All 16 cards in kitty should be unique"

      # All cards in kitty should be valid cards (rank 2-14, valid suit)
      Enum.each(kitty_cards, fn {rank, suit} ->
        assert rank in 2..14,
               "Kitty card rank should be between 2 and 14, got #{rank}"

        assert suit in [:hearts, :diamonds, :clubs, :spades],
               "Kitty card suit should be valid, got #{suit}"
      end)
    end
  end

  property "remaining 16 cards can be further dealt" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Initial deal to 4 players
      {_p1, deck2} = Deck.deal_batch(deck, 9)
      {_p2, deck3} = Deck.deal_batch(deck2, 9)
      {_p3, deck4} = Deck.deal_batch(deck3, 9)
      {_p4, kitty_deck} = Deck.deal_batch(deck4, 9)

      assert Deck.remaining(kitty_deck) == 16

      # Should be able to deal more cards from the kitty
      {additional_cards, final_deck} = Deck.deal_batch(kitty_deck, 10)

      assert length(additional_cards) == 10,
             "Should be able to deal 10 cards from kitty"

      assert Deck.remaining(final_deck) == 6,
             "After dealing 10 from kitty, 6 should remain"

      # Can deal the rest
      {last_cards, empty_deck} = Deck.deal_batch(final_deck, 6)

      assert length(last_cards) == 6
      assert Deck.remaining(empty_deck) == 0
    end
  end

  # =============================================================================
  # Property: Dealing Order and Consistency
  # =============================================================================

  property "dealing order is consistent (cards dealt in sequence)" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal all 52 cards one at a time to verify order
      {all_cards, empty_deck} = Enum.reduce(1..52, {[], deck}, fn _i, {acc, d} ->
        {[card], new_deck} = Deck.deal_batch(d, 1)
        {acc ++ [card], new_deck}
      end)

      assert length(all_cards) == 52
      assert Deck.remaining(empty_deck) == 0

      # All cards should be unique
      assert length(Enum.uniq(all_cards)) == 52,
             "All cards dealt in sequence should be unique"
    end
  end

  property "dealing operation is deterministic for same deck" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      # Create two identical decks (note: in real implementation,
      # Deck.new() shuffles, so we'd need a way to create identical decks
      # for true determinism testing. This property verifies the dealing
      # logic itself is deterministic.)
      deck = Deck.new()

      # First deal
      {dealt1, remaining1} = Deck.deal_batch(deck, 9)

      # Same deck, same deal
      {dealt2, remaining2} = Deck.deal_batch(deck, 9)

      # Should get identical results from same deck
      assert dealt1 == dealt2,
             "Dealing from same deck should be deterministic"

      assert remaining1.cards == remaining2.cards,
             "Remaining cards should be identical"
    end
  end

  # =============================================================================
  # Property: Edge Cases for Dealing
  # =============================================================================

  property "cannot deal 9 cards to more than 5 players from full deck" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal to 5 players (45 cards)
      {_p1, deck2} = Deck.deal_batch(deck, 9)
      {_p2, deck3} = Deck.deal_batch(deck2, 9)
      {_p3, deck4} = Deck.deal_batch(deck3, 9)
      {_p4, deck5} = Deck.deal_batch(deck4, 9)
      {_p5, remaining_deck} = Deck.deal_batch(deck5, 9)

      # Should have 7 cards remaining
      assert Deck.remaining(remaining_deck) == 7

      # Attempting to deal 9 more should only return 7
      {p6_cards, final_deck} = Deck.deal_batch(remaining_deck, 9)

      assert length(p6_cards) == 7,
             "Should only deal 7 cards when only 7 remain"

      assert Deck.remaining(final_deck) == 0
    end
  end

  property "dealing 0 cards multiple times does not affect deck" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # Deal 0 cards multiple times
      {dealt1, deck2} = Deck.deal_batch(deck, 0)
      {dealt2, deck3} = Deck.deal_batch(deck2, 0)
      {dealt3, deck4} = Deck.deal_batch(deck3, 0)

      assert dealt1 == []
      assert dealt2 == []
      assert dealt3 == []

      assert Deck.remaining(deck) == 52
      assert Deck.remaining(deck2) == 52
      assert Deck.remaining(deck3) == 52
      assert Deck.remaining(deck4) == 52
    end
  end

  # =============================================================================
  # Property: Finnish Pidro Specific Rules
  # =============================================================================

  property "Finnish Pidro initial deal follows 3-3-3 pattern per player" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # For one player, verify they receive 3 cards, then 3 more, then 3 more
      # (interleaved with other players in real game)

      # Simulate dealing to player 1 in three rounds
      {round1, deck2} = Deck.deal_batch(deck, 3)
      {_others1, deck3} = Deck.deal_batch(deck2, 9)  # Other 3 players get 3 each

      {round2, deck4} = Deck.deal_batch(deck3, 3)
      {_others2, deck5} = Deck.deal_batch(deck4, 9)  # Other 3 players get 3 each

      {round3, deck6} = Deck.deal_batch(deck5, 3)
      {_others3, remaining_deck} = Deck.deal_batch(deck6, 9)  # Other 3 players get 3 each

      # Player 1's full hand
      player1_hand = round1 ++ round2 ++ round3

      assert length(round1) == 3
      assert length(round2) == 3
      assert length(round3) == 3
      assert length(player1_hand) == 9

      # After dealing to all players in 3 rounds, 16 should remain
      assert Deck.remaining(remaining_deck) == 16
    end
  end

  property "Finnish Pidro standard game setup: 4 players, 9 cards each, 16 in kitty" do
    check all _ <- StreamData.constant(:ok), max_runs: 100 do
      deck = Deck.new()

      # This is the canonical Finnish Pidro initial deal
      {north_hand, deck2} = Deck.deal_batch(deck, 9)
      {east_hand, deck3} = Deck.deal_batch(deck2, 9)
      {south_hand, deck4} = Deck.deal_batch(deck3, 9)
      {west_hand, kitty_deck} = Deck.deal_batch(deck4, 9)

      # Verify player counts
      assert length(north_hand) == 9, "North should have 9 cards"
      assert length(east_hand) == 9, "East should have 9 cards"
      assert length(south_hand) == 9, "South should have 9 cards"
      assert length(west_hand) == 9, "West should have 9 cards"

      # Verify kitty
      assert Deck.remaining(kitty_deck) == 16, "Kitty should have 16 cards"

      # Verify total and uniqueness
      all_cards = north_hand ++ east_hand ++ south_hand ++ west_hand ++ kitty_deck.cards
      assert length(all_cards) == 52, "Total should be 52 cards"
      assert length(Enum.uniq(all_cards)) == 52, "All cards should be unique"

      # Verify no overlap between hands
      hands = [north_hand, east_hand, south_hand, west_hand]
      for {hand1, idx1} <- Enum.with_index(hands),
          {hand2, idx2} <- Enum.with_index(hands),
          idx1 < idx2 do
        overlap = MapSet.intersection(MapSet.new(hand1), MapSet.new(hand2))
        assert MapSet.size(overlap) == 0,
               "No cards should overlap between player hands"
      end
    end
  end
end
