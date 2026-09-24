defmodule Pidro.Properties.DeckPropertiesTest do
  @moduledoc """
  Property-based tests for the Deck module using StreamData.

  These tests verify fundamental invariants of the deck:
  - Deck composition (52 unique cards, 4 suits x 13 ranks)
  - Shuffling through the chance stream preserves all cards

  Dealing is not exercised here: the deck is a bare card list and dealing
  belongs to `Pidro.Game.Dealing`, which
  `Pidro.Properties.DealingPropertiesTest` covers.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Chance, Deck}

  # =============================================================================
  # Generators
  # =============================================================================

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
    cards
  end

  # =============================================================================
  # Property: A Shuffled Deck Always Has 52 Unique Cards
  # =============================================================================

  property "a shuffled deck always contains 52 unique cards" do
    check all(seed <- seed(), max_runs: 100) do
      cards = shuffled_deck(seed)

      assert length(cards) == 52
      assert length(Enum.uniq(cards)) == 52
    end
  end

  property "a shuffled deck contains all 4 suits with 13 cards each" do
    check all(seed <- seed(), max_runs: 100) do
      cards = shuffled_deck(seed)

      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        cards_in_suit = Enum.filter(cards, fn {_rank, s} -> s == suit end)

        assert length(cards_in_suit) == 13,
               "Expected 13 cards in #{suit}, got #{length(cards_in_suit)}"
      end
    end
  end

  property "a shuffled deck contains all ranks 2-14 in each suit" do
    check all(seed <- seed(), max_runs: 100) do
      cards = shuffled_deck(seed)

      for suit <- [:hearts, :diamonds, :clubs, :spades],
          rank <- 2..14 do
        assert {rank, suit} in cards,
               "Expected {#{rank}, #{suit}} to be in deck"
      end
    end
  end

  property "a shuffled deck is a permutation of the ordered deck" do
    check all(seed <- seed(), max_runs: 100) do
      assert Enum.sort(shuffled_deck(seed)) == Enum.sort(Deck.ordered())
    end
  end

  property "the same seed always produces the same deck" do
    check all(seed <- seed(), max_runs: 100) do
      assert shuffled_deck(seed) == shuffled_deck(seed)
    end
  end

  # =============================================================================
  # Property: Shuffling Through the Chance Stream Preserves the Cards
  # =============================================================================

  property "a shuffle contains the same cards as its input (order may differ)" do
    check all(seed <- seed(), max_runs: 100) do
      deck = shuffled_deck(seed)

      {cards, _chance} = Chance.shuffle(deck, Chance.from_seed(seed + 1))

      assert Enum.sort(cards) == Enum.sort(deck),
             "A shuffle should contain the same cards as its input"
    end
  end

  property "multiple shuffles preserve all cards" do
    check all(seed <- seed(), shuffle_count <- StreamData.integer(1..10), max_runs: 100) do
      deck = shuffled_deck(seed)

      {final_cards, _chance} =
        Enum.reduce(1..shuffle_count, {deck, Chance.from_seed(seed + 1)}, fn _i,
                                                                             {cards, chance} ->
          Chance.shuffle(cards, chance)
        end)

      assert Enum.sort(final_cards) == Enum.sort(deck),
             "After #{shuffle_count} shuffles, all cards should still be present"
    end
  end

  property "shuffling an empty deck is valid and leaves the stream unadvanced" do
    check all(seed <- seed(), max_runs: 100) do
      chance = Chance.from_seed(seed)

      # Nothing was drawn, so the stream is handed back unadvanced.
      assert {[], ^chance} = Chance.shuffle([], chance)
    end
  end
end
