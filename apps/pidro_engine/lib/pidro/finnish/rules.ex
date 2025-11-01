defmodule Pidro.Finnish.Rules do
  @moduledoc """
  Finnish Pidro variant-specific validation rules and game mechanics.

  This module implements the unique aspects of the Finnish variant:
  - Only trump cards can be played during tricks
  - Non-trump cards serve as "camouflage" to hide player strategy
  - Players are eliminated when they run out of trump cards ("going cold")
  - When eliminated, players reveal their remaining non-trump cards
  - Special validation rules for Finnish-specific game mechanics

  ## Finnish Variant Overview

  The Finnish variant of Pidro has several distinguishing characteristics:

  ### Trump-Only Play
  During the playing phase, only trump cards are valid plays. This includes:
  - All cards of the declared trump suit
  - The "wrong 5" (5 of the same-color suit)

  Non-trump cards cannot be played and serve only to conceal information
  about a player's trump holdings.

  ### Player Elimination ("Going Cold")
  When a player runs out of trump cards, they are eliminated from the hand:
  - The player can no longer participate in tricks
  - They must reveal all remaining non-trump cards in their hand
  - This is called "going cold"
  - Play continues with remaining active players

  ### Card Categories
  Cards fall into three categories:
  1. **Point Trumps**: Trump cards worth points (A, J, 10, 5, off-5, 2)
  2. **Non-Point Trumps**: Trump cards worth 0 points (K, Q, 9, 8, 7, 6, 4, 3)
  3. **Non-Trumps**: Cards that cannot be played (camouflage cards)

  ## Examples

      iex> alias Pidro.Finnish.Rules
      iex> # Check if a play is valid (must be trump)
      iex> Rules.valid_play?({14, :hearts}, :hearts)
      true

      iex> Rules.valid_play?({10, :clubs}, :hearts)
      false

      iex> # Wrong 5 is valid trump
      iex> Rules.valid_play?({5, :diamonds}, :hearts)
      true

      iex> # Check if player should be eliminated
      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Rules.should_eliminate_player?(hand, :hearts)
      true

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Rules.should_eliminate_player?(hand, :hearts)
      false
  """

  alias Pidro.Core.{Card, Types}

  @type card :: Types.card()
  @type suit :: Types.suit()
  @type hand :: [card()]

  # =============================================================================
  # Play Validation
  # =============================================================================

  @doc """
  Validates if a card can be played in the Finnish variant.

  In Finnish Pidro, only trump cards are valid plays. This includes:
  - All cards of the declared trump suit
  - The "wrong 5" (5 of the same-color suit)

  ## Parameters
  - `card` - The card being played
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if the card is a valid play (i.e., is trump), `false` otherwise

  ## Examples

      iex> Pidro.Finnish.Rules.valid_play?({14, :hearts}, :hearts)
      true

      iex> Pidro.Finnish.Rules.valid_play?({10, :clubs}, :hearts)
      false

      iex> Pidro.Finnish.Rules.valid_play?({5, :diamonds}, :hearts)
      true  # Wrong 5 is trump

      iex> Pidro.Finnish.Rules.valid_play?({5, :clubs}, :hearts)
      false  # Not same-color suit
  """
  @spec valid_play?(card(), suit()) :: boolean()
  def valid_play?(card, trump_suit) do
    Card.is_trump?(card, trump_suit)
  end

  @doc """
  Validates if a player can legally play a specific card from their hand.

  Checks two conditions:
  1. The card is in the player's hand
  2. The card is a valid play (must be trump in Finnish variant)

  ## Parameters
  - `card` - The card being played
  - `hand` - The player's current hand
  - `trump_suit` - The declared trump suit

  ## Returns
  - `{:ok, :valid}` if the play is legal
  - `{:error, :card_not_in_hand}` if player doesn't have the card
  - `{:error, :not_trump}` if the card is not a trump card

  ## Examples

      iex> hand = [{14, :hearts}, {10, :hearts}, {7, :clubs}]
      iex> Pidro.Finnish.Rules.validate_play({14, :hearts}, hand, :hearts)
      {:ok, :valid}

      iex> hand = [{14, :hearts}, {10, :hearts}]
      iex> Pidro.Finnish.Rules.validate_play({7, :clubs}, hand, :hearts)
      {:error, :card_not_in_hand}

      iex> hand = [{14, :hearts}, {7, :clubs}]
      iex> Pidro.Finnish.Rules.validate_play({7, :clubs}, hand, :hearts)
      {:error, :not_trump}
  """
  @spec validate_play(card(), hand(), suit()) :: {:ok, :valid} | {:error, atom()}
  def validate_play(card, hand, trump_suit) do
    cond do
      card not in hand ->
        {:error, :card_not_in_hand}

      not valid_play?(card, trump_suit) ->
        {:error, :not_trump}

      true ->
        {:ok, :valid}
    end
  end

  # =============================================================================
  # Player Elimination ("Going Cold")
  # =============================================================================

  @doc """
  Determines if a player should be eliminated from play.

  A player is eliminated ("goes cold") when they have no trump cards left.
  Once eliminated, they reveal all remaining non-trump cards and cannot
  participate in further tricks.

  ## Parameters
  - `hand` - The player's current hand
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if player has no trumps left (should be eliminated), `false` otherwise

  ## Examples

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.should_eliminate_player?(hand, :hearts)
      true

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.should_eliminate_player?(hand, :hearts)
      false

      iex> hand = []
      iex> Pidro.Finnish.Rules.should_eliminate_player?(hand, :hearts)
      true

      iex> # Player with only wrong 5 is still active
      iex> hand = [{5, :diamonds}]
      iex> Pidro.Finnish.Rules.should_eliminate_player?(hand, :hearts)
      false
  """
  @spec should_eliminate_player?(hand(), suit()) :: boolean()
  def should_eliminate_player?(hand, trump_suit) do
    not has_trump?(hand, trump_suit)
  end

  @doc """
  Checks if a hand contains any trump cards.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if hand contains at least one trump, `false` otherwise

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.has_trump?(hand, :hearts)
      true

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.has_trump?(hand, :hearts)
      false

      iex> hand = [{5, :diamonds}]
      iex> Pidro.Finnish.Rules.has_trump?(hand, :hearts)
      true  # Wrong 5 counts as trump
  """
  @spec has_trump?(hand(), suit()) :: boolean()
  def has_trump?(hand, trump_suit) do
    Enum.any?(hand, fn card -> Card.is_trump?(card, trump_suit) end)
  end

  @doc """
  Gets all trump cards from a hand.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  List of trump cards in the hand

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.get_trumps(hand, :hearts)
      [{14, :hearts}, {7, :hearts}]

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.get_trumps(hand, :hearts)
      []

      iex> # Wrong 5 is included
      iex> hand = [{5, :diamonds}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.get_trumps(hand, :hearts)
      [{5, :diamonds}]
  """
  @spec get_trumps(hand(), suit()) :: [card()]
  def get_trumps(hand, trump_suit) do
    Enum.filter(hand, fn card -> Card.is_trump?(card, trump_suit) end)
  end

  @doc """
  Gets all non-trump cards from a hand.

  Non-trump cards are "camouflage" cards that cannot be played but
  help conceal a player's strategy. When a player goes cold, these
  cards are revealed.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  List of non-trump cards in the hand

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.get_non_trumps(hand, :hearts)
      [{10, :clubs}]

      iex> hand = [{14, :hearts}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.get_non_trumps(hand, :hearts)
      []

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.get_non_trumps(hand, :hearts)
      [{10, :clubs}, {7, :spades}]
  """
  @spec get_non_trumps(hand(), suit()) :: [card()]
  def get_non_trumps(hand, trump_suit) do
    Enum.reject(hand, fn card -> Card.is_trump?(card, trump_suit) end)
  end

  @doc """
  Reveals the non-trump cards when a player goes cold.

  When a player runs out of trumps, they are eliminated and must reveal
  all remaining non-trump cards. This function returns those cards.

  ## Parameters
  - `hand` - The player's hand when going cold
  - `trump_suit` - The declared trump suit

  ## Returns
  List of non-trump cards to be revealed

  ## Examples

      iex> hand = [{10, :clubs}, {7, :spades}, {13, :diamonds}]
      iex> Pidro.Finnish.Rules.reveal_cards_going_cold(hand, :hearts)
      [{10, :clubs}, {7, :spades}, {13, :diamonds}]

      iex> # Player with only trumps reveals nothing (shouldn't happen)
      iex> hand = [{14, :hearts}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.reveal_cards_going_cold(hand, :hearts)
      []
  """
  @spec reveal_cards_going_cold(hand(), suit()) :: [card()]
  def reveal_cards_going_cold(hand, trump_suit) do
    get_non_trumps(hand, trump_suit)
  end

  # =============================================================================
  # Card Categorization
  # =============================================================================

  @doc """
  Categorizes all cards in a hand by type.

  Returns a map with three categories:
  - `:trumps` - Trump cards that can be played
  - `:non_trumps` - Non-trump cards (camouflage)
  - `:point_trumps` - Trump cards worth points

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  Map with categorized cards

  ## Examples

      iex> hand = [{14, :hearts}, {5, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.categorize_hand(hand, :hearts)
      %{
        trumps: [{14, :hearts}, {5, :hearts}, {7, :hearts}],
        non_trumps: [{10, :clubs}],
        point_trumps: [{14, :hearts}, {5, :hearts}]
      }
  """
  @spec categorize_hand(hand(), suit()) :: %{
          trumps: [card()],
          non_trumps: [card()],
          point_trumps: [card()]
        }
  def categorize_hand(hand, trump_suit) do
    trumps = get_trumps(hand, trump_suit)
    non_trumps = get_non_trumps(hand, trump_suit)
    point_trumps = Enum.filter(trumps, fn card -> Card.point_value(card, trump_suit) > 0 end)

    %{
      trumps: trumps,
      non_trumps: non_trumps,
      point_trumps: point_trumps
    }
  end

  @doc """
  Counts the number of trumps in a hand.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  Integer count of trump cards

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.count_trumps(hand, :hearts)
      2

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.count_trumps(hand, :hearts)
      0
  """
  @spec count_trumps(hand(), suit()) :: non_neg_integer()
  def count_trumps(hand, trump_suit) do
    hand
    |> get_trumps(trump_suit)
    |> length()
  end

  @doc """
  Counts the total point value of trump cards in a hand.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  Integer sum of all point values in the hand

  ## Examples

      iex> hand = [{14, :hearts}, {5, :hearts}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.count_points_in_hand(hand, :hearts)
      6  # Ace (1) + Right 5 (5)

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.count_points_in_hand(hand, :hearts)
      0
  """
  @spec count_points_in_hand(hand(), suit()) :: non_neg_integer()
  def count_points_in_hand(hand, trump_suit) do
    hand
    |> Enum.map(fn card -> Card.point_value(card, trump_suit) end)
    |> Enum.sum()
  end

  # =============================================================================
  # Finnish Variant Specifics
  # =============================================================================

  @doc """
  Gets the legal plays for a player in the Finnish variant.

  In Finnish Pidro, only trump cards can be played. This function returns
  all trump cards in the player's hand that can be legally played.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  List of cards that can be legally played (all trumps in hand)

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Pidro.Finnish.Rules.legal_plays(hand, :hearts)
      [{14, :hearts}, {7, :hearts}]

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.legal_plays(hand, :hearts)
      []
  """
  @spec legal_plays(hand(), suit()) :: [card()]
  def legal_plays(hand, trump_suit) do
    get_trumps(hand, trump_suit)
  end

  @doc """
  Checks if a player can still play (has at least one trump).

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  `true` if player can play (has trumps), `false` if eliminated

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.can_play?(hand, :hearts)
      true

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.can_play?(hand, :hearts)
      false
  """
  @spec can_play?(hand(), suit()) :: boolean()
  def can_play?(hand, trump_suit) do
    has_trump?(hand, trump_suit)
  end

  @doc """
  Returns information about a player's elimination status.

  ## Parameters
  - `hand` - The player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  Map with elimination information:
  - `:eliminated?` - Boolean indicating if player is eliminated
  - `:revealed_cards` - List of non-trump cards to reveal (if eliminated)
  - `:trumps_remaining` - Count of trump cards remaining

  ## Examples

      iex> hand = [{10, :clubs}, {7, :spades}]
      iex> Pidro.Finnish.Rules.elimination_status(hand, :hearts)
      %{
        eliminated?: true,
        revealed_cards: [{10, :clubs}, {7, :spades}],
        trumps_remaining: 0
      }

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Pidro.Finnish.Rules.elimination_status(hand, :hearts)
      %{
        eliminated?: false,
        revealed_cards: [],
        trumps_remaining: 1
      }
  """
  @spec elimination_status(hand(), suit()) :: %{
          eliminated?: boolean(),
          revealed_cards: [card()],
          trumps_remaining: non_neg_integer()
        }
  def elimination_status(hand, trump_suit) do
    eliminated? = should_eliminate_player?(hand, trump_suit)
    revealed_cards = if eliminated?, do: reveal_cards_going_cold(hand, trump_suit), else: []
    trumps_remaining = count_trumps(hand, trump_suit)

    %{
      eliminated?: eliminated?,
      revealed_cards: revealed_cards,
      trumps_remaining: trumps_remaining
    }
  end
end
