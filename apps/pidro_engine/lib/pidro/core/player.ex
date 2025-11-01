defmodule Pidro.Core.Player do
  @moduledoc """
  Player operations for the Pidro game engine.

  This module provides functions for creating and managing player state,
  including hand management and card operations. In Finnish Pidro, players
  can be eliminated ("go cold") when they run out of trump cards.

  ## Player State

  A player has:
  - **position**: Their seat at the table (:north, :east, :south, :west)
  - **team**: Their team (:north_south or :east_west)
  - **hand**: List of cards currently held
  - **eliminated?**: Whether the player has gone "cold" (out of trumps)
  - **revealed_cards**: Non-trump cards revealed when going cold
  - **tricks_won**: Number of tricks won by this player

  ## Finnish Variant Rules

  - Players can only play trump cards
  - When a player runs out of trump cards, they "go cold" and are eliminated
  - Going cold reveals any remaining non-trump cards
  - Eliminated players do not participate in remaining tricks

  ## Examples

      iex> player = Player.new(:north, :north_south)
      %Player{position: :north, team: :north_south, hand: []}

      iex> player = Player.add_cards(player, [{14, :hearts}, {10, :hearts}])
      iex> Player.has_card?(player, {14, :hearts})
      true

      iex> player = Player.remove_card(player, {14, :hearts})
      iex> Player.has_card?(player, {14, :hearts})
      false
  """

  alias Pidro.Core.{Card, Types}

  @type t :: Types.Player.t()
  @type card :: Types.card()
  @type position :: Types.position()
  @type team :: Types.team()
  @type suit :: Types.suit()

  # =============================================================================
  # Player Creation
  # =============================================================================

  @doc """
  Creates a new player with the given position and team.

  The player starts with an empty hand and is not eliminated.

  ## Parameters
  - `position` - The player's position at the table
  - `team` - The player's team

  ## Returns
  A new Player struct

  ## Examples

      iex> Player.new(:north, :north_south)
      %Player{
        position: :north,
        team: :north_south,
        hand: [],
        eliminated?: false,
        revealed_cards: [],
        tricks_won: 0
      }
  """
  @spec new(position(), team()) :: t()
  def new(position, team)
      when position in [:north, :east, :south, :west] and
             team in [:north_south, :east_west] do
    %Types.Player{
      position: position,
      team: team,
      hand: [],
      eliminated?: false,
      revealed_cards: [],
      tricks_won: 0
    }
  end

  # =============================================================================
  # Hand Management
  # =============================================================================

  @doc """
  Adds cards to a player's hand.

  Cards are appended to the existing hand. Duplicate cards are allowed
  (though they shouldn't occur in normal gameplay).

  ## Parameters
  - `player` - The player to add cards to
  - `cards` - List of cards to add

  ## Returns
  Updated Player struct with cards added to hand

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])
      iex> length(player.hand)
      2

      iex> player = Player.add_cards(player, [{12, :hearts}])
      iex> length(player.hand)
      3
  """
  @spec add_cards(t(), [card()]) :: t()
  def add_cards(%Types.Player{} = player, cards) when is_list(cards) do
    %{player | hand: player.hand ++ cards}
  end

  @doc """
  Removes a specific card from a player's hand.

  If the card appears multiple times in the hand, only the first occurrence
  is removed. If the card is not in the hand, the player is returned unchanged.

  ## Parameters
  - `player` - The player to remove the card from
  - `card` - The card to remove

  ## Returns
  Updated Player struct with the card removed

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])
      iex> player = Player.remove_card(player, {14, :hearts})
      iex> player.hand
      [{13, :hearts}]

      iex> player = Player.remove_card(player, {10, :clubs})
      iex> player.hand
      [{13, :hearts}]  # Unchanged - card not in hand
  """
  @spec remove_card(t(), card()) :: t()
  def remove_card(%Types.Player{} = player, card) do
    case Enum.split_while(player.hand, fn c -> c != card end) do
      {before, [^card | after_card]} ->
        %{player | hand: before ++ after_card}

      {_hand, []} ->
        # Card not found in hand, return player unchanged
        player
    end
  end

  # =============================================================================
  # Card Queries
  # =============================================================================

  @doc """
  Checks if a player has a specific card in their hand.

  ## Parameters
  - `player` - The player to check
  - `card` - The card to look for

  ## Returns
  `true` if the player has the card, `false` otherwise

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])
      iex> Player.has_card?(player, {14, :hearts})
      true

      iex> Player.has_card?(player, {10, :clubs})
      false
  """
  @spec has_card?(t(), card()) :: boolean()
  def has_card?(%Types.Player{} = player, card) do
    card in player.hand
  end

  @doc """
  Returns all trump cards in a player's hand.

  A card is considered trump if:
  1. It matches the trump suit, OR
  2. It's a 5 of the same-color suit as trump (wrong 5 rule)

  ## Finnish Pidro Wrong 5 Rule
  - If Hearts is trump, 5 of Diamonds is also trump (wrong 5)
  - If Diamonds is trump, 5 of Hearts is also trump (wrong 5)
  - If Clubs is trump, 5 of Spades is also trump (wrong 5)
  - If Spades is trump, 5 of Clubs is also trump (wrong 5)

  ## Parameters
  - `player` - The player whose hand to check
  - `trump_suit` - The declared trump suit

  ## Returns
  List of trump cards in the player's hand (may be empty)

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [
      ...>   {14, :hearts},  # Trump (Ace of Hearts)
      ...>   {10, :hearts},  # Trump (10 of Hearts)
      ...>   {5, :diamonds}, # Trump (Wrong 5!)
      ...>   {13, :clubs},   # Not trump
      ...>   {7, :spades}    # Not trump
      ...> ])
      iex> trumps = Player.trump_cards(player, :hearts)
      iex> length(trumps)
      3
      iex> {5, :diamonds} in trumps
      true

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [{13, :clubs}, {7, :spades}])
      iex> Player.trump_cards(player, :hearts)
      []  # No trump cards
  """
  @spec trump_cards(t(), suit()) :: [card()]
  def trump_cards(%Types.Player{} = player, trump_suit)
      when trump_suit in [:hearts, :diamonds, :clubs, :spades] do
    Enum.filter(player.hand, fn card ->
      Card.is_trump?(card, trump_suit)
    end)
  end

  # =============================================================================
  # Player State Queries
  # =============================================================================

  @doc """
  Returns the number of cards in a player's hand.

  ## Parameters
  - `player` - The player to check

  ## Returns
  Non-negative integer representing the hand size

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> Player.hand_size(player)
      0

      iex> player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])
      iex> Player.hand_size(player)
      2
  """
  @spec hand_size(t()) :: non_neg_integer()
  def hand_size(%Types.Player{} = player) do
    length(player.hand)
  end

  @doc """
  Checks if a player is active (not eliminated).

  ## Parameters
  - `player` - The player to check

  ## Returns
  `true` if the player is active, `false` if eliminated

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> Player.active?(player)
      true

      iex> player = %{player | eliminated?: true}
      iex> Player.active?(player)
      false
  """
  @spec active?(t()) :: boolean()
  def active?(%Types.Player{} = player) do
    not player.eliminated?
  end

  @doc """
  Marks a player as eliminated ("going cold").

  When a player runs out of trump cards in Finnish Pidro, they "go cold"
  and cannot participate in remaining tricks. Any non-trump cards they
  still hold are revealed.

  ## Parameters
  - `player` - The player to eliminate

  ## Returns
  Updated Player struct marked as eliminated

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [{13, :clubs}, {7, :spades}])
      iex> player = Player.eliminate(player)
      iex> player.eliminated?
      true
      iex> player.revealed_cards
      [{13, :clubs}, {7, :spades}]
  """
  @spec eliminate(t()) :: t()
  def eliminate(%Types.Player{} = player) do
    %{player | eliminated?: true, revealed_cards: player.hand}
  end

  @doc """
  Returns non-trump cards in a player's hand.

  This is useful during the discarding phase when players must discard
  all non-trump cards (except the wrong 5, which is considered trump).

  ## Parameters
  - `player` - The player whose hand to check
  - `trump_suit` - The declared trump suit

  ## Returns
  List of non-trump cards in the player's hand (may be empty)

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player = Player.add_cards(player, [
      ...>   {14, :hearts},  # Trump
      ...>   {13, :clubs},   # Not trump
      ...>   {7, :spades}    # Not trump
      ...> ])
      iex> non_trumps = Player.non_trump_cards(player, :hearts)
      iex> length(non_trumps)
      2
      iex> {13, :clubs} in non_trumps
      true
  """
  @spec non_trump_cards(t(), suit()) :: [card()]
  def non_trump_cards(%Types.Player{} = player, trump_suit)
      when trump_suit in [:hearts, :diamonds, :clubs, :spades] do
    Enum.reject(player.hand, fn card ->
      Card.is_trump?(card, trump_suit)
    end)
  end

  @doc """
  Increments the number of tricks won by this player.

  ## Parameters
  - `player` - The player who won a trick

  ## Returns
  Updated Player struct with incremented tricks_won

  ## Examples

      iex> player = Player.new(:north, :north_south)
      iex> player.tricks_won
      0

      iex> player = Player.increment_tricks_won(player)
      iex> player.tricks_won
      1
  """
  @spec increment_tricks_won(t()) :: t()
  def increment_tricks_won(%Types.Player{} = player) do
    %{player | tricks_won: player.tricks_won + 1}
  end
end
