defmodule Pidro.Core.CardTest do
  use ExUnit.Case, async: true
  doctest Pidro.Core.Card

  alias Pidro.Core.Card

  describe "new/2" do
    test "creates valid cards for all ranks and suits" do
      for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades] do
        assert Card.new(rank, suit) == {rank, suit}
      end
    end

    test "creates Ace (rank 14)" do
      assert Card.new(14, :hearts) == {14, :hearts}
      assert Card.new(14, :diamonds) == {14, :diamonds}
      assert Card.new(14, :clubs) == {14, :clubs}
      assert Card.new(14, :spades) == {14, :spades}
    end

    test "creates King (rank 13)" do
      assert Card.new(13, :hearts) == {13, :hearts}
    end

    test "creates Queen (rank 12)" do
      assert Card.new(12, :hearts) == {12, :hearts}
    end

    test "creates Jack (rank 11)" do
      assert Card.new(11, :hearts) == {11, :hearts}
    end

    test "creates 5 cards (important for Finnish Pidro)" do
      assert Card.new(5, :hearts) == {5, :hearts}
      assert Card.new(5, :diamonds) == {5, :diamonds}
      assert Card.new(5, :clubs) == {5, :clubs}
      assert Card.new(5, :spades) == {5, :spades}
    end

    test "creates 2 cards (lowest trump)" do
      assert Card.new(2, :hearts) == {2, :hearts}
      assert Card.new(2, :diamonds) == {2, :diamonds}
      assert Card.new(2, :clubs) == {2, :clubs}
      assert Card.new(2, :spades) == {2, :spades}
    end

    test "raises FunctionClauseError for invalid rank below 2" do
      assert_raise FunctionClauseError, fn ->
        Card.new(1, :hearts)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new(0, :hearts)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new(-1, :hearts)
      end
    end

    test "raises FunctionClauseError for invalid rank above 14" do
      assert_raise FunctionClauseError, fn ->
        Card.new(15, :hearts)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new(100, :hearts)
      end
    end

    test "raises FunctionClauseError for invalid suit" do
      assert_raise FunctionClauseError, fn ->
        Card.new(10, :invalid)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new(10, :trump)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new(10, "hearts")
      end
    end

    test "raises FunctionClauseError for non-integer rank" do
      assert_raise FunctionClauseError, fn ->
        Card.new(10.5, :hearts)
      end

      assert_raise FunctionClauseError, fn ->
        Card.new("10", :hearts)
      end
    end
  end

  describe "is_trump?/2" do
    test "returns true for all cards of trump suit" do
      for rank <- 2..14 do
        assert Card.is_trump?({rank, :hearts}, :hearts) == true
        assert Card.is_trump?({rank, :diamonds}, :diamonds) == true
        assert Card.is_trump?({rank, :clubs}, :clubs) == true
        assert Card.is_trump?({rank, :spades}, :spades) == true
      end
    end

    test "returns false for non-trump cards (except wrong 5)" do
      # Clubs when hearts is trump (and not a 5)
      for rank <- [2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14] do
        assert Card.is_trump?({rank, :clubs}, :hearts) == false
        assert Card.is_trump?({rank, :spades}, :hearts) == false
      end
    end

    test "wrong 5 rule: 5 of diamonds is trump when hearts is trump" do
      assert Card.is_trump?({5, :diamonds}, :hearts) == true
      assert Card.is_trump?({5, :hearts}, :hearts) == true
    end

    test "wrong 5 rule: 5 of hearts is trump when diamonds is trump" do
      assert Card.is_trump?({5, :hearts}, :diamonds) == true
      assert Card.is_trump?({5, :diamonds}, :diamonds) == true
    end

    test "wrong 5 rule: 5 of spades is trump when clubs is trump" do
      assert Card.is_trump?({5, :spades}, :clubs) == true
      assert Card.is_trump?({5, :clubs}, :clubs) == true
    end

    test "wrong 5 rule: 5 of clubs is trump when spades is trump" do
      assert Card.is_trump?({5, :clubs}, :spades) == true
      assert Card.is_trump?({5, :spades}, :spades) == true
    end

    test "wrong 5 rule: 5 of wrong color is NOT trump" do
      # When hearts is trump, 5 of clubs/spades are not trump
      assert Card.is_trump?({5, :clubs}, :hearts) == false
      assert Card.is_trump?({5, :spades}, :hearts) == false

      # When diamonds is trump, 5 of clubs/spades are not trump
      assert Card.is_trump?({5, :clubs}, :diamonds) == false
      assert Card.is_trump?({5, :spades}, :diamonds) == false

      # When clubs is trump, 5 of hearts/diamonds are not trump
      assert Card.is_trump?({5, :hearts}, :clubs) == false
      assert Card.is_trump?({5, :diamonds}, :clubs) == false

      # When spades is trump, 5 of hearts/diamonds are not trump
      assert Card.is_trump?({5, :hearts}, :spades) == false
      assert Card.is_trump?({5, :diamonds}, :spades) == false
    end

    test "non-5 cards of same-color suit are NOT trump" do
      # Hearts trump, other red cards are not trump
      assert Card.is_trump?({14, :diamonds}, :hearts) == false
      assert Card.is_trump?({10, :diamonds}, :hearts) == false
      assert Card.is_trump?({2, :diamonds}, :hearts) == false

      # Clubs trump, other black cards are not trump
      assert Card.is_trump?({14, :spades}, :clubs) == false
      assert Card.is_trump?({10, :spades}, :clubs) == false
      assert Card.is_trump?({2, :spades}, :clubs) == false
    end
  end

  describe "compare/3 - equality" do
    test "returns :eq for identical cards" do
      assert Card.compare({14, :hearts}, {14, :hearts}, :hearts) == :eq
      assert Card.compare({5, :hearts}, {5, :hearts}, :hearts) == :eq
      assert Card.compare({2, :hearts}, {2, :hearts}, :hearts) == :eq
      assert Card.compare({5, :diamonds}, {5, :diamonds}, :hearts) == :eq
    end
  end

  describe "compare/3 - trump ranking order" do
    test "Ace beats all other trump cards" do
      for rank <- 2..13 do
        assert Card.compare({14, :hearts}, {rank, :hearts}, :hearts) == :gt
        assert Card.compare({rank, :hearts}, {14, :hearts}, :hearts) == :lt
      end

      # Ace beats wrong 5
      assert Card.compare({14, :hearts}, {5, :diamonds}, :hearts) == :gt
    end

    test "King beats all except Ace" do
      assert Card.compare({13, :hearts}, {14, :hearts}, :hearts) == :lt

      for rank <- 2..12 do
        assert Card.compare({13, :hearts}, {rank, :hearts}, :hearts) == :gt
        assert Card.compare({rank, :hearts}, {13, :hearts}, :hearts) == :lt
      end

      assert Card.compare({13, :hearts}, {5, :diamonds}, :hearts) == :gt
    end

    test "Queen beats Jack and below" do
      assert Card.compare({12, :hearts}, {14, :hearts}, :hearts) == :lt
      assert Card.compare({12, :hearts}, {13, :hearts}, :hearts) == :lt

      for rank <- 2..11 do
        assert Card.compare({12, :hearts}, {rank, :hearts}, :hearts) == :gt
        assert Card.compare({rank, :hearts}, {12, :hearts}, :hearts) == :lt
      end

      assert Card.compare({12, :hearts}, {5, :diamonds}, :hearts) == :gt
    end

    test "Jack beats 10 and below" do
      assert Card.compare({11, :hearts}, {14, :hearts}, :hearts) == :lt
      assert Card.compare({11, :hearts}, {13, :hearts}, :hearts) == :lt
      assert Card.compare({11, :hearts}, {12, :hearts}, :hearts) == :lt

      for rank <- 2..10 do
        assert Card.compare({11, :hearts}, {rank, :hearts}, :hearts) == :gt
        assert Card.compare({rank, :hearts}, {11, :hearts}, :hearts) == :lt
      end

      assert Card.compare({11, :hearts}, {5, :diamonds}, :hearts) == :gt
    end

    test "10 through 6 follow standard ranking" do
      # 10 > 9 > 8 > 7 > 6
      assert Card.compare({10, :hearts}, {9, :hearts}, :hearts) == :gt
      assert Card.compare({9, :hearts}, {8, :hearts}, :hearts) == :gt
      assert Card.compare({8, :hearts}, {7, :hearts}, :hearts) == :gt
      assert Card.compare({7, :hearts}, {6, :hearts}, :hearts) == :gt

      # All beat Right 5 and Wrong 5
      for rank <- 6..10 do
        assert Card.compare({rank, :hearts}, {5, :hearts}, :hearts) == :gt
        assert Card.compare({rank, :hearts}, {5, :diamonds}, :hearts) == :gt
      end
    end

    test "Right 5 beats Wrong 5" do
      # Hearts trump: right 5 of hearts beats wrong 5 of diamonds
      assert Card.compare({5, :hearts}, {5, :diamonds}, :hearts) == :gt
      assert Card.compare({5, :diamonds}, {5, :hearts}, :hearts) == :lt

      # Diamonds trump: right 5 of diamonds beats wrong 5 of hearts
      assert Card.compare({5, :diamonds}, {5, :hearts}, :diamonds) == :gt
      assert Card.compare({5, :hearts}, {5, :diamonds}, :diamonds) == :lt

      # Clubs trump: right 5 of clubs beats wrong 5 of spades
      assert Card.compare({5, :clubs}, {5, :spades}, :clubs) == :gt
      assert Card.compare({5, :spades}, {5, :clubs}, :clubs) == :lt

      # Spades trump: right 5 of spades beats wrong 5 of clubs
      assert Card.compare({5, :spades}, {5, :clubs}, :spades) == :gt
      assert Card.compare({5, :clubs}, {5, :spades}, :spades) == :lt
    end

    test "Right 5 beats 4, 3, and 2" do
      assert Card.compare({5, :hearts}, {4, :hearts}, :hearts) == :gt
      assert Card.compare({5, :hearts}, {3, :hearts}, :hearts) == :gt
      assert Card.compare({5, :hearts}, {2, :hearts}, :hearts) == :gt

      assert Card.compare({4, :hearts}, {5, :hearts}, :hearts) == :lt
      assert Card.compare({3, :hearts}, {5, :hearts}, :hearts) == :lt
      assert Card.compare({2, :hearts}, {5, :hearts}, :hearts) == :lt
    end

    test "Wrong 5 beats 4, 3, and 2" do
      # Wrong 5 of diamonds (when hearts is trump) beats 4, 3, 2 of hearts
      assert Card.compare({5, :diamonds}, {4, :hearts}, :hearts) == :gt
      assert Card.compare({5, :diamonds}, {3, :hearts}, :hearts) == :gt
      assert Card.compare({5, :diamonds}, {2, :hearts}, :hearts) == :gt

      assert Card.compare({4, :hearts}, {5, :diamonds}, :hearts) == :lt
      assert Card.compare({3, :hearts}, {5, :diamonds}, :hearts) == :lt
      assert Card.compare({2, :hearts}, {5, :diamonds}, :hearts) == :lt
    end

    test "4, 3, 2 ranking order" do
      # 4 > 3 > 2
      assert Card.compare({4, :hearts}, {3, :hearts}, :hearts) == :gt
      assert Card.compare({4, :hearts}, {2, :hearts}, :hearts) == :gt
      assert Card.compare({3, :hearts}, {2, :hearts}, :hearts) == :gt

      assert Card.compare({3, :hearts}, {4, :hearts}, :hearts) == :lt
      assert Card.compare({2, :hearts}, {4, :hearts}, :hearts) == :lt
      assert Card.compare({2, :hearts}, {3, :hearts}, :hearts) == :lt
    end

    test "2 is lowest trump card" do
      for rank <- 3..14 do
        assert Card.compare({2, :hearts}, {rank, :hearts}, :hearts) == :lt
        assert Card.compare({rank, :hearts}, {2, :hearts}, :hearts) == :gt
      end

      # 2 loses to wrong 5
      assert Card.compare({2, :hearts}, {5, :diamonds}, :hearts) == :lt
      assert Card.compare({5, :diamonds}, {2, :hearts}, :hearts) == :gt
    end

    test "complete trump ranking order from highest to lowest" do
      # A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
      trump_order = [
        # A
        {14, :hearts},
        # K
        {13, :hearts},
        # Q
        {12, :hearts},
        # J
        {11, :hearts},
        # 10
        {10, :hearts},
        # 9
        {9, :hearts},
        # 8
        {8, :hearts},
        # 7
        {7, :hearts},
        # 6
        {6, :hearts},
        # Right 5
        {5, :hearts},
        # Wrong 5
        {5, :diamonds},
        # 4
        {4, :hearts},
        # 3
        {3, :hearts},
        # 2
        {2, :hearts}
      ]

      # Test that each card beats all cards below it
      for {higher_card, i} <- Enum.with_index(trump_order) do
        for lower_card <- Enum.slice(trump_order, (i + 1)..-1//1) do
          assert Card.compare(higher_card, lower_card, :hearts) == :gt,
                 "Expected #{inspect(higher_card)} > #{inspect(lower_card)}"

          assert Card.compare(lower_card, higher_card, :hearts) == :lt,
                 "Expected #{inspect(lower_card)} < #{inspect(higher_card)}"
        end
      end
    end
  end

  describe "compare/3 - non-trump cards" do
    test "trump card always beats non-trump card" do
      # Lowest trump (2) beats any non-trump
      assert Card.compare({2, :hearts}, {14, :clubs}, :hearts) == :gt
      assert Card.compare({14, :clubs}, {2, :hearts}, :hearts) == :lt

      # Any trump beats non-trump
      assert Card.compare({10, :hearts}, {14, :clubs}, :hearts) == :gt
      assert Card.compare({14, :clubs}, {10, :hearts}, :hearts) == :lt
    end

    test "comparing two non-trump cards returns :eq (both have same low ranking)" do
      # Both non-trump cards get -1000 ranking, so they're equal
      # The Card module doesn't rank non-trump cards against each other
      assert Card.compare({14, :clubs}, {10, :clubs}, :hearts) == :eq
      assert Card.compare({10, :clubs}, {14, :clubs}, :hearts) == :eq
      assert Card.compare({10, :clubs}, {2, :clubs}, :hearts) == :eq
    end
  end

  describe "point_value/2 - Right 5" do
    test "Right 5 (5 of trump suit) is worth 5 points" do
      assert Card.point_value({5, :hearts}, :hearts) == 5
      assert Card.point_value({5, :diamonds}, :diamonds) == 5
      assert Card.point_value({5, :clubs}, :clubs) == 5
      assert Card.point_value({5, :spades}, :spades) == 5
    end
  end

  describe "point_value/2 - Wrong 5" do
    test "Wrong 5 (5 of same-color suit) is worth 5 points" do
      # Hearts trump -> 5 of diamonds is wrong 5
      assert Card.point_value({5, :diamonds}, :hearts) == 5

      # Diamonds trump -> 5 of hearts is wrong 5
      assert Card.point_value({5, :hearts}, :diamonds) == 5

      # Clubs trump -> 5 of spades is wrong 5
      assert Card.point_value({5, :spades}, :clubs) == 5

      # Spades trump -> 5 of clubs is wrong 5
      assert Card.point_value({5, :clubs}, :spades) == 5
    end

    test "5 of different color is worth 0 points" do
      # Hearts trump -> 5 of clubs/spades is 0 points
      assert Card.point_value({5, :clubs}, :hearts) == 0
      assert Card.point_value({5, :spades}, :hearts) == 0

      # Clubs trump -> 5 of hearts/diamonds is 0 points
      assert Card.point_value({5, :hearts}, :clubs) == 0
      assert Card.point_value({5, :diamonds}, :clubs) == 0
    end
  end

  describe "point_value/2 - Ace" do
    test "Ace of trump suit is worth 1 point" do
      assert Card.point_value({14, :hearts}, :hearts) == 1
      assert Card.point_value({14, :diamonds}, :diamonds) == 1
      assert Card.point_value({14, :clubs}, :clubs) == 1
      assert Card.point_value({14, :spades}, :spades) == 1
    end

    test "Ace of non-trump suit is worth 0 points" do
      assert Card.point_value({14, :diamonds}, :hearts) == 0
      assert Card.point_value({14, :clubs}, :hearts) == 0
      assert Card.point_value({14, :spades}, :hearts) == 0
    end
  end

  describe "point_value/2 - Jack" do
    test "Jack of trump suit is worth 1 point" do
      assert Card.point_value({11, :hearts}, :hearts) == 1
      assert Card.point_value({11, :diamonds}, :diamonds) == 1
      assert Card.point_value({11, :clubs}, :clubs) == 1
      assert Card.point_value({11, :spades}, :spades) == 1
    end

    test "Jack of non-trump suit is worth 0 points" do
      assert Card.point_value({11, :diamonds}, :hearts) == 0
      assert Card.point_value({11, :clubs}, :hearts) == 0
      assert Card.point_value({11, :spades}, :hearts) == 0
    end
  end

  describe "point_value/2 - 10" do
    test "10 of trump suit is worth 1 point" do
      assert Card.point_value({10, :hearts}, :hearts) == 1
      assert Card.point_value({10, :diamonds}, :diamonds) == 1
      assert Card.point_value({10, :clubs}, :clubs) == 1
      assert Card.point_value({10, :spades}, :spades) == 1
    end

    test "10 of non-trump suit is worth 0 points" do
      assert Card.point_value({10, :diamonds}, :hearts) == 0
      assert Card.point_value({10, :clubs}, :hearts) == 0
      assert Card.point_value({10, :spades}, :hearts) == 0
    end
  end

  describe "point_value/2 - 2" do
    test "2 of trump suit is worth 1 point" do
      assert Card.point_value({2, :hearts}, :hearts) == 1
      assert Card.point_value({2, :diamonds}, :diamonds) == 1
      assert Card.point_value({2, :clubs}, :clubs) == 1
      assert Card.point_value({2, :spades}, :spades) == 1
    end

    test "2 of non-trump suit is worth 0 points" do
      assert Card.point_value({2, :diamonds}, :hearts) == 0
      assert Card.point_value({2, :clubs}, :hearts) == 0
      assert Card.point_value({2, :spades}, :hearts) == 0
    end
  end

  describe "point_value/2 - non-point cards" do
    test "King, Queen, 9, 8, 7, 6, 4, 3 are worth 0 points even in trump suit" do
      non_point_ranks = [13, 12, 9, 8, 7, 6, 4, 3]

      for rank <- non_point_ranks do
        assert Card.point_value({rank, :hearts}, :hearts) == 0
        assert Card.point_value({rank, :diamonds}, :diamonds) == 0
        assert Card.point_value({rank, :clubs}, :clubs) == 0
        assert Card.point_value({rank, :spades}, :spades) == 0
      end
    end

    test "non-trump cards are always worth 0 points" do
      for rank <- 2..14 do
        # Test all suits except trump
        assert Card.point_value({rank, :diamonds}, :hearts) == 0 or rank == 5
        assert Card.point_value({rank, :clubs}, :hearts) == 0
        assert Card.point_value({rank, :spades}, :hearts) == 0
      end
    end
  end

  describe "point_value/2 - total points per suit" do
    test "each suit has exactly 14 points available" do
      for trump_suit <- [:hearts, :diamonds, :clubs, :spades] do
        total_points =
          Enum.sum(
            for rank <- 2..14 do
              Card.point_value({rank, trump_suit}, trump_suit)
            end
          )

        # Right 5 (5) + Wrong 5 (5) + Ace (1) + Jack (1) + 10 (1) + 2 (1) = 14
        wrong_5_suit = Card.same_color_suit(trump_suit)
        wrong_5_points = Card.point_value({5, wrong_5_suit}, trump_suit)

        assert total_points + wrong_5_points == 14,
               "Expected 14 total points for #{trump_suit} trump, got #{total_points + wrong_5_points}"
      end
    end

    test "hearts trump: 14 total points" do
      # Right 5 of hearts: 5 points
      # Wrong 5 of diamonds: 5 points
      # Ace of hearts: 1 point
      # Jack of hearts: 1 point
      # 10 of hearts: 1 point
      # 2 of hearts: 1 point
      # Total: 14 points

      points = [
        # 5
        Card.point_value({5, :hearts}, :hearts),
        # 5
        Card.point_value({5, :diamonds}, :hearts),
        # 1
        Card.point_value({14, :hearts}, :hearts),
        # 1
        Card.point_value({11, :hearts}, :hearts),
        # 1
        Card.point_value({10, :hearts}, :hearts),
        # 1
        Card.point_value({2, :hearts}, :hearts)
      ]

      assert Enum.sum(points) == 14
    end
  end

  describe "same_color_suit/1" do
    test "hearts and diamonds are same color (red)" do
      assert Card.same_color_suit(:hearts) == :diamonds
      assert Card.same_color_suit(:diamonds) == :hearts
    end

    test "clubs and spades are same color (black)" do
      assert Card.same_color_suit(:clubs) == :spades
      assert Card.same_color_suit(:spades) == :clubs
    end

    test "same_color_suit is symmetric" do
      for suit <- [:hearts, :diamonds, :clubs, :spades] do
        same_color = Card.same_color_suit(suit)

        assert Card.same_color_suit(same_color) == suit,
               "Expected same_color_suit(same_color_suit(#{suit})) == #{suit}"
      end
    end

    test "red suits never return black suits" do
      refute Card.same_color_suit(:hearts) in [:clubs, :spades]
      refute Card.same_color_suit(:diamonds) in [:clubs, :spades]
    end

    test "black suits never return red suits" do
      refute Card.same_color_suit(:clubs) in [:hearts, :diamonds]
      refute Card.same_color_suit(:spades) in [:hearts, :diamonds]
    end
  end

  describe "Finnish Pidro edge cases" do
    test "all trump cards including wrong 5 can be identified" do
      # When hearts is trump, there should be 14 trump cards
      trump_suit = :hearts

      all_cards =
        for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades], do: {rank, suit}

      trump_cards = Enum.filter(all_cards, fn card -> Card.is_trump?(card, trump_suit) end)

      # 13 hearts + 1 wrong 5 (5 of diamonds) = 14 trump cards
      assert length(trump_cards) == 14
    end

    test "wrong 5 is correctly identified for all trump suits" do
      assert Card.is_trump?({5, :diamonds}, :hearts) == true
      assert Card.is_trump?({5, :hearts}, :diamonds) == true
      assert Card.is_trump?({5, :spades}, :clubs) == true
      assert Card.is_trump?({5, :clubs}, :spades) == true
    end

    test "wrong 5 correctly beats 4 but loses to 6" do
      # Wrong 5 > 4
      assert Card.compare({5, :diamonds}, {4, :hearts}, :hearts) == :gt

      # 6 > Wrong 5
      assert Card.compare({6, :hearts}, {5, :diamonds}, :hearts) == :gt
    end

    test "right 5 correctly positioned in ranking" do
      # Right 5 > Wrong 5
      assert Card.compare({5, :hearts}, {5, :diamonds}, :hearts) == :gt

      # Right 5 > 4
      assert Card.compare({5, :hearts}, {4, :hearts}, :hearts) == :gt

      # 6 > Right 5
      assert Card.compare({6, :hearts}, {5, :hearts}, :hearts) == :gt
    end

    test "2 of trump has special point value (kept by player)" do
      # 2 is worth 1 point in card value
      assert Card.point_value({2, :hearts}, :hearts) == 1

      # Note: The special rule where player keeps 1 point is handled in Trick module,
      # not in Card module. Card module just reports the card's value.
    end

    test "maximum possible points in a single trick" do
      # Right 5 (5) + Wrong 5 (5) + Ace (1) + Jack (1) + 10 (1) + 2 (1) = 14
      # But 2 is kept by player, so winner gets 13
      # However, Card module doesn't handle this logic, just reports values

      cards = [
        # Right 5: 5 points
        {5, :hearts},
        # Wrong 5: 5 points
        {5, :diamonds},
        # Ace: 1 point
        {14, :hearts},
        # Jack: 1 point
        {11, :hearts}
      ]

      total = Enum.sum(Enum.map(cards, fn card -> Card.point_value(card, :hearts) end))
      assert total == 12
    end
  end

  describe "all trump suits behave consistently" do
    test "trump ranking order is consistent across all suits" do
      for trump_suit <- [:hearts, :diamonds, :clubs, :spades] do
        wrong_5_suit = Card.same_color_suit(trump_suit)

        # Ace beats everything
        assert Card.compare({14, trump_suit}, {5, trump_suit}, trump_suit) == :gt

        # Right 5 beats Wrong 5
        assert Card.compare({5, trump_suit}, {5, wrong_5_suit}, trump_suit) == :gt

        # Wrong 5 beats 4
        assert Card.compare({5, wrong_5_suit}, {4, trump_suit}, trump_suit) == :gt

        # 4 beats 3
        assert Card.compare({4, trump_suit}, {3, trump_suit}, trump_suit) == :gt

        # 3 beats 2
        assert Card.compare({3, trump_suit}, {2, trump_suit}, trump_suit) == :gt

        # 6 beats Right 5
        assert Card.compare({6, trump_suit}, {5, trump_suit}, trump_suit) == :gt
      end
    end

    test "point values are consistent across all trump suits" do
      for trump_suit <- [:hearts, :diamonds, :clubs, :spades] do
        wrong_5_suit = Card.same_color_suit(trump_suit)

        # Right 5: 5 points
        assert Card.point_value({5, trump_suit}, trump_suit) == 5

        # Wrong 5: 5 points
        assert Card.point_value({5, wrong_5_suit}, trump_suit) == 5

        # Ace: 1 point
        assert Card.point_value({14, trump_suit}, trump_suit) == 1

        # Jack: 1 point
        assert Card.point_value({11, trump_suit}, trump_suit) == 1

        # 10: 1 point
        assert Card.point_value({10, trump_suit}, trump_suit) == 1

        # 2: 1 point
        assert Card.point_value({2, trump_suit}, trump_suit) == 1

        # King: 0 points
        assert Card.point_value({13, trump_suit}, trump_suit) == 0
      end
    end
  end
end
