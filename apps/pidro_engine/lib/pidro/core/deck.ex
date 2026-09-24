defmodule Pidro.Core.Deck do
  @moduledoc """
  The 52 cards of a Pidro deck, in a fixed generation order.

  ## Deck Structure

  A standard 52-card deck consists of:
  - 4 suits: Hearts, Diamonds, Clubs, Spades
  - 13 ranks per suit: 2-10, Jack (11), Queen (12), King (13), Ace (14)

  This module is a definition, not a container. A deck in play is a plain list
  of cards held in `state.deck`; `Pidro.Game.Dealing` splits that list itself
  when it deals, so there is no deck struct and no dealing helper here.

  ## Shuffling

  This module does not shuffle. Shuffling is a draw on the game's explicit
  chance stream, so it belongs to `Pidro.Core.Chance`, which is the only module
  in the domain permitted to touch `:rand`:

      {cards, chance} = Pidro.Core.Chance.shuffle(Deck.ordered(), state.chance)
  """

  alias Pidro.Core.Types

  @type card :: Types.card()

  @doc """
  Returns the 52 cards in a fixed generation order, as a bare list.

  Order: Hearts (2-A), Diamonds (2-A), Clubs (2-A), Spades (2-A).

  This is the canonical unshuffled deck. It is the input the engine hands to
  `Pidro.Core.Chance.shuffle/2` to produce a deal, and the definition fixtures
  should build from rather than writing a 52-card literal.

  ## Examples

      iex> alias Pidro.Core.Deck
      iex> length(Deck.ordered())
      52

      iex> alias Pidro.Core.Deck
      iex> Deck.ordered() |> Enum.take(3)
      [{2, :hearts}, {3, :hearts}, {4, :hearts}]

      iex> alias Pidro.Core.Deck
      iex> Deck.ordered() == Deck.ordered()
      true
  """
  @spec ordered() :: [card()]
  def ordered do
    suits = [:hearts, :diamonds, :clubs, :spades]
    ranks = 2..14

    for suit <- suits,
        rank <- ranks do
      {rank, suit}
    end
  end
end
