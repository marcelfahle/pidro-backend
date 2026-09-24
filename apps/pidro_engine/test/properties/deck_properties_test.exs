defmodule Pidro.Properties.DeckPropertiesTest do
  @moduledoc """
  Property-based tests for the Deck module using StreamData.

  These tests verify fundamental invariants of deck operations:
  - Deck composition (52 unique cards)
  - Shuffling through the chance stream preserves all cards
  - Dealing operations maintain deck integrity
  - Immutability of deck operations
  - Edge cases with empty/partial decks
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Chance, Deck}

  # =============================================================================
  # Generators
  # =============================================================================

  @doc """
  Generates a valid deal count (non-negative integer).
  """
  def deal_count do
    StreamData.integer(0..60)
  end

  @doc """
  Generates a small deal count for more focused testing.
  """
  def small_deal_count do
    StreamData.integer(0..20)
  end

  @doc """
  Generates a seed for the chance stream a deck is shuffled from.
  """
  def seed do
    StreamData.integer(1..1_000_000)
  end

  # A deck as the engine builds one: `Deck.ordered/0` permuted by an explicit
  # chance value. Varying the seed varies the order, without touching the
  # calling process's RNG.
  defp shuffled_deck(seed) do
    {cards, _chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(seed))
    %Deck{cards: cards, shuffled?: true}
  end

  # =============================================================================
  # Property: A Shuffled Deck Always Has 52 Unique Cards
  # =============================================================================

  property "a shuffled deck always contains exactly 52 cards" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)
      assert Deck.remaining(deck) == 52
    end
  end

  property "a shuffled deck always contains 52 unique cards" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)
      cards = deck.cards

      # All cards should be unique
      unique_cards = Enum.uniq(cards)
      assert length(cards) == 52
      assert length(unique_cards) == 52
    end
  end

  property "a shuffled deck contains all 4 suits with 13 cards each" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        cards_in_suit = Enum.filter(deck.cards, fn {_rank, s} -> s == suit end)

        assert length(cards_in_suit) == 13,
               "Expected 13 cards in #{suit}, got #{length(cards_in_suit)}"
      end
    end
  end

  property "a shuffled deck contains all ranks 2-14 in each suit" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      for suit <- [:hearts, :diamonds, :clubs, :spades],
          rank <- 2..14 do
        assert {rank, suit} in deck.cards,
               "Expected {#{rank}, #{suit}} to be in deck"
      end
    end
  end

  property "a shuffled deck is a permutation of the ordered deck" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)
      assert Enum.sort(deck.cards) == Enum.sort(Deck.ordered())
    end
  end

  property "the same seed always produces the same deck" do
    check all(seed <- seed(), max_runs: 100) do
      assert shuffled_deck(seed).cards == shuffled_deck(seed).cards
    end
  end

  # =============================================================================
  # Property: Shuffling Through the Chance Stream Preserves the Cards
  # =============================================================================

  property "a shuffle contains the same cards as its input (order may differ)" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {cards, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(seed + 1))

      assert Enum.sort(cards) == Enum.sort(deck.cards),
             "A shuffle should contain the same cards as its input"
    end
  end

  property "shuffling preserves card count" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {cards, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(seed + 1))

      assert length(cards) == Deck.remaining(deck),
             "A shuffle should have the same count as its input"
    end
  end

  property "shuffling a partial deck preserves the remaining cards" do
    check all(seed <- seed(), deal_amount <- small_deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_dealt, remaining} = Deck.deal_batch(deck, deal_amount)

      {cards, _chance} = Chance.shuffle(remaining.cards, Chance.from_seed(seed + 1))

      assert length(cards) == Deck.remaining(remaining)
      assert Enum.sort(cards) == Enum.sort(remaining.cards)
    end
  end

  property "multiple shuffles preserve all cards" do
    check all(seed <- seed(), shuffle_count <- StreamData.integer(1..10), max_runs: 100) do
      deck = shuffled_deck(seed)

      {final_cards, _chance} =
        Enum.reduce(1..shuffle_count, {deck.cards, Chance.from_seed(seed + 1)}, fn _i,
                                                                                   {cards, chance} ->
          Chance.shuffle(cards, chance)
        end)

      assert Enum.sort(final_cards) == Enum.sort(deck.cards),
             "After #{shuffle_count} shuffles, all cards should still be present"

      assert length(final_cards) == 52
    end
  end

  # =============================================================================
  # Property: Dealing N Cards Reduces Deck Size by N
  # =============================================================================

  property "dealing N cards reduces deck size by exactly N (when N <= remaining)" do
    check all(seed <- seed(), deal_amount <- deal_count(), max_runs: 200) do
      deck = shuffled_deck(seed)
      initial_count = Deck.remaining(deck)

      {dealt, remaining} = Deck.deal_batch(deck, deal_amount)

      expected_dealt = min(deal_amount, initial_count)
      expected_remaining = max(0, initial_count - deal_amount)

      assert length(dealt) == expected_dealt,
             "Expected to deal #{expected_dealt} cards, got #{length(dealt)}"

      assert Deck.remaining(remaining) == expected_remaining,
             "Expected #{expected_remaining} cards remaining, got #{Deck.remaining(remaining)}"
    end
  end

  property "dealt cards plus remaining cards equals original deck" do
    check all(seed <- seed(), deal_amount <- small_deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      original_cards = Enum.sort(deck.cards)

      {dealt, remaining} = Deck.deal_batch(deck, deal_amount)
      recombined = Enum.sort(dealt ++ remaining.cards)

      assert recombined == original_cards,
             "Dealt cards + remaining cards should equal original deck"
    end
  end

  property "dealing 0 cards returns empty list and unchanged deck" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {dealt, remaining} = Deck.deal_batch(deck, 0)

      assert dealt == []
      assert Deck.remaining(remaining) == 52
      assert remaining.cards == deck.cards
    end
  end

  property "dealing all 52 cards empties the deck" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {dealt, remaining} = Deck.deal_batch(deck, 52)

      assert length(dealt) == 52
      assert Deck.remaining(remaining) == 0
      assert remaining.cards == []
    end
  end

  property "sequential dealing maintains card uniqueness" do
    check all(
            seed <- seed(),
            deal_counts <- StreamData.list_of(small_deal_count(), min_length: 2, max_length: 6),
            max_runs: 100
          ) do
      deck = shuffled_deck(seed)

      # Deal multiple batches
      {all_dealt, _final_deck} =
        Enum.reduce(deal_counts, {[], deck}, fn count, {acc, d} ->
          {dealt, remaining} = Deck.deal_batch(d, count)
          {acc ++ dealt, remaining}
        end)

      # All dealt cards should be unique
      unique_dealt = Enum.uniq(all_dealt)

      assert length(all_dealt) == length(unique_dealt),
             "All dealt cards across multiple deals should be unique"
    end
  end

  property "dealing from deck never duplicates cards" do
    check all(
            seed <- seed(),
            first_deal <- small_deal_count(),
            second_deal <- small_deal_count(),
            max_runs: 100
          ) do
      deck = shuffled_deck(seed)

      {first_batch, deck2} = Deck.deal_batch(deck, first_deal)
      {second_batch, _deck3} = Deck.deal_batch(deck2, second_deal)

      # No card from first batch should appear in second batch
      overlap =
        MapSet.intersection(
          MapSet.new(first_batch),
          MapSet.new(second_batch)
        )

      assert MapSet.size(overlap) == 0,
             "No cards should appear in both batches"
    end
  end

  # =============================================================================
  # Property: Cannot Deal More Cards Than Available
  # =============================================================================

  property "dealing more cards than available returns only available cards" do
    check all(
            seed <- seed(),
            initial_deal <- StreamData.integer(0..52),
            excessive_deal <- StreamData.integer(1..100),
            max_runs: 100
          ) do
      deck = shuffled_deck(seed)
      {_first, remaining} = Deck.deal_batch(deck, initial_deal)

      available = Deck.remaining(remaining)
      {dealt, final_deck} = Deck.deal_batch(remaining, excessive_deal)

      expected_count = min(excessive_deal, available)

      assert length(dealt) == expected_count,
             "Should deal #{expected_count} cards (available), not #{excessive_deal} (requested)"

      assert Deck.remaining(final_deck) == max(0, available - excessive_deal),
             "Remaining count should be correct after dealing more than available"
    end
  end

  property "dealing from empty deck returns empty list" do
    check all(seed <- seed(), excessive_count <- deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_all_cards, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0

      {dealt, still_empty} = Deck.deal_batch(empty_deck, excessive_count)

      assert dealt == []
      assert Deck.remaining(still_empty) == 0
    end
  end

  property "cannot deal negative number of cards (guard clause)" do
    check all(seed <- seed(), negative_count <- StreamData.integer(-100..-1), max_runs: 100) do
      deck = shuffled_deck(seed)

      assert_raise FunctionClauseError, fn ->
        Deck.deal_batch(deck, negative_count)
      end
    end
  end

  # =============================================================================
  # Property: Deck Operations Are Immutable
  # =============================================================================

  property "dealing from a deck does not mutate the original deck" do
    check all(seed <- seed(), deal_amount <- small_deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      original_cards = deck.cards
      original_count = Deck.remaining(deck)

      {_dealt, _remaining} = Deck.deal_batch(deck, deal_amount)

      # Original deck should be unchanged
      assert deck.cards == original_cards,
             "Original deck cards should not be mutated"

      assert Deck.remaining(deck) == original_count,
             "Original deck count should not be mutated"
    end
  end

  property "shuffling does not mutate the list it was given" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)
      original_cards = deck.cards

      {_shuffled, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(seed + 1))

      # Original deck should be unchanged
      assert deck.cards == original_cards,
             "Original deck should not be mutated by shuffle"
    end
  end

  property "multiple operations on same deck do not interfere" do
    check all(
            seed <- seed(),
            deal1 <- small_deal_count(),
            deal2 <- small_deal_count(),
            max_runs: 100
          ) do
      deck = shuffled_deck(seed)
      original_cards = deck.cards

      # Perform multiple operations from the same deck
      {dealt1, remaining1} = Deck.deal_batch(deck, deal1)
      {dealt2, remaining2} = Deck.deal_batch(deck, deal2)
      {shuffled, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(seed + 1))

      # Original deck should be unchanged
      assert deck.cards == original_cards

      # Each operation should have same starting point
      assert length(dealt1) == min(deal1, 52)
      assert length(dealt2) == min(deal2, 52)
      assert length(shuffled) == 52

      # Operations from same starting point should be independent
      assert Deck.remaining(remaining1) == max(0, 52 - deal1)
      assert Deck.remaining(remaining2) == max(0, 52 - deal2)
    end
  end

  property "chaining operations creates new deck at each step" do
    check all(
            seed <- seed(),
            deals <- StreamData.list_of(small_deal_count(), min_length: 3, max_length: 5),
            max_runs: 100
          ) do
      initial_deck = shuffled_deck(seed)

      # Chain multiple deals and collect all intermediate decks
      {_final_dealt, all_decks} =
        Enum.reduce(deals, {[], [initial_deck]}, fn deal_count,
                                                    {_dealt_acc, [current_deck | _] = deck_acc} ->
          {dealt, new_deck} = Deck.deal_batch(current_deck, deal_count)
          {dealt, [new_deck | deck_acc]}
        end)

      # Each deck in the chain should be independent
      # Earlier decks should not be affected by later operations
      for deck <- all_decks do
        # Each deck should be a valid Deck struct
        assert %Deck{} = deck
        assert is_list(deck.cards)
      end
    end
  end

  # =============================================================================
  # Property: Draw/Deal Equivalence
  # =============================================================================

  property "draw/2 and deal_batch/2 are equivalent" do
    check all(seed <- seed(), deal_amount <- small_deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {dealt, remaining_deal} = Deck.deal_batch(deck, deal_amount)
      {drawn, remaining_draw} = Deck.draw(deck, deal_amount)

      assert dealt == drawn,
             "draw/2 and deal_batch/2 should return same cards"

      assert remaining_deal.cards == remaining_draw.cards,
             "draw/2 and deal_batch/2 should leave same remaining cards"
    end
  end

  # =============================================================================
  # Property: Remaining Count Accuracy
  # =============================================================================

  property "remaining/1 always equals length of cards list" do
    check all(seed <- seed(), deal_amount <- deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_dealt, remaining} = Deck.deal_batch(deck, deal_amount)

      assert Deck.remaining(remaining) == length(remaining.cards),
             "remaining/1 should always equal actual card count"
    end
  end

  property "remaining count is never negative" do
    check all(seed <- seed(), deal_amount <- deal_count(), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_dealt, remaining} = Deck.deal_batch(deck, deal_amount)

      assert Deck.remaining(remaining) >= 0,
             "Remaining count should never be negative"
    end
  end

  # =============================================================================
  # Property: Edge Cases and Boundary Conditions
  # =============================================================================

  property "dealing exact number of remaining cards empties deck" do
    check all(seed <- seed(), initial_deal <- StreamData.integer(0..52), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_first, partial} = Deck.deal_batch(deck, initial_deal)

      remaining_count = Deck.remaining(partial)
      {dealt, empty_deck} = Deck.deal_batch(partial, remaining_count)

      assert length(dealt) == remaining_count
      assert Deck.remaining(empty_deck) == 0
      assert empty_deck.cards == []
    end
  end

  property "Finnish Pidro standard deal pattern (4 players, 9 cards each)" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      # Deal 9 cards to each of 4 players
      {player1, deck2} = Deck.deal_batch(deck, 9)
      {player2, deck3} = Deck.deal_batch(deck2, 9)
      {player3, deck4} = Deck.deal_batch(deck3, 9)
      {player4, kitty} = Deck.deal_batch(deck4, 9)

      # Verify each player got 9 cards
      assert length(player1) == 9
      assert length(player2) == 9
      assert length(player3) == 9
      assert length(player4) == 9

      # Verify kitty has 16 cards remaining
      assert Deck.remaining(kitty) == 16

      # Verify all cards are accounted for and unique
      all_cards = player1 ++ player2 ++ player3 ++ player4 ++ kitty.cards
      assert length(all_cards) == 52
      assert length(Enum.uniq(all_cards)) == 52
    end
  end

  property "shuffling an empty deck is valid" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)
      {_all, empty_deck} = Deck.deal_batch(deck, 52)

      {shuffled, chance} = Chance.shuffle(empty_deck.cards, Chance.from_seed(seed + 1))

      assert shuffled == []
      # Nothing was drawn, so the stream is handed back unadvanced.
      assert chance == Chance.from_seed(seed + 1)
    end
  end

  property "dealing one card at a time eventually empties deck" do
    check all(seed <- seed(), max_runs: 20) do
      deck = shuffled_deck(seed)

      # Deal one card at a time until empty
      final_state =
        Enum.reduce(1..52, {[], deck}, fn _i, {acc, d} ->
          {[card], remaining} = Deck.deal_batch(d, 1)
          {acc ++ [card], remaining}
        end)

      {all_dealt, empty_deck} = final_state

      assert length(all_dealt) == 52
      assert length(Enum.uniq(all_dealt)) == 52
      assert Deck.remaining(empty_deck) == 0
    end
  end
end
