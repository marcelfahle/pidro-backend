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

      # All trump should be selected over non-trump
      assert Card.new(14, :hearts) in result
      assert Card.new(13, :hearts) in result
      assert Card.new(12, :hearts) in result

      # Non-trump point cards (A♣, J♣, 10♣) should be selected over non-trump non-point
      assert Card.new(14, :clubs) in result
      assert Card.new(11, :clubs) in result
      assert Card.new(10, :clubs) in result
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
  end

  describe "score_card/2" do
    test "scores ace of trump correctly" do
      card = Card.new(14, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 14 (rank) + 20 (point card) + 10 (trump) = 44
      assert score == 44
    end

    test "scores right-5 correctly" do
      card = Card.new(5, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 5 (rank) + 20 (point card) + 10 (trump) = 35
      assert score == 35
    end

    test "scores wrong-5 correctly" do
      # Hearts trump, so 5♦ is wrong-5 (same color = red)
      card = Card.new(5, :diamonds)
      score = DealerRob.score_card(card, :hearts)

      # 5 (rank) + 20 (point card, wrong-5) + 10 (trump) = 35
      assert score == 35
    end

    test "scores jack of trump correctly" do
      card = Card.new(11, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 11 (rank) + 20 (point card) + 10 (trump) = 41
      assert score == 41
    end

    test "scores king of trump (non-point) correctly" do
      card = Card.new(13, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 13 (rank) + 0 (not point card) + 10 (trump) = 23
      assert score == 23
    end

    test "scores non-trump point card correctly" do
      card = Card.new(14, :clubs)
      score = DealerRob.score_card(card, :hearts)

      # 14 (rank) + 20 (point card) + 0 (not trump) = 34
      assert score == 34
    end

    test "scores non-trump non-point card correctly" do
      card = Card.new(9, :clubs)
      score = DealerRob.score_card(card, :hearts)

      # 9 (rank) + 0 (not point) + 0 (not trump) = 9
      assert score == 9
    end

    test "scores two of trump correctly" do
      card = Card.new(2, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 2 (rank) + 20 (point card) + 10 (trump) = 32
      assert score == 32
    end

    test "scores ten of trump correctly" do
      card = Card.new(10, :hearts)
      score = DealerRob.score_card(card, :hearts)

      # 10 (rank) + 20 (point card) + 10 (trump) = 40
      assert score == 40
    end
  end
end
