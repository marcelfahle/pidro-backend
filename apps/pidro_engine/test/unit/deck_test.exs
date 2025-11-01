defmodule Pidro.Core.DeckTest do
  use ExUnit.Case, async: true
  doctest Pidro.Core.Deck

  alias Pidro.Core.Deck

  describe "new/0" do
    test "creates a deck with exactly 52 cards" do
      deck = Deck.new()
      assert Deck.remaining(deck) == 52
    end

    test "creates a shuffled deck by default" do
      deck = Deck.new()
      assert deck.shuffled? == true
    end

    test "contains all 52 unique cards" do
      deck = Deck.new()
      cards = deck.cards

      # Verify all cards are unique
      assert length(cards) == length(Enum.uniq(cards))
    end

    test "contains all 4 suits" do
      deck = Deck.new()
      suits = deck.cards |> Enum.map(fn {_rank, suit} -> suit end) |> Enum.uniq()

      assert :hearts in suits
      assert :diamonds in suits
      assert :clubs in suits
      assert :spades in suits
      assert length(suits) == 4
    end

    test "contains all 13 ranks per suit" do
      deck = Deck.new()

      # Count cards per suit
      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        cards_in_suit = Enum.filter(deck.cards, fn {_rank, s} -> s == suit end)
        assert length(cards_in_suit) == 13, "Expected 13 cards in #{suit}"
      end
    end

    test "contains ranks 2 through 14 (Ace)" do
      deck = Deck.new()
      ranks = deck.cards |> Enum.map(fn {rank, _suit} -> rank end) |> Enum.uniq() |> Enum.sort()

      assert ranks == Enum.to_list(2..14)
    end

    test "each rank-suit combination appears exactly once" do
      deck = Deck.new()

      for suit <- [:hearts, :diamonds, :clubs, :spades],
          rank <- 2..14 do
        card_count = Enum.count(deck.cards, fn card -> card == {rank, suit} end)
        assert card_count == 1, "Expected exactly 1 #{rank} of #{suit}, got #{card_count}"
      end
    end

    test "creates different shuffles on multiple calls" do
      # While theoretically possible to get the same shuffle twice,
      # the probability is 1 / 52! which is astronomically small
      deck1 = Deck.new()
      deck2 = Deck.new()
      deck3 = Deck.new()

      # At least one should be different
      assert deck1.cards != deck2.cards or deck2.cards != deck3.cards
    end

    test "contains all point cards for Finnish Pidro" do
      deck = Deck.new()

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

  describe "shuffle/1" do
    test "maintains the same number of cards" do
      deck = Deck.new()
      original_count = Deck.remaining(deck)

      shuffled = Deck.shuffle(deck)

      assert Deck.remaining(shuffled) == original_count
    end

    test "sets shuffled? flag to true" do
      deck = Deck.new()
      shuffled = Deck.shuffle(deck)

      assert shuffled.shuffled? == true
    end

    test "contains the same cards (different order)" do
      deck = Deck.new()
      original_cards = Enum.sort(deck.cards)

      shuffled = Deck.shuffle(deck)
      shuffled_cards = Enum.sort(shuffled.cards)

      assert original_cards == shuffled_cards
    end

    test "randomizes card order" do
      deck = Deck.new()

      # Shuffle multiple times and expect different orders
      shuffled1 = Deck.shuffle(deck)
      shuffled2 = Deck.shuffle(deck)
      shuffled3 = Deck.shuffle(deck)

      # At least one should be different from the original
      assert shuffled1.cards != deck.cards or
             shuffled2.cards != deck.cards or
             shuffled3.cards != deck.cards
    end

    test "works with partially dealt deck" do
      deck = Deck.new()
      {_dealt, remaining} = Deck.deal_batch(deck, 20)

      assert Deck.remaining(remaining) == 32

      shuffled = Deck.shuffle(remaining)

      assert Deck.remaining(shuffled) == 32
      assert shuffled.shuffled? == true
    end

    test "works with empty deck" do
      deck = Deck.new()
      {_dealt, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0

      shuffled = Deck.shuffle(empty_deck)

      assert Deck.remaining(shuffled) == 0
      assert shuffled.shuffled? == true
    end

    test "maintains deck integrity after multiple shuffles" do
      deck = Deck.new()

      # Shuffle multiple times
      shuffled = deck
      |> Deck.shuffle()
      |> Deck.shuffle()
      |> Deck.shuffle()

      # Should still have all 52 cards
      assert Deck.remaining(shuffled) == 52

      # Should still have all unique cards
      assert length(Enum.uniq(shuffled.cards)) == 52
    end
  end

  describe "deal_batch/2" do
    test "deals the correct number of cards" do
      deck = Deck.new()
      {dealt, _remaining} = Deck.deal_batch(deck, 9)

      assert length(dealt) == 9
    end

    test "removes dealt cards from the deck" do
      deck = Deck.new()
      {_dealt, remaining} = Deck.deal_batch(deck, 9)

      assert Deck.remaining(remaining) == 43
    end

    test "returns both dealt cards and remaining deck" do
      deck = Deck.new()
      {dealt, remaining} = Deck.deal_batch(deck, 9)

      assert is_list(dealt)
      assert %Deck{} = remaining
      assert length(dealt) == 9
      assert Deck.remaining(remaining) == 43
    end

    test "dealt cards are removed from remaining deck" do
      deck = Deck.new()
      {dealt, remaining} = Deck.deal_batch(deck, 9)

      # No card in dealt should appear in remaining
      for card <- dealt do
        refute card in remaining.cards, "Card #{inspect(card)} should not be in remaining deck"
      end
    end

    test "can deal all 52 cards" do
      deck = Deck.new()
      {dealt, remaining} = Deck.deal_batch(deck, 52)

      assert length(dealt) == 52
      assert Deck.remaining(remaining) == 0
    end

    test "can deal cards in batches" do
      deck = Deck.new()

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
      deck = Deck.new()
      {dealt, remaining} = Deck.deal_batch(deck, 0)

      assert dealt == []
      assert Deck.remaining(remaining) == 52
    end

    test "deals cards from the top of the deck" do
      deck = Deck.new()
      top_cards = Enum.take(deck.cards, 3)

      {dealt, _remaining} = Deck.deal_batch(deck, 3)

      assert dealt == top_cards
    end

    test "maintains deck integrity after dealing" do
      deck = Deck.new()
      original_cards = Enum.sort(deck.cards)

      {dealt, remaining} = Deck.deal_batch(deck, 20)
      recombined = Enum.sort(dealt ++ remaining.cards)

      assert original_cards == recombined
    end

    test "typical Finnish Pidro deal (9 cards to 4 players)" do
      deck = Deck.new()

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
      deck = Deck.new()
      {_first_batch, partial_deck} = Deck.deal_batch(deck, 50)

      assert Deck.remaining(partial_deck) == 2

      {dealt, remaining} = Deck.deal_batch(partial_deck, 10)

      assert length(dealt) == 2
      assert Deck.remaining(remaining) == 0
    end

    test "dealing from empty deck returns empty list" do
      deck = Deck.new()
      {_all_cards, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0

      {dealt, remaining} = Deck.deal_batch(empty_deck, 5)

      assert dealt == []
      assert Deck.remaining(remaining) == 0
    end

    test "dealing from single card deck" do
      deck = Deck.new()
      {_dealt, single_card_deck} = Deck.deal_batch(deck, 51)

      assert Deck.remaining(single_card_deck) == 1

      {dealt, remaining} = Deck.deal_batch(single_card_deck, 1)

      assert length(dealt) == 1
      assert Deck.remaining(remaining) == 0
    end

    test "dealing exact number of remaining cards" do
      deck = Deck.new()
      {_dealt, partial_deck} = Deck.deal_batch(deck, 40)

      assert Deck.remaining(partial_deck) == 12

      {dealt, remaining} = Deck.deal_batch(partial_deck, 12)

      assert length(dealt) == 12
      assert Deck.remaining(remaining) == 0
    end

    test "dealing with negative count is not allowed (relies on guard clause)" do
      deck = Deck.new()

      # This should raise FunctionClauseError due to guard clause (count >= 0)
      assert_raise FunctionClauseError, fn ->
        Deck.deal_batch(deck, -1)
      end
    end

    test "multiple sequential deals from deck" do
      deck = Deck.new()

      # Deal 5 cards, 10 times
      result = Enum.reduce(1..10, {[], deck}, fn _i, {acc, d} ->
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
      deck = Deck.new()
      {drawn, _remaining} = Deck.draw(deck, 5)

      assert length(drawn) == 5
    end

    test "removes drawn cards from the deck" do
      deck = Deck.new()
      {_drawn, remaining} = Deck.draw(deck, 5)

      assert Deck.remaining(remaining) == 47
    end

    test "is an alias for deal_batch/2" do
      deck = Deck.new()

      {drawn, remaining1} = Deck.draw(deck, 5)
      {dealt, remaining2} = Deck.deal_batch(deck, 5)

      assert drawn == dealt
      assert remaining1.cards == remaining2.cards
    end

    test "works with various counts" do
      deck = Deck.new()

      {drawn1, deck2} = Deck.draw(deck, 1)
      {drawn3, deck3} = Deck.draw(deck2, 3)
      {drawn10, _deck4} = Deck.draw(deck3, 10)

      assert length(drawn1) == 1
      assert length(drawn3) == 3
      assert length(drawn10) == 10
    end

    test "draws 0 cards when count is 0" do
      deck = Deck.new()
      {drawn, remaining} = Deck.draw(deck, 0)

      assert drawn == []
      assert Deck.remaining(remaining) == 52
    end

    test "drawing more than available returns all remaining" do
      deck = Deck.new()
      {_dealt, partial_deck} = Deck.deal_batch(deck, 50)

      {drawn, remaining} = Deck.draw(partial_deck, 10)

      assert length(drawn) == 2
      assert Deck.remaining(remaining) == 0
    end

    test "drawing from empty deck returns empty list" do
      deck = Deck.new()
      {_all, empty_deck} = Deck.draw(deck, 52)

      {drawn, remaining} = Deck.draw(empty_deck, 5)

      assert drawn == []
      assert Deck.remaining(remaining) == 0
    end
  end

  describe "remaining/1" do
    test "returns 52 for new deck" do
      deck = Deck.new()
      assert Deck.remaining(deck) == 52
    end

    test "returns 0 for empty deck" do
      deck = Deck.new()
      {_dealt, empty_deck} = Deck.deal_batch(deck, 52)

      assert Deck.remaining(empty_deck) == 0
    end

    test "returns correct count after dealing" do
      deck = Deck.new()

      {_dealt, remaining} = Deck.deal_batch(deck, 9)
      assert Deck.remaining(remaining) == 43

      {_dealt2, remaining2} = Deck.deal_batch(remaining, 9)
      assert Deck.remaining(remaining2) == 34

      {_dealt3, remaining3} = Deck.deal_batch(remaining2, 9)
      assert Deck.remaining(remaining3) == 25
    end

    test "returns correct count for various deck sizes" do
      deck = Deck.new()

      for count <- [1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 51, 52] do
        {_dealt, remaining} = Deck.deal_batch(deck, count)
        assert Deck.remaining(remaining) == 52 - count
      end
    end

    test "returns 1 for single card deck" do
      deck = Deck.new()
      {_dealt, single_card} = Deck.deal_batch(deck, 51)

      assert Deck.remaining(single_card) == 1
    end

    test "remains accurate after shuffling" do
      deck = Deck.new()
      {_dealt, partial} = Deck.deal_batch(deck, 20)

      assert Deck.remaining(partial) == 32

      shuffled = Deck.shuffle(partial)

      assert Deck.remaining(shuffled) == 32
    end

    test "is consistent with length of cards list" do
      deck = Deck.new()

      for count <- [0, 10, 20, 30, 40, 50, 52] do
        {_dealt, remaining} = Deck.deal_batch(deck, count)
        assert Deck.remaining(remaining) == length(remaining.cards)
      end
    end
  end

  describe "deck struct" do
    test "has required fields" do
      deck = Deck.new()

      assert Map.has_key?(deck, :cards)
      assert Map.has_key?(deck, :shuffled?)
    end

    test "cards field is a list" do
      deck = Deck.new()
      assert is_list(deck.cards)
    end

    test "shuffled? field is a boolean" do
      deck = Deck.new()
      assert is_boolean(deck.shuffled?)
    end

    test "cards are tuples of {rank, suit}" do
      deck = Deck.new()

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
      deck = Deck.new()
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
      deck = Deck.new()
      {_dealt, remaining} = Deck.deal_batch(deck, 30)

      assert Deck.remaining(remaining) == 22

      # Reshuffle the remaining cards
      reshuffled = Deck.shuffle(remaining)

      # Should still have 22 cards
      assert Deck.remaining(reshuffled) == 22

      # Should still be able to deal from reshuffled deck
      {more_dealt, final_deck} = Deck.deal_batch(reshuffled, 10)

      assert length(more_dealt) == 10
      assert Deck.remaining(final_deck) == 12
    end

    test "multiple new decks are independent" do
      deck1 = Deck.new()
      deck2 = Deck.new()

      {_dealt1, remaining1} = Deck.deal_batch(deck1, 10)
      {_dealt2, remaining2} = Deck.deal_batch(deck2, 20)

      # Each deck maintains its own state
      assert Deck.remaining(remaining1) == 42
      assert Deck.remaining(remaining2) == 32
      assert Deck.remaining(deck1) == 52  # Original deck unchanged
      assert Deck.remaining(deck2) == 52  # Original deck unchanged
    end
  end
end
