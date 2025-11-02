defmodule Pidro.Game.DealerRob do
  @moduledoc """
  Automatic dealer rob card selection logic for Finnish Pidro.

  This module implements the "best 6 cards" selection strategy when
  auto_dealer_rob is enabled. The strategy prioritizes:

  1. **Trump point cards** (A, J, 10, Right-5, Wrong-5, 2 of trump suit ONLY)
  2. **Trump quantity** - maximize number of tricks dealer can participate in
  3. **High trump** (K, Q) - more likely to win tricks
  4. **High non-trump** (A, K, Q, J) - for disguise/variety

  ## Strategic Principle: Trump Quantity > Card Quality

  The key insight: **A dealer with 6 worthless trump (3,4,6,7,8,9) is stronger
  than a dealer with 2 good trump (K,Q) + 4 aces of other suits.**

  Why? Because the dealer with 6 trump participates in 6 tricks, giving them
  more opportunities to win points, protect their partner, and control the game.
  The dealer with only 2 trump goes "cold" after 2 tricks.

  ## Selection Algorithm

  Cards are categorized into priority buckets:

  1. **Trump point cards**: A, J, 10, Right-5, Wrong-5, 2 (trump suit ONLY)
  2. **High trump**: K, Q of trump suit (not point cards)
  3. **Low trump**: All other trump cards (9, 8, 7, 6, 4, 3)
  4. **High non-trump**: A, K, Q, J of non-trump suits (disguise)
  5. **Low non-trump**: Everything else

  Selection proceeds by concatenating buckets in order, then taking the first 6 cards.
  Within each bucket, cards are sorted by rank (high to low) for determinism.

  This ensures that **no non-trump card can ever displace a trump card**, regardless
  of rank or point value.

  ## Examples

  ### Example 1: Trump Quantity Priority

  Pool: 2♥, 9♥, 8♥, 7♥, 6♥, 4♥, A♠, K♠
  Result: 2♥, 9♥, 8♥, 7♥, 6♥, 4♥ (all 6 trump!)
  Discarded: A♠, K♠

  Even though A♠ is a point card, we keep all trump cards to maximize
  participation in tricks.

  ### Example 2: Mixed Pool

  Pool: A♥, K♥, Q♥, 10♥, 9♥, 8♥, 7♥, 2♥, A♠
  Result: A♥, 10♥, 2♥, K♥, Q♥, 9♥
  Discarded: 8♥, 7♥, A♠

  Point cards first (A♥, 10♥, 2♥), then high trump (K♥, Q♥), then low trump (9♥).
  We discard low trump (8♥, 7♥) and even A♠ to keep more trump overall.
  """

  alias Pidro.Core.{Card, Types}

  @type card :: Types.card()
  @type suit :: Types.suit()

  @doc """
  Selects the best 6 cards from the dealer's pool using bucket-based prioritization.

  The strategy maximizes trump quantity while prioritizing point cards.

  ## Parameters

  - `pool` - List of cards available to dealer (hand + remaining deck)
  - `trump_suit` - The declared trump suit

  ## Returns

  List of up to 6 cards, sorted by selection priority (highest priority first).

  ## Algorithm

  Cards are categorized into 5 priority buckets:
  1. Trump point cards (A, J, 10, Right-5, Wrong-5, 2 of trump suit)
  2. High trump (K, Q of trump suit)
  3. Low trump (all other trump: 9, 8, 7, 6, 4, 3)
  4. High non-trump (A, K, Q, J of non-trump suits)
  5. Low non-trump (everything else)

  Buckets are concatenated in priority order, sorted by rank within each bucket,
  then the first 6 cards are taken.

  ## Examples

      iex> pool = [Card.new(14, :hearts), Card.new(5, :hearts), Card.new(3, :clubs)]
      iex> DealerRob.select_best_cards(pool, :hearts)
      [{14, :hearts}, {5, :hearts}, {3, :clubs}]

      iex> # Trump quantity over non-trump quality
      iex> pool = [Card.new(2, :hearts), Card.new(9, :hearts), Card.new(8, :hearts),
      ...>         Card.new(7, :hearts), Card.new(6, :hearts), Card.new(4, :hearts),
      ...>         Card.new(14, :spades), Card.new(13, :spades)]
      iex> result = DealerRob.select_best_cards(pool, :hearts)
      iex> Enum.all?(result, &Card.is_trump?(&1, :hearts))
      true
  """
  @spec select_best_cards([card()], suit()) :: [card()]
  def select_best_cards(pool, trump_suit) when is_list(pool) do
    # Categorize cards into priority buckets
    {trump_point_cards, high_trump, low_trump, high_non_trump, low_non_trump} =
      categorize_cards(pool, trump_suit)

    # Build selection list in strict priority order
    # Within each category, sort by rank descending for determinism
    selection_list =
      sort_by_rank_desc(trump_point_cards) ++
        sort_by_rank_desc(high_trump) ++
        sort_by_rank_desc(low_trump) ++
        sort_by_rank_desc(high_non_trump) ++
        sort_by_rank_desc(low_non_trump)

    # Take first 6 cards (or all if less than 6)
    Enum.take(selection_list, 6)
  end

  # Categorizes cards into priority buckets for selection.
  #
  # Returns a 5-tuple of card lists:
  # {trump_point_cards, high_trump, low_trump, high_non_trump, low_non_trump}
  #
  # Priority order (highest to lowest):
  # 1. trump_point_cards: A, J, 10, Right-5, Wrong-5, 2 (trump suit ONLY)
  # 2. high_trump: K, Q of trump suit (non-point trump)
  # 3. low_trump: all other trump cards (9, 8, 7, 6, 4, 3)
  # 4. high_non_trump: A, K, Q, J of non-trump suits (disguise value)
  # 5. low_non_trump: all other non-trump cards
  @spec categorize_cards([card()], suit()) ::
          {[card()], [card()], [card()], [card()], [card()]}
  defp categorize_cards(pool, trump_suit) do
    Enum.reduce(pool, {[], [], [], [], []}, fn card, {tpt, ht, lt, hnt, lnt} ->
      cond do
        # PRIORITY 1: Trump point cards ONLY
        # Must be both: (1) trump AND (2) worth points
        # Non-trump aces, jacks, etc. have no trick-winning value
        is_trump_point_card?(card, trump_suit) ->
          {[card | tpt], ht, lt, hnt, lnt}

        # PRIORITY 2: High trump (K, Q of trump suit, non-point)
        # These win tricks and protect point cards
        is_high_trump?(card, trump_suit) ->
          {tpt, [card | ht], lt, hnt, lnt}

        # PRIORITY 3: Low trump (9,8,7,6,4,3 of trump)
        # CRITICAL: Even a 3♥ is more valuable than an A♠!
        # Each trump = 1 more trick the dealer can participate in
        Card.is_trump?(card, trump_suit) ->
          {tpt, ht, [card | lt], hnt, lnt}

        # PRIORITY 4: High non-trump (A, K, Q, J)
        # Only useful for disguising trump count from opponents
        is_high_non_trump?(card) ->
          {tpt, ht, lt, [card | hnt], lnt}

        # PRIORITY 5: Low non-trump (everything else)
        # First candidates for discard
        true ->
          {tpt, ht, lt, hnt, [card | lnt]}
      end
    end)
  end

  # Determines if a card is a trump point card.
  # Must satisfy BOTH conditions:
  # 1. Card is trump (including wrong-5)
  # 2. Card is worth points
  #
  # Uses existing Card.point_value/2 which already checks trump context:
  # - Returns > 0 only for trump cards that score points
  # - Returns 0 for all non-trump cards (even aces!)
  @spec is_trump_point_card?(card(), suit()) :: boolean()
  defp is_trump_point_card?(card, trump_suit) do
    Card.is_trump?(card, trump_suit) and Card.point_value(card, trump_suit) > 0
  end

  # Determines if a card is high trump (K, Q of trump suit, excluding point cards)
  @spec is_high_trump?(card(), suit()) :: boolean()
  defp is_high_trump?({rank, suit}, trump_suit) do
    suit == trump_suit and rank in [13, 12]
  end

  # Determines if a card is high non-trump (A, K, Q, J of non-trump suits)
  @spec is_high_non_trump?(card()) :: boolean()
  defp is_high_non_trump?({rank, _suit}) do
    rank in [14, 13, 12, 11]
  end

  # Sorts a list of cards by rank in descending order (high to low)
  @spec sort_by_rank_desc([card()]) :: [card()]
  defp sort_by_rank_desc(cards) do
    Enum.sort_by(cards, fn {rank, _suit} -> rank end, :desc)
  end
end
