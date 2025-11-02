defmodule Pidro.Game.DealerRobTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Card
  alias Pidro.Game.DealerRob

  doctest DealerRob

  describe "select_best_cards/2" do
    test "selects exactly 6 cards from pool" do
      pool = [
        Card.new(14, :hearts),
        Card.new(13, :hearts),
        Card.new(12, :hearts),
        Card.new(11, :hearts),
        Card.new(10, :hearts),
        Card.new(9, :hearts),
        Card.new(8, :hearts),
        Card.new(7, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      assert length(result) == 6
    end

    test "prioritizes point cards over non-point cards" do
      pool = [
        # A♥ (1 pt) - should select
        Card.new(14, :hearts),
        # K♥ (0 pts)
        Card.new(13, :hearts),
        # Q♥ (0 pts)
        Card.new(12, :hearts),
        # J♥ (1 pt) - should select
        Card.new(11, :hearts),
        # 10♥ (1 pt) - should select
        Card.new(10, :hearts),
        # 5♥ (5 pts) - should select
        Card.new(5, :hearts),
        # 2♥ (1 pt) - should select
        Card.new(2, :hearts),
        # 3♥ (0 pts)
        Card.new(3, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # All point cards should be selected
      # A♥
      assert Card.new(14, :hearts) in result
      # J♥
      assert Card.new(11, :hearts) in result
      # 10♥
      assert Card.new(10, :hearts) in result
      # 5♥
      assert Card.new(5, :hearts) in result
      # 2♥
      assert Card.new(2, :hearts) in result

      # Should also select King (highest non-point trump)
      # K♥
      assert Card.new(13, :hearts) in result
    end

    test "prioritizes high-ranking cards when points are equal" do
      pool = [
        # K♥ (rank 13, 0 pts)
        Card.new(13, :hearts),
        # Q♥ (rank 12, 0 pts)
        Card.new(12, :hearts),
        # 9♥ (rank 9, 0 pts)
        Card.new(9, :hearts),
        # 8♥ (rank 8, 0 pts)
        Card.new(8, :hearts),
        # 7♥ (rank 7, 0 pts)
        Card.new(7, :hearts),
        # 6♥ (rank 6, 0 pts)
        Card.new(6, :hearts),
        # 4♥ (rank 4, 0 pts)
        Card.new(4, :hearts),
        # 3♥ (rank 3, 0 pts)
        Card.new(3, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Should select 6 highest ranked cards
      # K♥
      assert Card.new(13, :hearts) in result
      # Q♥
      assert Card.new(12, :hearts) in result
      # 9♥
      assert Card.new(9, :hearts) in result
      # 8♥
      assert Card.new(8, :hearts) in result
      # 7♥
      assert Card.new(7, :hearts) in result
      # 6♥
      assert Card.new(6, :hearts) in result

      # Should NOT select lowest cards
      refute Card.new(4, :hearts) in result
      refute Card.new(3, :hearts) in result
    end

    test "prioritizes trump over non-trump" do
      pool = [
        # A♥ trump (high priority)
        Card.new(14, :hearts),
        # K♥ trump
        Card.new(13, :hearts),
        # Q♥ trump
        Card.new(12, :hearts),
        # A♣ non-trump point card
        Card.new(14, :clubs),
        # K♣ non-trump
        Card.new(13, :clubs),
        # Q♣ non-trump
        Card.new(12, :clubs),
        # J♣ non-trump point card
        Card.new(11, :clubs),
        # 10♣ non-trump point card
        Card.new(10, :clubs)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # All trump should be selected first
      assert Card.new(14, :hearts) in result
      assert Card.new(13, :hearts) in result
      assert Card.new(12, :hearts) in result

      # Only 3 trump, so need 3 more cards
      # Should select highest non-trump by rank: A♣, K♣, Q♣
      assert Card.new(14, :clubs) in result
      assert Card.new(13, :clubs) in result
      assert Card.new(12, :clubs) in result

      # Should NOT select lower-ranked cards
      refute Card.new(11, :clubs) in result
      refute Card.new(10, :clubs) in result
    end

    test "handles wrong 5 as trump point card" do
      pool = [
        # A♥ trump
        Card.new(14, :hearts),
        # K♥ trump
        Card.new(13, :hearts),
        # 5♥ right-5 (trump, 5 pts)
        Card.new(5, :hearts),
        # 5♦ wrong-5 (trump, 5 pts)
        Card.new(5, :diamonds),
        # 9♥ trump
        Card.new(9, :hearts),
        # 8♥ trump
        Card.new(8, :hearts),
        # 7♥ trump
        Card.new(7, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Both 5s should be selected (point cards)
      # right-5
      assert Card.new(5, :hearts) in result
      # wrong-5
      assert Card.new(5, :diamonds) in result

      # High trumps should be selected
      assert Card.new(14, :hearts) in result
      assert Card.new(13, :hearts) in result
    end

    test "works with fewer than 6 cards in pool" do
      pool = [
        Card.new(14, :hearts),
        Card.new(5, :hearts),
        Card.new(11, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      assert length(result) == 3
      assert Enum.sort(result) == Enum.sort(pool)
    end

    test "handles pool with exactly 6 cards" do
      pool = [
        Card.new(14, :hearts),
        Card.new(13, :hearts),
        Card.new(12, :hearts),
        Card.new(11, :hearts),
        Card.new(10, :hearts),
        Card.new(9, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      assert length(result) == 6
      assert Enum.sort(result) == Enum.sort(pool)
    end

    test "realistic scenario: dealer has 3 trump, remaining deck has 10 cards" do
      # Dealer hand: 3 trump cards
      dealer_hand = [
        # A♥ (1 pt)
        Card.new(14, :hearts),
        # J♥ (1 pt)
        Card.new(11, :hearts),
        # 9♥ (0 pts)
        Card.new(9, :hearts)
      ]

      # Remaining deck: 7 trump + 3 non-trump
      remaining_deck = [
        # 5♥ (5 pts) - RIGHT FIVE
        Card.new(5, :hearts),
        # 5♦ (5 pts) - WRONG FIVE
        Card.new(5, :diamonds),
        # K♥ (0 pts)
        Card.new(13, :hearts),
        # 10♥ (1 pt)
        Card.new(10, :hearts),
        # 8♥ (0 pts)
        Card.new(8, :hearts),
        # 7♥ (0 pts)
        Card.new(7, :hearts),
        # 2♥ (1 pt)
        Card.new(2, :hearts),
        # Non-trump
        Card.new(6, :clubs),
        # Non-trump
        Card.new(4, :spades),
        # Non-trump
        Card.new(3, :diamonds)
      ]

      pool = dealer_hand ++ remaining_deck
      result = DealerRob.select_best_cards(pool, :hearts)

      # Should select all 6 point cards
      # A♥ (1 pt)
      assert Card.new(14, :hearts) in result
      # J♥ (1 pt)
      assert Card.new(11, :hearts) in result
      # 10♥ (1 pt)
      assert Card.new(10, :hearts) in result
      # 5♥ (5 pts)
      assert Card.new(5, :hearts) in result
      # 5♦ (5 pts)
      assert Card.new(5, :diamonds) in result
      # 2♥ (1 pt)
      assert Card.new(2, :hearts) in result

      # Total points in hand: 14 (perfect!)
      # Should NOT select K♥ (0 pts) even though it's high rank
    end

    test "prioritizes trump quantity over non-trump point cards" do
      pool = [
        # Point card (trump)
        Card.new(2, :hearts),
        # Low trump (no points)
        Card.new(9, :hearts),
        Card.new(8, :hearts),
        Card.new(7, :hearts),
        Card.new(6, :hearts),
        Card.new(4, :hearts),
        # Point cards (non-trump)
        Card.new(14, :spades),
        Card.new(13, :spades)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Should keep ALL 6 trump cards (even low ones)
      assert Card.new(2, :hearts) in result
      assert Card.new(9, :hearts) in result
      assert Card.new(8, :hearts) in result
      assert Card.new(7, :hearts) in result
      assert Card.new(6, :hearts) in result
      assert Card.new(4, :hearts) in result

      # Should NOT keep A♠ (even though it's a point card)
      refute Card.new(14, :spades) in result
      refute Card.new(13, :spades) in result
    end

    test "keeps 6 worthless trump over high non-trump" do
      pool = [
        # Low trump (6 cards)
        Card.new(9, :hearts),
        Card.new(8, :hearts),
        Card.new(7, :hearts),
        Card.new(6, :hearts),
        Card.new(4, :hearts),
        Card.new(3, :hearts),
        # High trump (2 cards)
        Card.new(13, :hearts),
        Card.new(12, :hearts),
        # High non-trump (4 cards)
        Card.new(14, :clubs),
        Card.new(14, :diamonds),
        Card.new(13, :clubs),
        Card.new(13, :diamonds)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Verify ALL selected cards are trump
      Enum.each(result, fn card ->
        assert Card.is_trump?(card, :hearts),
               "Expected only trump cards, but got #{inspect(card)}"
      end)

      # Should include high trump
      assert Card.new(13, :hearts) in result
      assert Card.new(12, :hearts) in result

      # Should include some low trump
      assert Card.new(9, :hearts) in result or Card.new(8, :hearts) in result

      # Should NOT include any non-trump
      refute Card.new(14, :clubs) in result
      refute Card.new(14, :diamonds) in result
    end

    test "all trump point cards are kept (lucky scenario)" do
      pool = [
        # All 6 point cards, all trump
        Card.new(14, :hearts),
        Card.new(11, :hearts),
        Card.new(10, :hearts),
        Card.new(5, :hearts),
        Card.new(5, :diamonds),
        Card.new(2, :hearts),
        # Extra trump
        Card.new(13, :hearts)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Should keep exactly the 6 point cards
      assert length(result) == 6

      # All point cards should be selected
      assert Card.new(14, :hearts) in result
      assert Card.new(11, :hearts) in result
      assert Card.new(10, :hearts) in result
      assert Card.new(5, :hearts) in result
      assert Card.new(5, :diamonds) in result
      assert Card.new(2, :hearts) in result

      # K♥ should NOT be selected (not a point card)
      refute Card.new(13, :hearts) in result
    end

    test "edge case: pool has <6 cards total" do
      pool = [
        Card.new(2, :hearts),
        Card.new(9, :hearts),
        Card.new(14, :spades)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      assert length(result) == 3, "Should return all 3 available cards"
      assert Enum.sort(result) == Enum.sort(pool)
    end

    test "edge case: pool has 0 trump" do
      pool = [
        Card.new(14, :spades),
        Card.new(13, :spades),
        Card.new(14, :clubs),
        Card.new(13, :clubs),
        Card.new(14, :diamonds),
        Card.new(13, :diamonds)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      # Should select 6 highest non-trump cards
      assert length(result) == 6

      # Verify no trump cards (since none available)
      trump_count = Enum.count(result, &Card.is_trump?(&1, :hearts))
      assert trump_count == 0, "No trump available in pool"

      # Should select all 6 aces and kings
      assert Enum.sort(result) == Enum.sort(pool)
    end

    test "edge case: pool has < 6 cards, mixed trump and non-trump" do
      pool = [
        Card.new(14, :hearts),
        Card.new(14, :spades),
        Card.new(9, :hearts),
        Card.new(13, :clubs)
      ]

      result = DealerRob.select_best_cards(pool, :hearts)

      assert length(result) == 4
      assert Enum.sort(result) == Enum.sort(pool)

      # Should have 2 trump (A♥, 9♥) + 2 non-trump
      trump_count = Enum.count(result, &Card.is_trump?(&1, :hearts))
      assert trump_count == 2
    end
  end
end
