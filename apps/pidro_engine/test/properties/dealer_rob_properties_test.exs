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

    property "maximizes trump count in selection" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(6, 20),
              max_runs: 200
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        # Count trump in result
        trump_in_result = Enum.count(result, &Card.is_trump?(&1, trump_suit))

        # Count available trump in pool
        trump_in_pool = Enum.count(pool, &Card.is_trump?(&1, trump_suit))

        # INVARIANT: If pool has >= 6 trump, result should have 6 trump
        if trump_in_pool >= 6 do
          assert trump_in_result == 6,
                 """
                 Pool has #{trump_in_pool} trump cards but result only has #{trump_in_result}.
                 Expected all 6 selected cards to be trump.
                 Pool: #{inspect(pool)}
                 Result: #{inspect(result)}
                 """
        else
          # If pool has < 6 trump, result should have all available trump
          assert trump_in_result == trump_in_pool,
                 """
                 Pool has #{trump_in_pool} trump cards but result has #{trump_in_result}.
                 Expected all available trump to be selected.
                 Pool: #{inspect(pool)}
                 Result: #{inspect(result)}
                 """
        end
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

    property "no non-trump displaces trump (trump quantity priority)" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(8, 20),
              max_runs: 100
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        # Get cards NOT selected
        discarded = pool -- result

        # If any trump was discarded...
        discarded_trump = Enum.filter(discarded, &Card.is_trump?(&1, trump_suit))

        if length(discarded_trump) > 0 do
          # Then ALL non-trump in result must be trump point cards OR
          # we've selected all available trump already
          non_trump_in_result = Enum.reject(result, &Card.is_trump?(&1, trump_suit))

          # Count total trump in pool
          total_trump = Enum.count(pool, &Card.is_trump?(&1, trump_suit))

          # If we discarded trump but total trump >= 6, something is wrong
          # (unless the discarded trump are lower priority than non-trump point cards)
          if total_trump >= 6 do
            # All selected cards should be trump
            assert length(non_trump_in_result) == 0,
                   """
                   Found #{length(non_trump_in_result)} non-trump cards in result while
                   #{length(discarded_trump)} trump cards were discarded, and pool has #{total_trump} trump.
                   This violates the trump quantity priority rule.
                   Discarded trump: #{inspect(discarded_trump)}
                   Non-trump in result: #{inspect(non_trump_in_result)}
                   """
          end
        end
      end
    end

    property "trump point cards always selected first" do
      check all(
              trump_suit <- suit_gen(),
              pool <- numeric_cards(8, 20),
              max_runs: 100
            ) do
        result = DealerRob.select_best_cards(pool, trump_suit)

        # Find all trump point cards in pool
        trump_point_cards =
          Enum.filter(pool, fn card ->
            Card.is_trump?(card, trump_suit) and Card.point_value(card, trump_suit) > 0
          end)

        # If there are 6 or fewer trump point cards, ALL should be selected
        if length(trump_point_cards) <= 6 do
          Enum.each(trump_point_cards, fn card ->
            assert card in result,
                   """
                   Trump point card #{inspect(card)} not in result.
                   Trump point cards should always be selected first.
                   Result: #{inspect(result)}
                   """
          end)
        else
          # If more than 6 trump point cards (rare), result should contain only trump point cards
          Enum.each(result, fn card ->
            assert Card.is_trump?(card, trump_suit) and Card.point_value(card, trump_suit) > 0,
                   """
                   Found non-point-trump card #{inspect(card)} when 6+ trump point cards available.
                   Result: #{inspect(result)}
                   """
          end)
        end
      end
    end
  end
end
