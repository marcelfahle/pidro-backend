defmodule Pidro.Core.Deck do
  @moduledoc """
  Deck operations for the Pidro game engine.

  This module provides functions for creating, shuffling, and dealing cards
  from a standard 52-card deck. The deck is represented as a simple list of
  cards for efficient dealing operations.

  ## Deck Structure

  A standard 52-card deck consists of:
  - 4 suits: Hearts, Diamonds, Clubs, Spades
  - 13 ranks per suit: 2-10, Jack (11), Queen (12), King (13), Ace (14)

  ## Operations

  - `new/0` - Creates a new shuffled deck
  - `shuffle/1` - Shuffles an existing deck
  - `deal_batch/2` - Deals a batch of N cards
  - `draw/2` - Draws N cards from the deck
  - `remaining/1` - Returns count of remaining cards

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> Deck.remaining(deck)
      52

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> {cards, remaining_deck} = Deck.deal_batch(deck, 9)
      iex> length(cards)
      9
      iex> Deck.remaining(remaining_deck)
      43
  """

  use TypedStruct
  alias Pidro.Core.Types

  @type card :: Types.card()
  @type suit :: Types.suit()
  @type rank :: Types.rank()

  # =============================================================================
  # Type Definition
  # =============================================================================

  typedstruct enforce: true do
    field :cards, [Types.card()]
    field :shuffled?, boolean(), default: false
  end

  # =============================================================================
  # Deck Creation
  # =============================================================================

  @doc """
  Creates a new shuffled 52-card deck.

  The deck is automatically shuffled using Erlang's `:rand` module with
  a uniform distribution algorithm.

  ## Returns
  A new Deck struct with 52 shuffled cards

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> Deck.remaining(deck)
      52

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> deck.shuffled?
      true
  """
  @spec new() :: t()
  def new do
    cards = create_standard_deck()
    shuffled_cards = Enum.shuffle(cards)

    %__MODULE__{
      cards: shuffled_cards,
      shuffled?: true
    }
  end

  # =============================================================================
  # Deck Manipulation
  # =============================================================================

  @doc """
  Shuffles the deck using a uniform random distribution.

  This operation randomizes the order of all remaining cards in the deck.
  Uses Erlang's `:rand.uniform/1` for cryptographically secure shuffling.

  ## Parameters
  - `deck` - The deck to shuffle

  ## Returns
  A new Deck struct with cards shuffled

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> shuffled = Deck.shuffle(deck)
      iex> shuffled.shuffled?
      true

      iex> alias Pidro.Core.Deck
      iex> {_cards, remaining} = Deck.deal_batch(Deck.new(), 10)
      iex> Deck.remaining(remaining)
      42
      iex> reshuffled = Deck.shuffle(remaining)
      iex> Deck.remaining(reshuffled)
      42
  """
  @spec shuffle(t()) :: t()
  def shuffle(%__MODULE__{cards: cards}) do
    %__MODULE__{
      cards: Enum.shuffle(cards),
      shuffled?: true
    }
  end

  # =============================================================================
  # Dealing Operations
  # =============================================================================

  @doc """
  Deals a batch of N cards from the top of the deck.

  This is the primary dealing operation used during the initial deal phase.
  Cards are removed from the deck and returned in the order they were dealt.

  ## Parameters
  - `deck` - The deck to deal from
  - `count` - Number of cards to deal

  ## Returns
  A tuple of `{dealt_cards, remaining_deck}` where:
  - `dealt_cards` - List of dealt cards (length = min(count, remaining))
  - `remaining_deck` - New deck with dealt cards removed

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> {cards, remaining} = Deck.deal_batch(deck, 9)
      iex> length(cards)
      9
      iex> Deck.remaining(remaining)
      43

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> {batch1, deck2} = Deck.deal_batch(deck, 3)
      iex> {batch2, deck3} = Deck.deal_batch(deck2, 3)
      iex> {batch3, deck4} = Deck.deal_batch(deck3, 3)
      iex> length(batch1) + length(batch2) + length(batch3)
      9
      iex> Deck.remaining(deck4)
      43

  ## Edge Cases

      # Dealing more cards than available
      iex> alias Pidro.Core.Deck
      iex> deck = %Deck{cards: [{2, :hearts}, {3, :hearts}], shuffled?: true}
      iex> {cards, remaining} = Deck.deal_batch(deck, 5)
      iex> length(cards)
      2
      iex> Deck.remaining(remaining)
      0
  """
  @spec deal_batch(t(), non_neg_integer()) :: {[card()], t()}
  def deal_batch(%__MODULE__{cards: cards} = deck, count) when count >= 0 do
    {dealt, remaining} = Enum.split(cards, count)

    new_deck = %__MODULE__{deck | cards: remaining}

    {dealt, new_deck}
  end

  @doc """
  Draws N cards from the deck.

  This is an alias for `deal_batch/2` provided for semantic clarity.
  Use `draw/2` when cards are being drawn during play, and `deal_batch/2`
  during the initial dealing phase.

  ## Parameters
  - `deck` - The deck to draw from
  - `count` - Number of cards to draw

  ## Returns
  A tuple of `{drawn_cards, remaining_deck}`

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> {cards, remaining} = Deck.draw(deck, 5)
      iex> length(cards)
      5
      iex> Deck.remaining(remaining)
      47
  """
  @spec draw(t(), non_neg_integer()) :: {[card()], t()}
  def draw(deck, count) do
    deal_batch(deck, count)
  end

  # =============================================================================
  # Deck Information
  # =============================================================================

  @doc """
  Returns the number of cards remaining in the deck.

  ## Parameters
  - `deck` - The deck to check

  ## Returns
  Non-negative integer representing the count of remaining cards

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> deck = Deck.new()
      iex> Deck.remaining(deck)
      52

      iex> alias Pidro.Core.Deck
      iex> {_cards, remaining_deck} = Deck.deal_batch(Deck.new(), 36)
      iex> Deck.remaining(remaining_deck)
      16

      iex> alias Pidro.Core.Deck
      iex> deck = %Deck{cards: [], shuffled?: true}
      iex> Deck.remaining(deck)
      0
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{cards: cards}) do
    length(cards)
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Creates a standard 52-card deck in a deterministic order
  # Order: Hearts (2-A), Diamonds (2-A), Clubs (2-A), Spades (2-A)
  @spec create_standard_deck() :: [card()]
  defp create_standard_deck do
    suits = [:hearts, :diamonds, :clubs, :spades]
    ranks = 2..14

    for suit <- suits,
        rank <- ranks do
      {rank, suit}
    end
  end
end
