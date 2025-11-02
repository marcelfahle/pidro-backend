defmodule Pidro.Properties.CardPropertiesTest do
  @moduledoc """
  Property-based tests for the Card module using StreamData.

  These tests verify fundamental invariants of the Pidro card system,
  particularly focusing on the Finnish variant rules including:
  - Deck composition (52 cards, 14 per suit including wrong 5)
  - Trump identification (right 5 and wrong 5)
  - Trump ranking order
  - Card comparison transitivity
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.Card
  alias Pidro.Core.Deck

  # =============================================================================
  # Generators
  # =============================================================================

  @doc """
  Generates valid card suits.
  """
  def suit do
    StreamData.member_of([:hearts, :diamonds, :clubs, :spades])
  end

  @doc """
  Generates valid card ranks (2-14, where 11=Jack, 12=Queen, 13=King, 14=Ace).
  """
  def rank do
    StreamData.integer(2..14)
  end

  # =============================================================================
  # Property: Deck Composition
  # =============================================================================

  property "deck always contains exactly 52 cards" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      deck = Deck.new()
      assert Deck.remaining(deck) == 52
    end
  end

  property "each suit contains exactly 13 ranks in a standard deck" do
    check all(suit_value <- suit(), max_runs: 100) do
      deck = Deck.new()
      {all_cards, _} = Deck.deal_batch(deck, 52)

      cards_of_suit = Enum.filter(all_cards, fn {_rank, card_suit} -> card_suit == suit_value end)
      assert length(cards_of_suit) == 13
    end
  end

  property "each suit contains exactly 14 cards when including cross-color 5 as trump" do
    check all(trump_suit <- suit(), max_runs: 100) do
      deck = Deck.new()
      {all_cards, _} = Deck.deal_batch(deck, 52)

      # Count all cards that are trump for this suit
      trump_cards = Enum.filter(all_cards, fn card -> Card.is_trump?(card, trump_suit) end)

      # Each suit has 13 cards + 1 wrong 5 from same-color suit = 14 trump cards
      assert length(trump_cards) == 14,
             "Expected 14 trump cards for #{trump_suit}, got #{length(trump_cards)}"
    end
  end

  # =============================================================================
  # Property: Wrong 5 Rule (Same-Color 5 is Trump)
  # =============================================================================

  property "5 of hearts is trump when hearts OR diamonds is trump" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      five_of_hearts = {5, :hearts}

      # 5 of hearts is trump when hearts is trump (right 5)
      assert Card.is_trump?(five_of_hearts, :hearts) == true

      # 5 of hearts is also trump when diamonds is trump (wrong 5)
      assert Card.is_trump?(five_of_hearts, :diamonds) == true

      # But NOT trump for black suits
      assert Card.is_trump?(five_of_hearts, :clubs) == false
      assert Card.is_trump?(five_of_hearts, :spades) == false
    end
  end

  property "5 of diamonds is trump when diamonds OR hearts is trump" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      five_of_diamonds = {5, :diamonds}

      # 5 of diamonds is trump when diamonds is trump (right 5)
      assert Card.is_trump?(five_of_diamonds, :diamonds) == true

      # 5 of diamonds is also trump when hearts is trump (wrong 5)
      assert Card.is_trump?(five_of_diamonds, :hearts) == true

      # But NOT trump for black suits
      assert Card.is_trump?(five_of_diamonds, :clubs) == false
      assert Card.is_trump?(five_of_diamonds, :spades) == false
    end
  end

  property "5 of clubs is trump when clubs OR spades is trump" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      five_of_clubs = {5, :clubs}

      # 5 of clubs is trump when clubs is trump (right 5)
      assert Card.is_trump?(five_of_clubs, :clubs) == true

      # 5 of clubs is also trump when spades is trump (wrong 5)
      assert Card.is_trump?(five_of_clubs, :spades) == true

      # But NOT trump for red suits
      assert Card.is_trump?(five_of_clubs, :hearts) == false
      assert Card.is_trump?(five_of_clubs, :diamonds) == false
    end
  end

  property "5 of spades is trump when spades OR clubs is trump" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      five_of_spades = {5, :spades}

      # 5 of spades is trump when spades is trump (right 5)
      assert Card.is_trump?(five_of_spades, :spades) == true

      # 5 of spades is also trump when clubs is trump (wrong 5)
      assert Card.is_trump?(five_of_spades, :clubs) == true

      # But NOT trump for red suits
      assert Card.is_trump?(five_of_spades, :hearts) == false
      assert Card.is_trump?(five_of_spades, :diamonds) == false
    end
  end

  # =============================================================================
  # Property: Trump Ranking Order
  # =============================================================================

  property "trump ranking is always: A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2" do
    check all(trump_suit <- suit(), max_runs: 100) do
      # Define the expected order of trump cards (highest to lowest)
      # Using ranks where Ace=14, King=13, Queen=12, Jack=11
      same_color = Card.same_color_suit(trump_suit)

      ordered_trumps = [
        # Ace
        {14, trump_suit},
        # King
        {13, trump_suit},
        # Queen
        {12, trump_suit},
        # Jack
        {11, trump_suit},
        # 10
        {10, trump_suit},
        # 9
        {9, trump_suit},
        # 8
        {8, trump_suit},
        # 7
        {7, trump_suit},
        # 6
        {6, trump_suit},
        # Right 5
        {5, trump_suit},
        # Wrong 5
        {5, same_color},
        # 4
        {4, trump_suit},
        # 3
        {3, trump_suit},
        # 2
        {2, trump_suit}
      ]

      # Verify each card beats the one after it
      ordered_trumps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [higher, lower] ->
        assert Card.compare(higher, lower, trump_suit) == :gt,
               "Expected #{inspect(higher)} > #{inspect(lower)} for trump #{trump_suit}"

        assert Card.compare(lower, higher, trump_suit) == :lt,
               "Expected #{inspect(lower)} < #{inspect(higher)} for trump #{trump_suit}"
      end)
    end
  end

  property "right pidro (5 of trump suit) always beats wrong pidro (5 of same-color suit)" do
    check all(trump_suit <- suit(), max_runs: 100) do
      right_five = {5, trump_suit}
      wrong_five = {5, Card.same_color_suit(trump_suit)}

      assert Card.compare(right_five, wrong_five, trump_suit) == :gt,
             "Right 5 (#{inspect(right_five)}) should beat Wrong 5 (#{inspect(wrong_five)}) when trump is #{trump_suit}"

      assert Card.compare(wrong_five, right_five, trump_suit) == :lt,
             "Wrong 5 (#{inspect(wrong_five)}) should lose to Right 5 (#{inspect(right_five)}) when trump is #{trump_suit}"
    end
  end

  property "ace of trump is always the highest trump card" do
    check all(trump_suit <- suit(), max_runs: 100) do
      ace_of_trump = {14, trump_suit}

      # Generate all other trump cards
      all_ranks = 2..14
      same_color = Card.same_color_suit(trump_suit)

      # All trump cards of the trump suit except ace
      trump_cards = for rank <- all_ranks, rank != 14, do: {rank, trump_suit}

      # Add the wrong 5
      all_trump_cards = [{5, same_color} | trump_cards]

      # Ace should beat every other trump card
      Enum.each(all_trump_cards, fn card ->
        assert Card.compare(ace_of_trump, card, trump_suit) == :gt,
               "Ace of trump #{inspect(ace_of_trump)} should beat #{inspect(card)}"
      end)
    end
  end

  property "2 of trump is always the lowest trump card" do
    check all(trump_suit <- suit(), max_runs: 100) do
      two_of_trump = {2, trump_suit}

      # Generate all other trump cards
      all_ranks = 3..14
      same_color = Card.same_color_suit(trump_suit)

      # All trump cards of the trump suit except 2
      trump_cards = for rank <- all_ranks, do: {rank, trump_suit}

      # Add the wrong 5
      all_trump_cards = [{5, same_color} | trump_cards]

      # 2 should lose to every other trump card
      Enum.each(all_trump_cards, fn card ->
        assert Card.compare(two_of_trump, card, trump_suit) == :lt,
               "2 of trump #{inspect(two_of_trump)} should lose to #{inspect(card)}"
      end)
    end
  end

  # =============================================================================
  # Property: Card Comparison Transitivity
  # =============================================================================

  property "card comparison is transitive (if A > B and B > C, then A > C)" do
    check all(trump_suit <- suit(), max_runs: 100) do
      # Generate three distinct trump cards
      same_color = Card.same_color_suit(trump_suit)

      # Use cards we know have different rankings
      # Ace (highest)
      card_a = {14, trump_suit}
      # 10 (middle)
      card_b = {10, trump_suit}
      # 2 (lowest)
      card_c = {2, trump_suit}

      # Verify transitivity: A > B, B > C => A > C
      assert Card.compare(card_a, card_b, trump_suit) == :gt
      assert Card.compare(card_b, card_c, trump_suit) == :gt
      assert Card.compare(card_a, card_c, trump_suit) == :gt

      # Test with wrong 5 in the mix
      # Right 5
      card_x = {5, trump_suit}
      # Wrong 5
      card_y = {5, same_color}
      # 4
      card_z = {4, trump_suit}

      # Verify: Right5 > Wrong5, Wrong5 > 4 => Right5 > 4
      assert Card.compare(card_x, card_y, trump_suit) == :gt
      assert Card.compare(card_y, card_z, trump_suit) == :gt
      assert Card.compare(card_x, card_z, trump_suit) == :gt
    end
  end

  property "card comparison is reflexive (A == A)" do
    check all(
            trump_suit <- suit(),
            rank <- StreamData.integer(2..14),
            max_runs: 100
          ) do
      card = {rank, trump_suit}

      assert Card.compare(card, card, trump_suit) == :eq,
             "Card #{inspect(card)} should equal itself"
    end
  end

  property "card comparison is antisymmetric (if A > B, then B < A)" do
    check all(trump_suit <- suit(), max_runs: 100) do
      # Ace
      card_a = {14, trump_suit}
      # 2
      card_b = {2, trump_suit}

      result_ab = Card.compare(card_a, card_b, trump_suit)
      result_ba = Card.compare(card_b, card_a, trump_suit)

      case result_ab do
        :gt -> assert result_ba == :lt
        :lt -> assert result_ba == :gt
        :eq -> assert result_ba == :eq
      end
    end
  end

  # =============================================================================
  # Property: Point Values
  # =============================================================================

  property "total points in any trump suit always equals 14" do
    check all(trump_suit <- suit(), max_runs: 100) do
      deck = Deck.new()
      {all_cards, _} = Deck.deal_batch(deck, 52)

      # Calculate total points for all cards
      total_points =
        all_cards
        |> Enum.map(fn card -> Card.point_value(card, trump_suit) end)
        |> Enum.sum()

      assert total_points == 14,
             "Expected total points to be 14 for trump suit #{trump_suit}, got #{total_points}"
    end
  end

  property "right 5 and wrong 5 are each worth 5 points" do
    check all(trump_suit <- suit(), max_runs: 100) do
      right_five = {5, trump_suit}
      wrong_five = {5, Card.same_color_suit(trump_suit)}

      assert Card.point_value(right_five, trump_suit) == 5,
             "Right 5 (#{inspect(right_five)}) should be worth 5 points"

      assert Card.point_value(wrong_five, trump_suit) == 5,
             "Wrong 5 (#{inspect(wrong_five)}) should be worth 5 points"
    end
  end

  property "ace, jack, 10, and 2 of trump are each worth 1 point" do
    check all(trump_suit <- suit(), max_runs: 100) do
      ace = {14, trump_suit}
      jack = {11, trump_suit}
      ten = {10, trump_suit}
      two = {2, trump_suit}

      assert Card.point_value(ace, trump_suit) == 1
      assert Card.point_value(jack, trump_suit) == 1
      assert Card.point_value(ten, trump_suit) == 1
      assert Card.point_value(two, trump_suit) == 1
    end
  end

  property "non-point trump cards are worth 0 points" do
    check all(trump_suit <- suit(), max_runs: 100) do
      # Non-point ranks: 3, 4, 6, 7, 8, 9, King (13), Queen (12)
      non_point_ranks = [3, 4, 6, 7, 8, 9, 12, 13]

      Enum.each(non_point_ranks, fn rank ->
        card = {rank, trump_suit}

        assert Card.point_value(card, trump_suit) == 0,
               "Card #{inspect(card)} should be worth 0 points"
      end)
    end
  end

  # =============================================================================
  # Property: Same-Color Suit Pairing
  # =============================================================================

  property "same_color_suit returns the correct paired suit" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # Red suits pair with each other
      assert Card.same_color_suit(:hearts) == :diamonds
      assert Card.same_color_suit(:diamonds) == :hearts

      # Black suits pair with each other
      assert Card.same_color_suit(:clubs) == :spades
      assert Card.same_color_suit(:spades) == :clubs
    end
  end

  property "same_color_suit is its own inverse" do
    check all(suit_value <- suit(), max_runs: 100) do
      # Note: renamed to suit_value to avoid shadowing the suit/0 function
      paired_suit = Card.same_color_suit(suit_value)
      back_to_original = Card.same_color_suit(paired_suit)

      assert back_to_original == suit_value,
             "same_color_suit should be its own inverse: #{suit_value} -> #{paired_suit} -> #{back_to_original}"
    end
  end

  # =============================================================================
  # Property: Non-Trump Cards
  # =============================================================================

  property "cards not matching trump suit or wrong 5 are not trump" do
    check all(
            trump_suit <- suit(),
            rank <- StreamData.integer(2..14),
            max_runs: 100
          ) do
      # Generate suits that are neither trump nor same-color
      other_suits =
        [:hearts, :diamonds, :clubs, :spades]
        |> Enum.reject(fn s -> s == trump_suit or s == Card.same_color_suit(trump_suit) end)

      # Test cards from other suits
      Enum.each(other_suits, fn suit ->
        card = {rank, suit}

        refute Card.is_trump?(card, trump_suit),
               "Card #{inspect(card)} should not be trump when trump is #{trump_suit}"
      end)
    end
  end

  property "non-trump cards have 0 point value" do
    check all(
            trump_suit <- suit(),
            rank <- StreamData.integer(2..14),
            max_runs: 100
          ) do
      # Generate suits that are neither trump nor same-color
      other_suits =
        [:hearts, :diamonds, :clubs, :spades]
        |> Enum.reject(fn s -> s == trump_suit or s == Card.same_color_suit(trump_suit) end)

      # Test cards from other suits
      Enum.each(other_suits, fn suit ->
        card = {rank, suit}

        assert Card.point_value(card, trump_suit) == 0,
               "Non-trump card #{inspect(card)} should be worth 0 points when trump is #{trump_suit}"
      end)
    end
  end
end
