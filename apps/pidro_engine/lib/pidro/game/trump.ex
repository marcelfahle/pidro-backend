defmodule Pidro.Game.Trump do
  @moduledoc """
  Trump declaration and card categorization for the Pidro game engine.

  This module handles all aspects of trump suit declaration in Finnish Pidro,
  including:
  - Validating and declaring the trump suit
  - Categorizing cards into trump and non-trump groups
  - Properly handling the "wrong 5" rule
  - Recording events for trump declaration

  ## Finnish Pidro Trump Rules

  ### Trump Suit Declaration
  - The winning bidder declares the trump suit after bidding is complete
  - Must be one of the four suits: hearts, diamonds, clubs, or spades
  - Once declared, the trump suit cannot be changed for the hand

  ### Trump Card Identification
  - All cards of the declared trump suit are trump cards
  - The 5 of the same-color suit is also a trump card (wrong 5)
    - Hearts <-> Diamonds (red suits)
    - Clubs <-> Spades (black suits)
  - Non-trump cards are considered "camouflage" and cannot be played

  ### Card Categorization
  After trump is declared, each player's hand is categorized into:
  - Trump cards: Cards that can be played during tricks
  - Non-trump cards: Cards that must be discarded

  ## Examples

      # Declare trump suit
      iex> state = %{GameState.new() | phase: :declaring, current_turn: :north}
      iex> {:ok, state} = Trump.declare_trump(state, :hearts)
      iex> state.trump_suit
      :hearts
      iex> state.phase
      :discarding

      # Categorize a player's hand
      iex> hand = [{14, :hearts}, {5, :diamonds}, {10, :clubs}, {7, :hearts}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [{14, :hearts}, {5, :diamonds}, {7, :hearts}], non_trump: [{10, :clubs}]}
  """

  alias Pidro.Core.{Types, Card, GameState}
  alias Pidro.Game.Errors

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type suit :: Types.suit()
  @type card :: Types.card()
  @type error :: Errors.error()

  # =============================================================================
  # Trump Declaration
  # =============================================================================

  @doc """
  Declares the trump suit for the current hand.

  This function validates that trump declaration is valid in the current
  game state, then updates the state with the declared trump suit and
  transitions to the discarding phase.

  ## Parameters
  - `state` - Current game state
  - `trump_suit` - The suit to declare as trump (:hearts, :diamonds, :clubs, or :spades)

  ## Returns
  - `{:ok, state}` - Updated state with trump suit declared
  - `{:error, reason}` - If declaration is invalid

  ## State Changes
  - Sets `trump_suit` to the declared suit
  - Adds `{:trump_declared, suit}` event
  - Transitions `phase` to `:discarding`
  - Maintains `current_turn` as the bidding winner (who will discard first)

  ## Validation
  - Game must be in `:declaring` phase
  - Trump suit must be a valid suit atom
  - Trump suit must not already be declared

  ## Examples

      iex> state = %{GameState.new() | phase: :declaring, current_turn: :north}
      iex> {:ok, state} = Trump.declare_trump(state, :hearts)
      iex> state.trump_suit
      :hearts
      iex> state.phase
      :discarding

      iex> state = %{GameState.new() | phase: :bidding}
      iex> Trump.declare_trump(state, :hearts)
      {:error, {:invalid_phase, :declaring, :bidding}}
  """
  @spec declare_trump(game_state(), suit()) :: {:ok, game_state()} | {:error, error()}
  def declare_trump(%Types.GameState{} = state, trump_suit) do
    with :ok <- validate_declaring_phase(state),
         :ok <- validate_trump_suit(trump_suit),
         :ok <- validate_trump_not_declared(state) do
      # Update state with trump suit
      updated_state =
        state
        |> GameState.update(:trump_suit, trump_suit)
        |> GameState.update(:events, state.events ++ [{:trump_declared, trump_suit}])
        |> GameState.update(:phase, :discarding)

      {:ok, updated_state}
    end
  end

  # Validates game is in declaring phase
  @spec validate_declaring_phase(game_state()) :: :ok | {:error, error()}
  defp validate_declaring_phase(%Types.GameState{phase: :declaring}), do: :ok

  defp validate_declaring_phase(%Types.GameState{phase: actual_phase}) do
    {:error, {:invalid_phase, :declaring, actual_phase}}
  end

  # Validates trump suit is a valid suit
  @spec validate_trump_suit(any()) :: :ok | {:error, error()}
  defp validate_trump_suit(suit) when suit in [:hearts, :diamonds, :clubs, :spades], do: :ok
  defp validate_trump_suit(suit), do: {:error, {:invalid_suit, suit}}

  # Validates trump has not already been declared
  @spec validate_trump_not_declared(game_state()) :: :ok | {:error, error()}
  defp validate_trump_not_declared(%Types.GameState{trump_suit: nil}), do: :ok

  defp validate_trump_not_declared(%Types.GameState{trump_suit: suit}),
    do: {:error, {:trump_already_declared, suit}}

  # =============================================================================
  # Card Categorization
  # =============================================================================

  @doc """
  Categorizes a hand of cards into trump and non-trump cards.

  This function uses `Pidro.Core.Card.is_trump?/2` to properly identify
  trump cards, which automatically handles the "wrong 5" rule where the
  5 of the same-color suit is considered a trump card.

  ## Parameters
  - `hand` - List of cards to categorize
  - `trump_suit` - The declared trump suit

  ## Returns
  A map with two keys:
  - `:trump` - List of trump cards (including wrong 5)
  - `:non_trump` - List of non-trump cards (camouflage cards)

  ## Trump Identification
  A card is considered trump if:
  1. It matches the declared trump suit, OR
  2. It's a 5 of the same-color suit (wrong 5)

  ## Same-Color Pairs
  - Hearts <-> Diamonds (red suits)
  - Clubs <-> Spades (black suits)

  ## Examples

      # Simple case: trump and non-trump cards
      iex> hand = [{14, :hearts}, {10, :clubs}, {7, :hearts}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [{14, :hearts}, {7, :hearts}], non_trump: [{10, :clubs}]}

      # With wrong 5: 5 of diamonds is trump when hearts is trump
      iex> hand = [{14, :hearts}, {5, :diamonds}, {10, :clubs}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [{14, :hearts}, {5, :diamonds}], non_trump: [{10, :clubs}]}

      # With right 5: 5 of hearts is trump when hearts is trump
      iex> hand = [{5, :hearts}, {5, :diamonds}, {10, :clubs}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [{5, :hearts}, {5, :diamonds}], non_trump: [{10, :clubs}]}

      # All trumps
      iex> hand = [{14, :hearts}, {10, :hearts}, {7, :hearts}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [{14, :hearts}, {10, :hearts}, {7, :hearts}], non_trump: []}

      # No trumps (all camouflage)
      iex> hand = [{14, :clubs}, {10, :spades}, {7, :diamonds}]
      iex> Trump.categorize_hand(hand, :hearts)
      %{trump: [], non_trump: [{14, :clubs}, {10, :spades}, {7, :diamonds}]}
  """
  @spec categorize_hand([card()], suit()) :: %{trump: [card()], non_trump: [card()]}
  def categorize_hand(hand, trump_suit)
      when is_list(hand) and trump_suit in [:hearts, :diamonds, :clubs, :spades] do
    {trump, non_trump} =
      Enum.split_with(hand, fn card ->
        Card.is_trump?(card, trump_suit)
      end)

    %{trump: trump, non_trump: non_trump}
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  @doc """
  Counts the number of trump cards in a hand.

  This is a convenience function that categorizes the hand and returns
  the count of trump cards.

  ## Parameters
  - `hand` - List of cards to count
  - `trump_suit` - The declared trump suit

  ## Returns
  The number of trump cards in the hand (including wrong 5)

  ## Examples

      iex> hand = [{14, :hearts}, {5, :diamonds}, {10, :clubs}]
      iex> Trump.count_trump_cards(hand, :hearts)
      2

      iex> hand = [{14, :clubs}, {10, :spades}]
      iex> Trump.count_trump_cards(hand, :hearts)
      0
  """
  @spec count_trump_cards([card()], suit()) :: non_neg_integer()
  def count_trump_cards(hand, trump_suit) do
    %{trump: trump} = categorize_hand(hand, trump_suit)
    length(trump)
  end

  @doc """
  Checks if a hand contains any trump cards.

  ## Parameters
  - `hand` - List of cards to check
  - `trump_suit` - The declared trump suit

  ## Returns
  - `true` if the hand contains at least one trump card
  - `false` if the hand contains no trump cards

  ## Examples

      iex> hand = [{14, :hearts}, {10, :clubs}]
      iex> Trump.has_trump?(hand, :hearts)
      true

      iex> hand = [{14, :clubs}, {10, :spades}]
      iex> Trump.has_trump?(hand, :hearts)
      false
  """
  @spec has_trump?([card()], suit()) :: boolean()
  def has_trump?(hand, trump_suit) do
    Enum.any?(hand, fn card -> Card.is_trump?(card, trump_suit) end)
  end

  @doc """
  Filters a hand to return only trump cards.

  ## Parameters
  - `hand` - List of cards to filter
  - `trump_suit` - The declared trump suit

  ## Returns
  List containing only the trump cards from the hand

  ## Examples

      iex> hand = [{14, :hearts}, {5, :diamonds}, {10, :clubs}]
      iex> Trump.get_trump_cards(hand, :hearts)
      [{14, :hearts}, {5, :diamonds}]

      iex> hand = [{14, :clubs}, {10, :spades}]
      iex> Trump.get_trump_cards(hand, :hearts)
      []
  """
  @spec get_trump_cards([card()], suit()) :: [card()]
  def get_trump_cards(hand, trump_suit) do
    %{trump: trump} = categorize_hand(hand, trump_suit)
    trump
  end

  @doc """
  Filters a hand to return only non-trump cards.

  ## Parameters
  - `hand` - List of cards to filter
  - `trump_suit` - The declared trump suit

  ## Returns
  List containing only the non-trump cards from the hand

  ## Examples

      iex> hand = [{14, :hearts}, {5, :diamonds}, {10, :clubs}]
      iex> Trump.get_non_trump_cards(hand, :hearts)
      [{10, :clubs}]

      iex> hand = [{14, :hearts}, {7, :hearts}]
      iex> Trump.get_non_trump_cards(hand, :hearts)
      []
  """
  @spec get_non_trump_cards([card()], suit()) :: [card()]
  def get_non_trump_cards(hand, trump_suit) do
    %{non_trump: non_trump} = categorize_hand(hand, trump_suit)
    non_trump
  end

  @doc """
  Check if a player can kill down to 6 cards.

  The "kill" rule allows a player to discard non-point trump cards to reduce
  their hand down to 6 cards. This function validates whether a player has
  enough non-point trump cards available to kill down to 6.

  ## Parameters
  - `hand` - List of cards in the player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  - `true` if the player can kill down to 6 cards
  - `false` if the player cannot (not enough non-point trump cards)

  ## Logic
  A player can kill if the number of excess cards (cards above 6) is less than
  or equal to the number of available non-point trump cards.

  ## Examples

      # Hand with 8 cards, 2 excess, and 3 non-point trumps
      iex> hand = [{14, :hearts}, {10, :hearts}, {7, :hearts}, {5, :hearts}, {4, :hearts}, {3, :hearts}, {14, :clubs}, {13, :clubs}]
      iex> Trump.can_kill_to_six?(hand, :hearts)
      true

      # Hand with 10 cards but only 1 non-point trump (4 excess cards)
      iex> hand = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {10, :hearts}, {14, :clubs}, {13, :clubs}, {12, :clubs}, {11, :clubs}, {10, :clubs}, {9, :clubs}]
      iex> Trump.can_kill_to_six?(hand, :hearts)
      false
  """
  @spec can_kill_to_six?([card()], suit()) :: boolean()
  def can_kill_to_six?(hand, trump_suit) do
    point_cards = Enum.count(hand, &Card.is_point_card?(&1, trump_suit))
    non_point_cards = length(hand) - point_cards

    # Can kill if: excess cards <= non_point_cards
    excess = length(hand) - 6
    excess <= non_point_cards
  end

  @doc """
  Validate that kill cards are all non-point trumps.

  When a player elects to kill (discard trumps to reduce hand to 6 cards),
  this function validates that the selected cards meet all requirements:
  - All selected cards are in the player's hand
  - All selected cards are trump cards
  - None of the selected cards are point cards (cannot kill point cards)

  ## Parameters
  - `kill_cards` - List of cards the player wants to kill
  - `hand` - List of cards in the player's hand
  - `trump_suit` - The declared trump suit

  ## Returns
  - `:ok` if all validations pass
  - `{:error, :cards_not_in_hand}` if any kill cards are not in the hand
  - `{:error, :can_only_kill_trump}` if any kill cards are not trump cards
  - `{:error, :cannot_kill_point_cards}` if any kill cards are point cards

  ## Examples

      iex> hand = [{14, :hearts}, {10, :hearts}, {7, :hearts}, {5, :hearts}]
      iex> Trump.validate_kill_cards([{7, :hearts}], hand, :hearts)
      :ok

      iex> hand = [{14, :hearts}, {10, :hearts}, {7, :hearts}]
      iex> Trump.validate_kill_cards([{14, :hearts}], hand, :hearts)
      {:error, :cannot_kill_point_cards}

      iex> hand = [{14, :hearts}, {10, :hearts}]
      iex> Trump.validate_kill_cards([{7, :hearts}], hand, :hearts)
      {:error, :cards_not_in_hand}
  """
  @spec validate_kill_cards([card()], [card()], suit()) :: :ok | {:error, atom()}
  def validate_kill_cards(kill_cards, hand, trump_suit) do
    cond do
      not Enum.all?(kill_cards, &(&1 in hand)) ->
        {:error, :cards_not_in_hand}

      not Enum.all?(kill_cards, &Card.is_trump?(&1, trump_suit)) ->
        {:error, :can_only_kill_trump}

      Enum.any?(kill_cards, &Card.is_point_card?(&1, trump_suit)) ->
        {:error, :cannot_kill_point_cards}

      true ->
        :ok
    end
  end
end
