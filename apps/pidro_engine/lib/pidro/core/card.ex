defmodule Pidro.Core.Card do
  @moduledoc """
  Card operations for the Pidro game engine.

  This module provides functions for creating, comparing, and evaluating cards
  in the Finnish variant of Pidro. It handles the complex trump ranking system
  including the "wrong 5" rule where the 5 of the same-color suit is considered
  a trump card.

  ## Finnish Pidro Card Rules

  ### Trump Ranking (Highest to Lowest)
  A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2

  Where:
  - **Right 5**: The 5 of the declared trump suit
  - **Wrong 5**: The 5 of the same-color suit
    - If hearts is trump, 5 of diamonds is wrong 5
    - If diamonds is trump, 5 of hearts is wrong 5
    - If clubs is trump, 5 of spades is wrong 5
    - If spades is trump, 5 of clubs is wrong 5

  ### Point Values
  - Ace: 1 point
  - Jack: 1 point
  - 10: 1 point
  - Right 5: 5 points
  - Wrong 5: 5 points
  - 2: 1 point
  - All other cards: 0 points

  **Total per suit: 14 points**

  ## Examples

      iex> Pidro.Core.Card.new(14, :hearts)
      {14, :hearts}

      iex> Pidro.Core.Card.is_trump?({14, :hearts}, :hearts)
      true

      iex> Pidro.Core.Card.is_trump?({5, :diamonds}, :hearts)
      true  # Wrong 5 is trump!

      iex> Pidro.Core.Card.point_value({5, :hearts}, :hearts)
      5  # Right 5

      iex> Pidro.Core.Card.point_value({5, :diamonds}, :hearts)
      5  # Wrong 5

      iex> Pidro.Core.Card.compare({14, :hearts}, {13, :hearts}, :hearts)
      :gt  # Ace beats King
  """

  alias Pidro.Core.Types

  @type card :: Types.card()
  @type suit :: Types.suit()
  @type rank :: Types.rank()

  # =============================================================================
  # Card Creation
  # =============================================================================

  @doc """
  Creates a new card with the given rank and suit.

  ## Parameters
  - `rank` - Card rank (2-14, where 11=Jack, 12=Queen, 13=King, 14=Ace)
  - `suit` - Card suit (`:hearts`, `:diamonds`, `:clubs`, or `:spades`)

  ## Returns
  A card tuple `{rank, suit}`

  ## Examples

      iex> Pidro.Core.Card.new(14, :hearts)
      {14, :hearts}

      iex> Pidro.Core.Card.new(5, :diamonds)
      {5, :diamonds}
  """
  @spec new(rank(), suit()) :: card()
  def new(rank, suit) when rank in 2..14 and suit in [:hearts, :diamonds, :clubs, :spades] do
    {rank, suit}
  end

  # =============================================================================
  # Trump Determination
  # =============================================================================

  @doc """
  Determines if a card is a trump card given the trump suit.

  A card is trump if:
  1. It matches the trump suit, OR
  2. It's a 5 of the same-color suit as trump (wrong 5 rule)

  ## Same-Color Pairs
  - Hearts <-> Diamonds (red)
  - Clubs <-> Spades (black)

  ## Parameters
  - `card` - The card to check
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if the card is trump, `false` otherwise

  ## Examples

      iex> Pidro.Core.Card.is_trump?({14, :hearts}, :hearts)
      true

      iex> Pidro.Core.Card.is_trump?({7, :hearts}, :hearts)
      true

      iex> Pidro.Core.Card.is_trump?({5, :diamonds}, :hearts)
      true  # Wrong 5!

      iex> Pidro.Core.Card.is_trump?({5, :hearts}, :hearts)
      true  # Right 5!

      iex> Pidro.Core.Card.is_trump?({10, :clubs}, :hearts)
      false
  """
  @spec is_trump?(card(), suit()) :: boolean()
  def is_trump?({rank, card_suit}, trump_suit) do
    cond do
      # Card matches trump suit
      card_suit == trump_suit ->
        true

      # Wrong 5 rule: 5 of same-color suit is trump
      rank == 5 and card_suit == same_color_suit(trump_suit) ->
        true

      # Not a trump card
      true ->
        false
    end
  end

  # =============================================================================
  # Card Comparison
  # =============================================================================

  @doc """
  Compares two cards within the trump suit ranking system.

  Returns:
  - `:gt` if card1 ranks higher than card2
  - `:eq` if cards are equal (same rank and suit)
  - `:lt` if card1 ranks lower than card2

  ## Trump Ranking Order (High to Low)
  A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2

  ## Parameters
  - `card1` - First card to compare
  - `card2` - Second card to compare
  - `trump_suit` - The declared trump suit

  ## Returns
  `:gt`, `:eq`, or `:lt`

  ## Examples

      iex> Pidro.Core.Card.compare({14, :hearts}, {13, :hearts}, :hearts)
      :gt

      iex> Pidro.Core.Card.compare({5, :hearts}, {5, :diamonds}, :hearts)
      :gt  # Right 5 beats Wrong 5

      iex> Pidro.Core.Card.compare({5, :diamonds}, {4, :hearts}, :hearts)
      :gt  # Wrong 5 beats 4

      iex> Pidro.Core.Card.compare({2, :hearts}, {4, :hearts}, :hearts)
      :lt  # 2 is lowest trump
  """
  @spec compare(card(), card(), suit()) :: :gt | :eq | :lt
  def compare({rank1, suit1}, {rank2, suit2}, trump_suit) do
    # Check for equality first
    if rank1 == rank2 and suit1 == suit2 do
      :eq
    else
      # Get trump rankings for both cards
      ranking1 = trump_ranking(rank1, suit1, trump_suit)
      ranking2 = trump_ranking(rank2, suit2, trump_suit)

      cond do
        ranking1 > ranking2 -> :gt
        ranking1 < ranking2 -> :lt
        true -> :eq
      end
    end
  end

  # =============================================================================
  # Point Value
  # =============================================================================

  @doc """
  Returns the point value of a card given the trump suit.

  ## Point Distribution
  - Ace: 1 point
  - Jack: 1 point
  - 10: 1 point
  - Right 5 (5 of trump suit): 5 points
  - Wrong 5 (5 of same-color suit): 5 points
  - 2: 1 point
  - All other cards: 0 points

  **Total points per suit: 14**

  ## Parameters
  - `card` - The card to evaluate
  - `trump_suit` - The declared trump suit

  ## Returns
  Integer from 0 to 5 representing the point value

  ## Examples

      iex> Pidro.Core.Card.point_value({14, :hearts}, :hearts)
      1  # Ace

      iex> Pidro.Core.Card.point_value({5, :hearts}, :hearts)
      5  # Right 5

      iex> Pidro.Core.Card.point_value({5, :diamonds}, :hearts)
      5  # Wrong 5

      iex> Pidro.Core.Card.point_value({11, :hearts}, :hearts)
      1  # Jack

      iex> Pidro.Core.Card.point_value({10, :hearts}, :hearts)
      1  # Ten

      iex> Pidro.Core.Card.point_value({2, :hearts}, :hearts)
      1  # Two

      iex> Pidro.Core.Card.point_value({7, :hearts}, :hearts)
      0  # No points
  """
  @spec point_value(card(), suit()) :: 0..5
  def point_value({rank, card_suit}, trump_suit) do
    cond do
      # Right 5: 5 of trump suit
      rank == 5 and card_suit == trump_suit ->
        5

      # Wrong 5: 5 of same-color suit
      rank == 5 and card_suit == same_color_suit(trump_suit) ->
        5

      # Ace, Jack, 10, 2 of trump suit: 1 point each
      rank == 14 and card_suit == trump_suit ->
        1

      rank == 11 and card_suit == trump_suit ->
        1

      rank == 10 and card_suit == trump_suit ->
        1

      rank == 2 and card_suit == trump_suit ->
        1

      # All other cards: 0 points
      true ->
        0
    end
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  @doc """
  Returns the same-color suit for a given suit.

  Used for determining the "wrong 5" in Finnish Pidro:
  - Hearts <-> Diamonds (red suits)
  - Clubs <-> Spades (black suits)

  ## Parameters
  - `suit` - The suit to find the same-color pair for

  ## Returns
  The same-color suit

  ## Examples

      iex> Pidro.Core.Card.same_color_suit(:hearts)
      :diamonds

      iex> Pidro.Core.Card.same_color_suit(:diamonds)
      :hearts

      iex> Pidro.Core.Card.same_color_suit(:clubs)
      :spades

      iex> Pidro.Core.Card.same_color_suit(:spades)
      :clubs
  """
  @spec same_color_suit(suit()) :: suit()
  def same_color_suit(:hearts), do: :diamonds
  def same_color_suit(:diamonds), do: :hearts
  def same_color_suit(:clubs), do: :spades
  def same_color_suit(:spades), do: :clubs

  @doc """
  Checks if a card is a point card.

  A card is considered a point card if it awards points in the trump suit.
  Point cards are: A, J, 10, Right-5, Wrong-5, 2

  ## Parameters
  - `card` - The card to check
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if the card is a point card, `false` otherwise

  ## Examples

      iex> Pidro.Core.Card.is_point_card?({14, :hearts}, :hearts)
      true  # Ace

      iex> Pidro.Core.Card.is_point_card?({11, :hearts}, :hearts)
      true  # Jack

      iex> Pidro.Core.Card.is_point_card?({5, :hearts}, :hearts)
      true  # Right 5

      iex> Pidro.Core.Card.is_point_card?({7, :hearts}, :hearts)
      false  # No points
  """
  @spec is_point_card?(card(), suit()) :: boolean()
  def is_point_card?(card, trump_suit) do
    point_value(card, trump_suit) > 0
  end

  @doc """
  Gets all non-point trump cards from a hand.

  Filters a hand to return only trump cards that don't award points.
  Non-point trumps are trump cards other than A, J, 10, Right-5, Wrong-5, 2.

  ## Parameters
  - `hand` - List of cards in the hand
  - `trump_suit` - The declared trump suit

  ## Returns
  List of non-point trump cards

  ## Examples

      iex> hand = [{14, :hearts}, {7, :hearts}, {6, :hearts}, {10, :clubs}]
      iex> Pidro.Core.Card.non_point_trumps(hand, :hearts)
      [{7, :hearts}, {6, :hearts}]
  """
  @spec non_point_trumps([card()], suit()) :: [card()]
  def non_point_trumps(hand, trump_suit) do
    hand
    |> Enum.filter(&is_trump?(&1, trump_suit))
    |> Enum.reject(&is_point_card?(&1, trump_suit))
  end

  @doc """
  Counts the number of trump cards in a hand.

  ## Parameters
  - `hand` - List of cards in the hand
  - `trump_suit` - The declared trump suit

  ## Returns
  The count of trump cards in the hand

  ## Examples

      iex> hand = [{14, :hearts}, {7, :hearts}, {5, :diamonds}, {5, :hearts}]
      iex> Pidro.Core.Card.count_trump(hand, :hearts)
      4

      iex> hand = [{10, :clubs}, {3, :spades}]
      iex> Pidro.Core.Card.count_trump(hand, :hearts)
      0
  """
  @spec count_trump([card()], suit()) :: non_neg_integer()
  def count_trump(hand, trump_suit) do
    Enum.count(hand, &is_trump?(&1, trump_suit))
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Returns the trump ranking for a card (higher number = better card)
  # Trump ranking: A(14) > K(13) > Q(12) > J(11) > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
  @spec trump_ranking(rank(), suit(), suit()) :: integer()
  defp trump_ranking(rank, card_suit, trump_suit) do
    cond do
      # Not a trump card: assign very low ranking
      not is_trump?({rank, card_suit}, trump_suit) ->
        -1000

      # Ace of trump: highest rank
      rank == 14 and card_suit == trump_suit ->
        14

      # King, Queen, Jack, 10, 9, 8, 7, 6 of trump: standard ranks
      rank in [13, 12, 11, 10, 9, 8, 7, 6] and card_suit == trump_suit ->
        rank

      # Right 5 (5 of trump suit): ranks between 6 and 4
      rank == 5 and card_suit == trump_suit ->
        5

      # Wrong 5 (5 of same-color suit): ranks just below Right 5
      rank == 5 and card_suit == same_color_suit(trump_suit) ->
        4.5

      # 4 of trump: ranks below Wrong 5
      rank == 4 and card_suit == trump_suit ->
        4

      # 3 of trump
      rank == 3 and card_suit == trump_suit ->
        3

      # 2 of trump: lowest rank
      rank == 2 and card_suit == trump_suit ->
        2

      # Default case (shouldn't reach here if is_trump? logic is correct)
      true ->
        0
    end
  end
end
