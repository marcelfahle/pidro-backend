defmodule PidroServerWeb.CardHelpers do
  @moduledoc """
  Helper functions for card display and logic in Dev UI.

  Wraps Pidro.Core.Card functions for template use and provides
  additional formatting utilities for rendering cards in LiveView.

  ## Usage

  These functions are designed to be used in LiveView templates
  and components to display cards, hands, and game state.

      iex> CardHelpers.is_trump?({14, :hearts}, :hearts)
      true

      iex> CardHelpers.point_value({5, :hearts}, :hearts)
      5

      iex> CardHelpers.format_card({14, :hearts})
      "A♥"
  """

  alias Pidro.Core.Card

  @suits %{hearts: "♥", diamonds: "♦", clubs: "♣", spades: "♠"}
  @ranks %{14 => "A", 13 => "K", 12 => "Q", 11 => "J"}

  # =============================================================================
  # Trump and Point Value
  # =============================================================================

  @doc """
  Check if card is trump (including wrong 5).

  Wraps Pidro.Core.Card.is_trump?/2 for template use.

  ## Examples

      iex> CardHelpers.is_trump?({14, :hearts}, :hearts)
      true

      iex> CardHelpers.is_trump?({5, :diamonds}, :hearts)
      true  # Wrong 5 is trump

      iex> CardHelpers.is_trump?({14, :hearts}, nil)
      false
  """
  @spec is_trump?(Card.card(), Card.suit() | nil) :: boolean()
  def is_trump?(_card, nil), do: false
  def is_trump?(card, trump_suit), do: Card.is_trump?(card, trump_suit)

  @doc """
  Get point value of card.

  Returns the point value considering trump suit and wrong 5 rule.

  ## Examples

      iex> CardHelpers.point_value({14, :hearts}, :hearts)
      1  # Ace

      iex> CardHelpers.point_value({5, :hearts}, :hearts)
      5  # Right 5

      iex> CardHelpers.point_value({5, :diamonds}, :hearts)
      5  # Wrong 5

      iex> CardHelpers.point_value({7, :hearts}, :hearts)
      0  # No points
  """
  @spec point_value(Card.card(), Card.suit() | nil) :: 0..5
  def point_value(_card, nil), do: 0
  def point_value(card, trump_suit), do: Card.point_value(card, trump_suit)

  # =============================================================================
  # Hand Sorting
  # =============================================================================

  @doc """
  Sort hand for display: trump first, then by rank descending.

  This provides a logical ordering for displaying cards in the UI,
  grouping trump cards together and sorting by rank.

  ## Examples

      iex> hand = [{7, :hearts}, {14, :hearts}, {5, :diamonds}]
      iex> CardHelpers.sort_hand(hand, :hearts)
      [{14, :hearts}, {7, :hearts}, {5, :diamonds}]  # Trump ace, trump 7, wrong 5
  """
  @spec sort_hand([Card.card()], Card.suit() | nil) :: [Card.card()]
  def sort_hand(cards, trump_suit) do
    Enum.sort_by(cards, fn card ->
      is_trump = is_trump?(card, trump_suit)
      {rank, _suit} = card

      # Trump cards first (priority 0), then non-trump (priority 1)
      # Within each group, sort by rank descending
      trump_priority = if is_trump, do: 0, else: 1
      {trump_priority, -rank}
    end)
  end

  # =============================================================================
  # Card Formatting
  # =============================================================================

  @doc """
  Format card for display as rank + suit symbol.

  ## Examples

      iex> CardHelpers.format_card({14, :hearts})
      "A♥"

      iex> CardHelpers.format_card({5, :diamonds})
      "5♦"

      iex> CardHelpers.format_card({11, :spades})
      "J♠"
  """
  @spec format_card(Card.card()) :: String.t()
  def format_card({rank, suit}) do
    "#{format_rank(rank)}#{suit_symbol(suit)}"
  end

  @doc """
  Format rank for display.

  Converts numeric ranks to their letter representation for face cards.

  ## Examples

      iex> CardHelpers.format_rank(14)
      "A"

      iex> CardHelpers.format_rank(13)
      "K"

      iex> CardHelpers.format_rank(5)
      "5"
  """
  @spec format_rank(Card.rank()) :: String.t()
  def format_rank(rank) do
    Map.get(@ranks, rank, to_string(rank))
  end

  @doc """
  Get suit symbol for display.

  ## Examples

      iex> CardHelpers.suit_symbol(:hearts)
      "♥"

      iex> CardHelpers.suit_symbol(:spades)
      "♠"
  """
  @spec suit_symbol(Card.suit()) :: String.t()
  def suit_symbol(suit) do
    Map.get(@suits, suit, "?")
  end

  @doc """
  Get CSS color class for suit.

  Returns Tailwind CSS color class for the suit.

  ## Examples

      iex> CardHelpers.suit_color(:hearts)
      "text-red-600"

      iex> CardHelpers.suit_color(:spades)
      "text-gray-900"
  """
  @spec suit_color(Card.suit()) :: String.t()
  def suit_color(suit) when suit in [:hearts, :diamonds], do: "text-red-600"
  def suit_color(_), do: "text-gray-900"

  @doc """
  Format trump suit for display.

  ## Examples

      iex> CardHelpers.format_trump(:hearts)
      "♥ hearts"

      iex> CardHelpers.format_trump(nil)
      "Not declared"
  """
  @spec format_trump(Card.suit() | nil) :: String.t()
  def format_trump(nil), do: "Not declared"

  def format_trump(suit) do
    "#{suit_symbol(suit)} #{suit}"
  end

  # =============================================================================
  # Card Encoding for Events
  # =============================================================================

  @doc """
  Encode card as string for phx-value attributes.

  Used in templates to pass card data through phx-click events.

  ## Examples

      iex> CardHelpers.encode_card({14, :hearts})
      "14:hearts"
  """
  @spec encode_card(Card.card()) :: String.t()
  def encode_card({rank, suit}), do: "#{rank}:#{suit}"

  @doc """
  Decode card from string format.

  Inverse of encode_card/1, used in event handlers.

  ## Examples

      iex> CardHelpers.decode_card("14:hearts")
      {14, :hearts}
  """
  @spec decode_card(String.t()) :: Card.card()
  def decode_card(card_string) do
    [rank_str, suit_str] = String.split(card_string, ":")
    {String.to_integer(rank_str), String.to_existing_atom(suit_str)}
  end

  # =============================================================================
  # Suit Counting (for trump selection UI)
  # =============================================================================

  @doc """
  Count cards by suit in a hand.

  Returns a map with suit counts, useful for trump selection UI.

  ## Examples

      iex> hand = [{14, :hearts}, {13, :hearts}, {5, :diamonds}]
      iex> CardHelpers.count_suits(hand)
      %{hearts: 2, diamonds: 1}
  """
  @spec count_suits([Card.card()]) :: %{Card.suit() => non_neg_integer()}
  def count_suits(hand) do
    Enum.frequencies_by(hand, fn {_rank, suit} -> suit end)
  end
end
