defmodule Pidro.Core.DeckTest do
  use ExUnit.Case, async: true
  doctest Pidro.Core.Deck

  alias Pidro.Core.{Chance, Deck}

  # A deterministic stand-in for the deck the engine shuffles at the start of a
  # hand: `Deck.ordered/0` permuted by a fixed chance value. Nothing here draws
  # from the calling process's RNG.
  defp shuffled_deck(seed \\ 1) do
    {cards, _chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(seed))
    %Deck{cards: cards, shuffled?: true}
  end

  describe "ordered/0" do
    test "is the same 52 cards every time, in the same order" do
      assert Deck.ordered() == Deck.ordered()
      assert length(Deck.ordered()) == 52
    end

    test "starts unshuffled, in generation order" do
      assert Enum.take(Deck.ordered(), 3) == [{2, :hearts}, {3, :hearts}, {4, :hearts}]
    end
  end

  describe "a deck shuffled from the chance stream" do
    test "creates a deck with exactly 52 cards" do
      deck = shuffled_deck()
      assert Deck.remaining(deck) == 52
    end

    test "contains all 52 unique cards" do
      deck = shuffled_deck()
      cards = deck.cards

      # Verify all cards are unique
      assert length(cards) == length(Enum.uniq(cards))
    end

    test "contains all 4 suits" do
      deck = shuffled_deck()
      suits = deck.cards |> Enum.map(fn {_rank, suit} -> suit end) |> Enum.uniq()

      assert :hearts in suits
      assert :diamonds in suits
      assert :clubs in suits
      assert :spades in suits
      assert length(suits) == 4
    end

    test "contains all 13 ranks per suit" do
      deck = shuffled_deck()

      # Count cards per suit
      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        cards_in_suit = Enum.filter(deck.cards, fn {_rank, s} -> s == suit end)
        assert length(cards_in_suit) == 13, "Expected 13 cards in #{suit}"
      end
    end

    test "contains ranks 2 through 14 (Ace)" do
      deck = shuffled_deck()
      ranks = deck.cards |> Enum.map(fn {rank, _suit} -> rank end) |> Enum.uniq() |> Enum.sort()

      assert ranks == Enum.to_list(2..14)
    end

    test "each rank-suit combination appears exactly once" do
      deck = shuffled_deck()

      for suit <- [:hearts, :diamonds, :clubs, :spades],
          rank <- 2..14 do
        card_count = Enum.count(deck.cards, fn card -> card == {rank, suit} end)
        assert card_count == 1, "Expected exactly 1 #{rank} of #{suit}, got #{card_count}"
      end
    end

    test "different chance values produce different orders" do
      # There is no process-RNG deck constructor to be nondeterministic any
      # more: a deck's order is a function of the chance value it was shuffled
      # with, and the same value always produces the same deck.
      assert shuffled_deck(1).cards == shuffled_deck(1).cards
      refute shuffled_deck(1).cards == shuffled_deck(2).cards
    end

    test "contains all point cards for Finnish Pidro" do
      deck = shuffled_deck()

      # Check for all fives (important for Right 5 and Wrong 5)
      fives = Enum.filter(deck.cards, fn {rank, _suit} -> rank == 5 end)
      assert length(fives) == 4

      # Check for all Aces
      aces = Enum.filter(deck.cards, fn {rank, _suit} -> rank == 14 end)
      assert length(aces) == 4

      # Check for all Jacks
      jacks = Enum.filter(deck.cards, fn {rank, _suit} -> rank == 11 end)
      assert length(jacks) == 4

      # Check for all 10s
      tens = Enum.filter(deck.cards, fn {rank, _suit} -> rank == 10 end)
      assert length(tens) == 4

      # Check for all 2s
      twos = Enum.filter(deck.cards, fn {rank, _suit} -> rank == 2 end)
      assert length(twos) == 4
    end
  end

  describe "shuffling through the chance stream" do
    test "maintains the same number of cards" do
      deck = shuffled_deck()

      {cards, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(9))

      assert length(cards) == Deck.remaining(deck)
    end

    test "contains the same cards (different order)" do
      deck = shuffled_deck()

      {cards, _chance} = Chance.shuffle(deck.cards, Chance.from_seed(9))

      assert Enum.sort(cards) == Enum.sort(deck.cards)
      refute cards == deck.cards
    end

    test "works with a partially dealt deck" do
      deck = shuffled_deck()
      {_dealt, remaining} = Deck.deal_batch(deck, 20)

      assert Deck.remaining(remaining) == 32

      {cards, _chance} = Chance.shuffle(remaining.cards, Chance.from_seed(9))

      assert length(cards) == 32
      assert Enum.sort(cards) == Enum.sort(remaining.cards)
    end

    test "works with an empty deck" do
      deck = shuffled_deck()
      {_dealt, empty_deck} = Deck.deal_batch(deck, 52)

      assert {[], _chance} = Chance.shuffle(empty_deck.cards, Chance.from_seed(9))
    end

    test "maintains deck integrity after multiple shuffles" do
      deck = shuffled_deck()

      {cards, chance} = Chance.shuffle(deck.cards, Chance.from_seed(9))
      {cards, chance} = Chance.shuffle(cards, chance)
      {cards, _chance} = Chance.shuffle(cards, chance)

      assert length(cards) == 52
      assert length(Enum.uniq(cards)) == 52
    end

    test "the advanced stream gives the next shuffle a different order" do
      {first, chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(9))
      {second, _chance} = Chance.shuffle(Deck.ordered(), chance)

      refute first == second
    end
  end

  describe "deal_batch/2" do
    test "deals the correct number of cards" do
      deck = shuffled_deck()
      {dealt, _remaining} = Deck.deal_batch(deck, 9)

      assert length(dealt) == 9
    end

    test "removes dealt cards from the deck" do
      deck = shuffled_deck()
      {_dealt, remaining} = Deck.deal_batch(deck, 9)

      assert Deck.remaining(remaining) == 43
    end

    test "returns both dealt cards and remaining deck" do
      deck = shuffled_deck()
      {dealt, remaining} = Deck.deal_batch(deck, 9)

      assert is_list(dealt)
      assert %Deck{} = remaining
      assert length(dealt) == 9
      assert Deck.remaining(remaining) == 43
    end

    test "dealt cards are removed from remaining deck" do
      deck = shuffled_deck()
      {dealt, remaining} = Deck.deal_batch(deck, 9)

      # No card in dealt should appear in remaining
      for card <- dealt do
        refute card in remaining.cards, "Card #{inspect(card)} should not be in remaining deck"
      end
    end

    test "can deal all 52 cards" do
      deck = shuffled_deck()
      {dealt, remaining} = Deck.deal_batch(deck, 52)

      assert length(dealt) == 52
      assert Deck.remaining(remaining) == 0
    end

    test "can deal cards in batches" do
      deck = shuffled_deck()

      {batch1, deck2} = Deck.deal_batch(deck, 9)
      {batch2, deck3} = Deck.deal_batch(deck2, 9)
      {batch3, deck4} = Deck.deal_batch(deck3, 9)
      {batch4, deck5} = Deck.deal_batch(deck4, 9)

      assert length(batch1) == 9
      assert length(batch2) == 9
      assert length(batch3) == 9
      assert length(batch4) == 9
      assert Deck.remaining(deck5) == 16

      # All dealt cards should be unique
      all_dealt = batch1 ++ batch2 ++ batch3 ++ batch4
      assert length(all_dealt) == length(Enum.uniq(all_dealt))
    end

    test "deals 0 cards when count is 0" do
      deck = shuffled_deck()
      {dealt, remaining} = Deck.deal_batch(deck, 0)

      assert dealt == []
      assert Deck.remaining(remaining) == 52
    end

    test "deals cards from the top of the deck" do
      deck = shuffled_deck()
      top_cards = Enum.take(deck.cards, 3)

      {dealt, _remaining} = Deck.deal_batch(deck, 3)

      assert dealt == top_cards
    end

    test "maintains deck integrity after dealing" do
      deck = shuffled_deck()
      original_cards = Enum.sort(deck.cards)

      {dealt, remaining} = Deck.deal_batch(deck, 20)
      recombined = Enum.sort(dealt ++ remaining.cards)

      assert original_cards == recombined
    end

    test "typical Finnish Pidro deal (9 cards to 4 players)" do
      deck = shuffled_deck()

      # Deal 9 cards to player 1
      {player1_hand, deck2} = Deck.deal_batch(deck, 9)

      # Deal 9 cards to player 2
      {player2_hand, deck3} = Deck.deal_batch(deck2, 9)

      # Deal 9 cards to player 3
      {player3_hand, deck4} = Deck.deal_batch(deck3, 9)

      # Deal 9 cards to player 4
      {player4_hand, remaining} = Deck.deal_batch(deck4, 9)

      assert length(player1_hand) == 9
      assert length(player2_hand) == 9
      assert length(player3_hand) == 9
      assert length(player4_hand) == 9
      assert Deck.remaining(remaining) == 16

      # All hands should be unique
      all_cards = player1_hand ++ player2_hand ++ player3_hand ++ player4_hand
      assert length(all_cards) == length(Enum.uniq(all_cards))
    end
  end

  describe "deal_batch/2 - edge cases" do
    test "dealing more cards than available returns all remaining cards" do
      deck = shuffled_deck()
      {_first_batch, partial_deck} = Deck.deal_batch(deck, 50)

      assert Deck.remaining(partial_deck) == 2

      {dealt, remaining} = Deck.deal_batch(partial_deck, 10)

      assert length(dealt) == 2
      assert Deck.remaining(remaining) == 0
    end

    test "dealing from empty deck returns empty list" do
      deck = shuffled_deck()
      {_all_cards, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0

      {dealt, remaining} = Deck.deal_batch(empty_deck, 5)

      assert dealt == []
      assert Deck.remaining(remaining) == 0
    end

    test "dealing from single card deck" do
      deck = shuffled_deck()
      {_dealt, single_card_deck} = Deck.deal_batch(deck, 51)

      assert Deck.remaining(single_card_deck) == 1

      {dealt, remaining} = Deck.deal_batch(single_card_deck, 1)

      assert length(dealt) == 1
      assert Deck.remaining(remaining) == 0
    end

    test "dealing exact number of remaining cards" do
      deck = shuffled_deck()
      {_dealt, partial_deck} = Deck.deal_batch(deck, 40)

      assert Deck.remaining(partial_deck) == 12

      {dealt, remaining} = Deck.deal_batch(partial_deck, 12)

      assert length(dealt) == 12
      assert Deck.remaining(remaining) == 0
    end

    test "dealing with negative count is not allowed (relies on guard clause)" do
      deck = shuffled_deck()

      # This should raise FunctionClauseError due to guard clause (count >= 0)
      assert_raise FunctionClauseError, fn ->
        Deck.deal_batch(deck, -1)
      end
    end

    test "multiple sequential deals from deck" do
      deck = shuffled_deck()

      # Deal 5 cards, 10 times
      result =
        Enum.reduce(1..10, {[], deck}, fn _i, {acc, d} ->
          {cards, remaining} = Deck.deal_batch(d, 5)
          {acc ++ cards, remaining}
        end)

      {all_dealt, final_deck} = result

      assert length(all_dealt) == 50
      assert Deck.remaining(final_deck) == 2
      assert length(Enum.uniq(all_dealt)) == 50
    end
  end

  describe "draw/2" do
    test "draws the correct number of cards" do
      deck = shuffled_deck()
      {drawn, _remaining} = Deck.draw(deck, 5)

      assert length(drawn) == 5
    end

    test "removes drawn cards from the deck" do
      deck = shuffled_deck()
      {_drawn, remaining} = Deck.draw(deck, 5)

      assert Deck.remaining(remaining) == 47
    end

    test "is an alias for deal_batch/2" do
      deck = shuffled_deck()

      {drawn, remaining1} = Deck.draw(deck, 5)
      {dealt, remaining2} = Deck.deal_batch(deck, 5)

      assert drawn == dealt
      assert remaining1.cards == remaining2.cards
    end

    test "works with various counts" do
      deck = shuffled_deck()

      {drawn1, deck2} = Deck.draw(deck, 1)
      {drawn3, deck3} = Deck.draw(deck2, 3)
      {drawn10, _deck4} = Deck.draw(deck3, 10)

      assert length(drawn1) == 1
      assert length(drawn3) == 3
      assert length(drawn10) == 10
    end

    test "draws 0 cards when count is 0" do
      deck = shuffled_deck()
      {drawn, remaining} = Deck.draw(deck, 0)

      assert drawn == []
      assert Deck.remaining(remaining) == 52
    end

    test "drawing more than available returns all remaining" do
      deck = shuffled_deck()
      {_dealt, partial_deck} = Deck.deal_batch(deck, 50)

      {drawn, remaining} = Deck.draw(partial_deck, 10)

      assert length(drawn) == 2
      assert Deck.remaining(remaining) == 0
    end

    test "drawing from empty deck returns empty list" do
      deck = shuffled_deck()
      {_all, empty_deck} = Deck.draw(deck, 52)

      {drawn, remaining} = Deck.draw(empty_deck, 5)

      assert drawn == []
      assert Deck.remaining(remaining) == 0
    end
  end

  describe "remaining/1" do
    test "returns 52 for new deck" do
      deck = shuffled_deck()
      assert Deck.remaining(deck) == 52
    end

    test "returns 0 for empty deck" do
      deck = shuffled_deck()
      {_dealt, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0
    end

    test "returns correct count after dealing" do
      deck = shuffled_deck()

      {_dealt, remaining} = Deck.deal_batch(deck, 9)
      assert Deck.remaining(remaining) == 43

      {_dealt2, remaining2} = Deck.deal_batch(remaining, 9)
      assert Deck.remaining(remaining2) == 34

      {_dealt3, remaining3} = Deck.deal_batch(remaining2, 9)
      assert Deck.remaining(remaining3) == 25
    end

    test "returns correct count for various deck sizes" do
      deck = shuffled_deck()

      for count <- [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 51, 52] do
        {_dealt, remaining} = Deck.deal_batch(deck, count)
        assert Deck.remaining(remaining) == 52 - count
      end
    end

    test "returns 1 for single card deck" do
      deck = shuffled_deck()
      {_dealt, single_card} = Deck.deal_batch(deck, 51)

      assert Deck.remaining(single_card) == 1
    end

    test "remains accurate after shuffling" do
      deck = shuffled_deck()
      {_dealt, partial} = Deck.deal_batch(deck, 20)

      assert Deck.remaining(partial) == 32

      {cards, _chance} = Chance.shuffle(partial.cards, Chance.from_seed(9))

      assert Deck.remaining(%Deck{partial | cards: cards}) == 32
    end

    test "is consistent with length of cards list" do
      deck = shuffled_deck()

      for count <- [0, 10, 20, 30, 40, 50, 52] do
        {_dealt, remaining} = Deck.deal_batch(deck, count)
        assert Deck.remaining(remaining) == length(remaining.cards)
      end
    end
  end

  describe "deck struct" do
    test "has required fields" do
      deck = shuffled_deck()

      assert Map.has_key?(deck, :cards)
      assert Map.has_key?(deck, :shuffled?)
    end

    test "cards field is a list" do
      deck = shuffled_deck()
      assert is_list(deck.cards)
    end

    test "shuffled? field is a boolean" do
      deck = shuffled_deck()
      assert is_boolean(deck.shuffled?)
    end

    test "cards are tuples of {rank, suit}" do
      deck = shuffled_deck()

      for card <- deck.cards do
        assert {rank, suit} = card
        assert is_integer(rank)
        assert rank in 2..14
        assert suit in [:hearts, :diamonds, :clubs, :spades]
      end
    end
  end

  describe "complete game simulation" do
    test "Finnish Pidro complete deal scenario" do
      # Start with a fresh deck
      deck = shuffled_deck()
      assert Deck.remaining(deck) == 52

      # Deal 9 cards to each of 4 players
      {player1, deck2} = Deck.deal_batch(deck, 9)
      {player2, deck3} = Deck.deal_batch(deck2, 9)
      {player3, deck4} = Deck.deal_batch(deck3, 9)
      {player4, kitty_deck} = Deck.deal_batch(deck4, 9)

      # 16 cards remain (the "kitty" or "widow")
      assert Deck.remaining(kitty_deck) == 16

      # All players have 9 cards
      assert length(player1) == 9
      assert length(player2) == 9
      assert length(player3) == 9
      assert length(player4) == 9

      # All 52 cards are accounted for
      all_cards = player1 ++ player2 ++ player3 ++ player4 ++ kitty_deck.cards
      assert length(all_cards) == 52
      assert length(Enum.uniq(all_cards)) == 52
    end

    test "dealing and reshuffling scenario" do
      # Deal some cards
      deck = shuffled_deck()
      {_dealt, remaining} = Deck.deal_batch(deck, 30)

      assert Deck.remaining(remaining) == 22

      # Reshuffle the remaining cards from the chance stream
      {cards, _chance} = Chance.shuffle(remaining.cards, Chance.from_seed(9))
      reshuffled = %Deck{remaining | cards: cards}

      # Should still have 22 cards
      assert Deck.remaining(reshuffled) == 22

      # Should still be able to deal from reshuffled deck
      {more_dealt, final_deck} = Deck.deal_batch(reshuffled, 10)

      assert length(more_dealt) == 10
      assert Deck.remaining(final_deck) == 12
    end

    test "multiple new decks are independent" do
      deck1 = shuffled_deck(1)
      deck2 = shuffled_deck(2)

      {_dealt1, remaining1} = Deck.deal_batch(deck1, 10)
      {_dealt2, remaining2} = Deck.deal_batch(deck2, 20)

      # Each deck maintains its own state
      assert Deck.remaining(remaining1) == 42
      assert Deck.remaining(remaining2) == 32
      # Original deck unchanged
      assert Deck.remaining(deck1) == 52
      # Original deck unchanged
      assert Deck.remaining(deck2) == 52
    end
  end
end
