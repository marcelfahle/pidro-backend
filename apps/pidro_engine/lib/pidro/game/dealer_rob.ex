defmodule Pidro.Game.DealerRob do
  @moduledoc """
  Automatic dealer rob card selection logic for Finnish Pidro.

  This module implements the "best 6 cards" selection strategy when
  auto_dealer_rob is enabled. The strategy prioritizes:

  1. Point cards (A, J, 10, Right-5, Wrong-5, 2) - worth points
  2. High trump cards (A, K, Q) - likely to win tricks
  3. Balance between strength and points

  ## Strategy

  The selection algorithm:
  - Always keeps point cards (14 points total available)
  - Prefers high-ranking trump over low-ranking trump
  - Balances offensive power (high cards) with points
  - Uses card score that combines rank and point value

  ## Examples

      iex> pool = [
      ...>   Card.new(14, :hearts),  # A♥ (1 pt, rank 14)
      ...>   Card.new(5, :hearts),   # 5♥ (5 pts, rank 5)
      ...>   Card.new(13, :hearts),  # K♥ (0 pts, rank 13)
      ...>   Card.new(11, :hearts),  # J♥ (1 pt, rank 11)
      ...>   Card.new(10, :hearts),  # 10♥ (1 pt, rank 10)
      ...>   Card.new(2, :hearts),   # 2♥ (1 pt, rank 2)
      ...>   Card.new(9, :hearts)    # 9♥ (0 pts, rank 9)
      ...> ]
      iex> result = DealerRob.select_best_cards(pool, :hearts)
      iex> length(result)
      6
  """

  alias Pidro.Core.{Card, Types}

  @type card :: Types.card()
  @type suit :: Types.suit()

  @doc """
  Selects the best 6 cards from the dealer's pool.

  Uses a scoring algorithm that combines:
  - Card rank (higher is better)
  - Point value (cards that score points)
  - Trump status (trump cards are preferred)

  ## Parameters

  - `pool` - List of cards available to dealer (hand + remaining deck)
  - `trump_suit` - The declared trump suit

  ## Returns

  List of exactly 6 cards, sorted by selection priority (highest score first).

  ## Algorithm

  Each card gets a score:
  - Base score: card rank (2-14)
  - Point bonus: +20 if card is a point card (A, J, 10, 5, 2)
  - Trump bonus: +10 if card is trump

  Cards sorted by score, top 6 selected.

  ## Examples

      iex> pool = [Card.new(14, :hearts), Card.new(5, :hearts), Card.new(3, :clubs)]
      iex> DealerRob.select_best_cards(pool, :hearts)
      [Card.new(14, :hearts), Card.new(5, :hearts), Card.new(3, :clubs)]
  """
  @spec select_best_cards([card()], suit()) :: [card()]
  def select_best_cards(pool, trump_suit) when is_list(pool) do
    pool
    |> Enum.map(fn card -> {card, score_card(card, trump_suit)} end)
    |> Enum.sort_by(fn {_card, score} -> score end, :desc)
    |> Enum.take(6)
    |> Enum.map(fn {card, _score} -> card end)
  end

  @doc """
  Scores a single card for selection priority.

  Higher scores = higher priority for selection.

  Scoring formula:
  - Rank: 2-14 (base value)
  - +20 if point card (A, J, 10, 5, 2)
  - +10 if trump card
  - Special: Right-5 and Wrong-5 get full point bonus

  ## Examples

      iex> DealerRob.score_card(Card.new(14, :hearts), :hearts)
      44  # Ace of trump: 14 (rank) + 20 (point) + 10 (trump)

      iex> DealerRob.score_card(Card.new(5, :hearts), :hearts)
      35  # Right-5: 5 (rank) + 20 (point) + 10 (trump)

      iex> DealerRob.score_card(Card.new(13, :hearts), :hearts)
      23  # King of trump: 13 (rank) + 10 (trump), no points

      iex> DealerRob.score_card(Card.new(9, :clubs), :hearts)
      9   # Non-trump, non-point: just rank
  """
  @spec score_card(card(), suit()) :: integer()
  def score_card({rank, _suit} = card, trump_suit) do
    base_score = rank
    point_bonus = if is_point_card?(card, trump_suit), do: 20, else: 0
    trump_bonus = if Card.is_trump?(card, trump_suit), do: 10, else: 0

    base_score + point_bonus + trump_bonus
  end

  # Point cards: A, J, 10, Right-5, Wrong-5, 2
  @spec is_point_card?(card(), suit()) :: boolean()
  defp is_point_card?({rank, suit}, trump_suit) do
    case rank do
      # Ace
      14 ->
        true

      # Jack
      11 ->
        true

      # Ten
      10 ->
        true

      # Two
      2 ->
        true

      5 ->
        # Right-5 (trump suit) or Wrong-5 (same color)
        suit == trump_suit or suit == Card.same_color_suit(trump_suit)

      _ ->
        false
    end
  end
end
