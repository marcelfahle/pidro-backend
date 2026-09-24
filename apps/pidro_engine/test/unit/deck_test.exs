defmodule Pidro.Core.DeckTest do
  use ExUnit.Case, async: true
  doctest Pidro.Core.Deck

  alias Pidro.Core.{Chance, Deck}

  # The deck the engine actually deals from: `Deck.ordered/0` permuted by a
  # fixed chance value. Nothing here draws from the calling process's RNG.
  defp shuffled_deck(seed \\ 1) do
    {cards, _chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(seed))
    cards
  end

  describe "ordered/0" do
    test "is the same 52 cards every time, in the same order" do
      assert Deck.ordered() == Deck.ordered()
      assert length(Deck.ordered()) == 52
    end

    test "is in generation order: hearts, diamonds, clubs, spades, each 2..A" do
      assert Enum.take(Deck.ordered(), 3) == [{2, :hearts}, {3, :hearts}, {4, :hearts}]
      assert List.last(Deck.ordered()) == {14, :spades}

      suit_order = Deck.ordered() |> Enum.map(fn {_rank, suit} -> suit end) |> Enum.dedup()
      assert suit_order == [:hearts, :diamonds, :clubs, :spades]
    end

    test "contains 52 distinct cards" do
      cards = Deck.ordered()

      assert length(Enum.uniq(cards)) == 52
    end

    test "contains all 4 suits, 13 cards each" do
      cards = Deck.ordered()

      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        assert Enum.count(cards, fn {_rank, s} -> s == suit end) == 13,
               "Expected 13 cards in #{suit}"
      end
    end

    test "contains ranks 2 through 14 (Ace)" do
      ranks =
        Deck.ordered() |> Enum.map(fn {rank, _suit} -> rank end) |> Enum.uniq() |> Enum.sort()

      assert ranks == Enum.to_list(2..14)
    end

    test "each rank-suit combination appears exactly once" do
      cards = Deck.ordered()

      for suit <- [:hearts, :diamonds, :clubs, :spades],
          rank <- 2..14 do
        card_count = Enum.count(cards, fn card -> card == {rank, suit} end)
        assert card_count == 1, "Expected exactly 1 #{rank} of #{suit}, got #{card_count}"
      end
    end

    test "contains all point cards for Finnish Pidro" do
      cards = Deck.ordered()

      # All fives (matters for the Right 5 and Wrong 5)
      assert Enum.count(cards, fn {rank, _suit} -> rank == 5 end) == 4
      # All Aces
      assert Enum.count(cards, fn {rank, _suit} -> rank == 14 end) == 4
      # All Jacks
      assert Enum.count(cards, fn {rank, _suit} -> rank == 11 end) == 4
      # All 10s
      assert Enum.count(cards, fn {rank, _suit} -> rank == 10 end) == 4
      # All 2s
      assert Enum.count(cards, fn {rank, _suit} -> rank == 2 end) == 4
    end

    test "cards are {rank, suit} tuples" do
      for {rank, suit} <- Deck.ordered() do
        assert is_integer(rank)
        assert rank in 2..14
        assert suit in [:hearts, :diamonds, :clubs, :spades]
      end
    end
  end

  describe "a deck shuffled from the chance stream" do
    test "is a permutation of the ordered deck" do
      assert Enum.sort(shuffled_deck()) == Enum.sort(Deck.ordered())
      refute shuffled_deck() == Deck.ordered()
    end

    test "different chance values produce different orders" do
      # There is no process-RNG deck constructor to be nondeterministic any
      # more: a deck's order is a function of the chance value it was shuffled
      # with, and the same value always produces the same deck.
      assert shuffled_deck(1) == shuffled_deck(1)
      refute shuffled_deck(1) == shuffled_deck(2)
    end

    test "reshuffling preserves the cards and changes the order" do
      deck = shuffled_deck()

      {cards, _chance} = Chance.shuffle(deck, Chance.from_seed(9))

      assert Enum.sort(cards) == Enum.sort(deck)
      refute cards == deck
    end

    test "survives repeated shuffles intact" do
      {cards, chance} = Chance.shuffle(shuffled_deck(), Chance.from_seed(9))
      {cards, chance} = Chance.shuffle(cards, chance)
      {cards, _chance} = Chance.shuffle(cards, chance)

      assert Enum.sort(cards) == Enum.sort(Deck.ordered())
    end

    test "the advanced stream gives the next shuffle a different order" do
      {first, chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(9))
      {second, _chance} = Chance.shuffle(Deck.ordered(), chance)

      refute first == second
    end

    test "shuffling an empty deck is valid and does not advance the stream" do
      chance = Chance.from_seed(9)

      assert {[], ^chance} = Chance.shuffle([], chance)
    end
  end
end
