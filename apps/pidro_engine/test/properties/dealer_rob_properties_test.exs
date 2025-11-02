defmodule Pidro.Properties.DealerRobPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.Card
  alias Pidro.Game.DealerRob

  @moduletag :property

  # Helper generators for numeric cards
  defp numeric_card do
    gen all(
          rank <- integer(2..14),
          suit <- member_of([:hearts, :diamonds, :clubs, :spades])
        ) do
      {rank, suit}
    end
  end

  defp numeric_cards(min_length, max_length) do
    uniq_list_of(numeric_card(), min_length: min_length, max_length: max_length)
  end

  defp suit_gen do
    member_of([:hearts, :diamonds, :clubs, :spades])
  end

  describe "DealerRob.select_best_cards/2 properties" do
    property "always selects exactly 6 cards when pool has 6+ cards" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(6, 20)
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        assert length(result) == 6
      end
    end

    property "selects all available cards when pool has <6 cards" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(1, 5)
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        assert length(result) == length(pool)
        # All cards from pool should be in result
        assert Enum.sort(result) == Enum.sort(pool)
      end
    end

    property "all selected cards come from the original pool" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(6, 20)
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        # Every selected card must be in original pool
        assert Enum.all?(result, fn card -> card in pool end)
      end
    end

    property "card scores are monotonic (higher score = better)" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(10, 20)
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        # Score all cards in pool
        scored_pool =
          pool
          |> Enum.map(fn card -> {card, DealerRob.score_card(card, trump_suit)} end)
          |> Enum.sort_by(fn {_card, score} -> score end, :desc)

        # Top 6 from scored pool should match result (order independent)
        expected =
          scored_pool
          |> Enum.take(6)
          |> Enum.map(fn {card, _score} -> card end)

        assert Enum.sort(result) == Enum.sort(expected)
      end
    end

    property "selecting from same pool twice gives same result (deterministic)" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(6, 20)
            ) do
        result1 = DealerRob.select_best_cards(pool, trump_suit)
        result2 = DealerRob.select_best_cards(pool, trump_suit)

        assert Enum.sort(result1) == Enum.sort(result2)
      end
    end

    property "result contains no duplicate cards" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(6, 20)
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        assert length(result) == length(Enum.uniq(result))
      end
    end
  end

  describe "score_card/2 properties" do
    property "score is always positive" do
      check all(
              trump_suit <- suit_gen(),
              card <- numeric_card()
            ) do
        score = DealerRob.score_card(card, trump_suit)

        assert score > 0
      end
    end

    property "ace of trump has highest possible score" do
      check all(trump_suit <- suit_gen()) do
        ace = Card.new(14, trump_suit)
        ace_score = DealerRob.score_card(ace, trump_suit)

        # Ace: 14 (rank) + 20 (point) + 10 (trump) = 44
        assert ace_score == 44
      end
    end
  end
end
