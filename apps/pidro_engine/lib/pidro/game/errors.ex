defmodule Pidro.Game.Errors do
  @moduledoc """
  Error definitions and formatting utilities for the Pidro game engine.

  This module defines all possible error atoms that can occur during game play
  and provides helper functions to format these errors into user-friendly messages.

  ## Error Categories

  ### Phase Errors
  - `:invalid_phase` - Action attempted in wrong game phase

  ### Turn Management Errors
  - `:not_your_turn` - Action attempted by player when it's not their turn
  - `:invalid_action` - Action is not valid for current game state

  ### Bidding Errors
  - `:invalid_bid_amount` - Bid amount outside valid range (6-14)
  - `:bid_too_low` - Bid must be higher than current highest bid
  - `:already_bid` - Player has already made a bid this round
  - `:already_passed` - Player has already passed and cannot bid

  ### Card Play Errors
  - `:invalid_card` - Card format or value is invalid
  - `:card_not_in_hand` - Attempted to play a card not in player's hand
  - `:must_follow_suit` - Must play trump card when holding trumps
  - `:cannot_play_non_trump` - Non-trump cards cannot be played in Finnish variant
  - `:must_play_top_killed_card_first` - Player must play top killed card on first trick play

  ### Player State Errors
  - `:player_eliminated` - Player has gone "cold" (out of trumps)

  ### Game State Errors
  - `:game_already_complete` - Action attempted after game has ended
  - `:invalid_position` - Player position is not valid
  - `:invalid_team` - Team designation is not valid

  ## Usage

      iex> format_error(:not_your_turn)
      "It is not your turn to play"

      iex> format_error({:bid_too_low, 8})
      "Bid must be at least 8 points"

      iex> format_error({:card_not_in_hand, {14, :hearts}})
      "You do not have Ace of Hearts in your hand"
  """

  alias Pidro.Core.Types

  # =============================================================================
  # Error Type Definitions
  # =============================================================================

  @typedoc """
  All possible game errors that can occur.

  Simple errors are represented as atoms, while complex errors that need
  additional context are represented as tuples with the error atom and
  relevant data.
  """
  # Phase errors
  @type error ::
          :invalid_phase
          | {:invalid_phase, expected :: Types.phase(), actual :: Types.phase()}

          # Turn management errors
          | :not_your_turn
          | {:not_your_turn, current_turn :: Types.position()}
          | :invalid_action
          | {:invalid_action, action :: Types.action(), phase :: Types.phase()}

          # Bidding errors
          | :invalid_bid_amount
          | {:invalid_bid_amount, amount :: integer()}
          | :bid_too_low
          | {:bid_too_low, minimum :: Types.bid_amount()}
          | :already_bid
          | {:already_bid, position :: Types.position()}
          | :already_passed
          | {:already_passed, position :: Types.position()}

          # Trump errors
          | :invalid_suit
          | {:invalid_suit, suit :: any()}
          | :trump_already_declared
          | {:trump_already_declared, suit :: Types.suit()}
          | :trump_not_declared
          | {:trump_not_declared, message :: String.t()}

          # Card play errors
          | :invalid_card
          | {:invalid_card, card :: any()}
          | :card_not_in_hand
          | {:card_not_in_hand, card :: Types.card()}
          | :must_follow_suit
          | {:must_follow_suit, trump_suit :: Types.suit()}
          | :cannot_play_non_trump
          | {:cannot_play_non_trump, card :: Types.card(), trump_suit :: Types.suit()}
          | :must_play_top_killed_card_first
          | {:must_play_top_killed_card_first, card :: Types.card()}

          # Discard errors
          | :cannot_discard_trump
          | {:cannot_discard_trump, card :: Types.card()}
          | :no_dealer
          | {:no_dealer, message :: String.t()}
          | :not_dealer_turn
          | {:not_dealer_turn, dealer :: Types.position(), current_turn :: Types.position()}
          | :invalid_card_count
          | {:invalid_card_count, expected :: non_neg_integer(), actual :: non_neg_integer()}

          # Player state errors
          | :player_eliminated
          | {:player_eliminated, position :: Types.position()}

          # Game state errors
          | :game_already_complete
          | {:game_already_complete, winner :: Types.team()}
          | :invalid_position
          | {:invalid_position, position :: any()}
          | :invalid_team
          | {:invalid_team, team :: any()}

  @typedoc """
  Result type for operations that can fail with game errors.
  """
  @type result(success) :: {:ok, success} | {:error, error()}

  # =============================================================================
  # Error Formatting
  # =============================================================================

  @doc """
  Formats an error into a human-readable message.

  ## Parameters

  - `error` - The error atom or tuple to format

  ## Returns

  A string containing the formatted error message.

  ## Examples

      iex> format_error(:invalid_phase)
      "Action cannot be performed in the current game phase"

      iex> format_error({:invalid_phase, :bidding, :playing})
      "Expected game phase to be bidding, but it is playing"

      iex> format_error(:not_your_turn)
      "It is not your turn to play"

      iex> format_error({:bid_too_low, 10})
      "Bid must be at least 10 points"
  """
  @spec format_error(error()) :: String.t()

  # Phase errors
  def format_error(:invalid_phase) do
    "Action cannot be performed in the current game phase"
  end

  def format_error({:invalid_phase, expected, actual}) do
    "Expected game phase to be #{expected}, but it is #{actual}"
  end

  # Turn management errors
  def format_error(:not_your_turn) do
    "It is not your turn to play"
  end

  def format_error({:not_your_turn, current_turn}) do
    "It is not your turn to play. Current turn: #{Types.position_to_string(current_turn)}"
  end

  def format_error(:invalid_action) do
    "This action is not valid in the current game state"
  end

  def format_error({:invalid_action, action, phase}) do
    "Action #{inspect(action)} is not valid during #{phase} phase"
  end

  # Bidding errors
  def format_error(:invalid_bid_amount) do
    "Bid amount must be between 6 and 14 points"
  end

  def format_error({:invalid_bid_amount, amount}) do
    "Invalid bid amount: #{amount}. Bid must be between 6 and 14 points"
  end

  def format_error(:bid_too_low) do
    "Bid must be higher than the current highest bid"
  end

  def format_error({:bid_too_low, minimum}) do
    "Bid must be at least #{minimum} points"
  end

  def format_error(:already_bid) do
    "You have already made a bid in this round"
  end

  def format_error({:already_bid, position}) do
    "#{Types.position_to_string(position)} has already made a bid in this round"
  end

  def format_error(:already_passed) do
    "You have already passed and cannot bid anymore"
  end

  def format_error({:already_passed, position}) do
    "#{Types.position_to_string(position)} has already passed and cannot bid"
  end

  # Trump errors
  def format_error(:invalid_suit) do
    "Invalid suit. Must be hearts, diamonds, clubs, or spades"
  end

  def format_error({:invalid_suit, suit}) do
    "Invalid suit: #{inspect(suit)}. Must be hearts, diamonds, clubs, or spades"
  end

  def format_error(:trump_already_declared) do
    "Trump suit has already been declared for this hand"
  end

  def format_error({:trump_already_declared, suit}) do
    "Trump suit has already been declared as #{Types.suit_to_name(suit)}"
  end

  def format_error(:trump_not_declared) do
    "Trump suit has not been declared yet"
  end

  def format_error({:trump_not_declared, message}) do
    message
  end

  # Card play errors
  def format_error(:invalid_card) do
    "The card format or value is invalid"
  end

  def format_error({:invalid_card, card}) do
    "Invalid card: #{inspect(card)}"
  end

  def format_error(:card_not_in_hand) do
    "You do not have that card in your hand"
  end

  def format_error({:card_not_in_hand, card}) do
    "You do not have #{Types.card_to_string(card)} in your hand"
  end

  def format_error(:must_follow_suit) do
    "You must play a trump card when you have one"
  end

  def format_error({:must_follow_suit, trump_suit}) do
    "You must play a #{Types.suit_to_name(trump_suit)} (trump) card when you have one"
  end

  def format_error(:cannot_play_non_trump) do
    "Non-trump cards cannot be played in the Finnish variant"
  end

  def format_error({:cannot_play_non_trump, card, trump_suit}) do
    "Cannot play #{Types.card_to_string(card)}. Only #{Types.suit_to_name(trump_suit)} (trump) cards can be played"
  end

  def format_error(:must_play_top_killed_card_first) do
    "You must play your top killed card first on your first trick play"
  end

  def format_error({:must_play_top_killed_card_first, card}) do
    "You must play your top killed card first. Top card: #{Types.card_to_string(card)}"
  end

  # Discard errors
  def format_error(:cannot_discard_trump) do
    "Cannot discard trump cards"
  end

  def format_error({:cannot_discard_trump, card}) do
    "Cannot discard #{Types.card_to_string(card)} because it is a trump card"
  end

  def format_error(:no_dealer) do
    "No dealer has been selected"
  end

  def format_error({:no_dealer, message}) do
    message
  end

  def format_error(:not_dealer_turn) do
    "It is not the dealer's turn"
  end

  def format_error({:not_dealer_turn, dealer, current_turn}) do
    "Expected dealer #{Types.position_to_string(dealer)} to act, but current turn is #{Types.position_to_string(current_turn)}"
  end

  def format_error(:invalid_card_count) do
    "Invalid number of cards"
  end

  def format_error({:invalid_card_count, expected, actual}) do
    "Expected #{expected} cards, but got #{actual}"
  end

  # Player state errors
  def format_error(:player_eliminated) do
    "Player has been eliminated (went cold)"
  end

  def format_error({:player_eliminated, position}) do
    "#{Types.position_to_string(position)} has been eliminated (went cold) and cannot play"
  end

  # Game state errors
  def format_error(:game_already_complete) do
    "The game has already ended"
  end

  def format_error({:game_already_complete, winner}) do
    "The game has already ended. Winner: #{Types.team_to_string(winner)}"
  end

  def format_error(:invalid_position) do
    "Invalid player position"
  end

  def format_error({:invalid_position, position}) do
    "Invalid player position: #{inspect(position)}. Must be one of: north, east, south, west"
  end

  def format_error(:invalid_team) do
    "Invalid team"
  end

  def format_error({:invalid_team, team}) do
    "Invalid team: #{inspect(team)}. Must be :north_south or :east_west"
  end

  # Fallback for unknown errors
  def format_error(error) do
    "Unknown error: #{inspect(error)}"
  end

  # =============================================================================
  # Error Validation Utilities
  # =============================================================================

  @doc """
  Validates a position atom.

  ## Returns

  - `{:ok, position}` if valid
  - `{:error, {:invalid_position, value}}` if invalid

  ## Examples

      iex> validate_position(:north)
      {:ok, :north}

      iex> validate_position(:invalid)
      {:error, {:invalid_position, :invalid}}
  """
  @spec validate_position(any()) :: result(Types.position())
  def validate_position(position) when position in [:north, :east, :south, :west] do
    {:ok, position}
  end

  def validate_position(position) do
    {:error, {:invalid_position, position}}
  end

  @doc """
  Validates a team atom.

  ## Returns

  - `{:ok, team}` if valid
  - `{:error, {:invalid_team, value}}` if invalid

  ## Examples

      iex> validate_team(:north_south)
      {:ok, :north_south}

      iex> validate_team(:invalid)
      {:error, {:invalid_team, :invalid}}
  """
  @spec validate_team(any()) :: result(Types.team())
  def validate_team(team) when team in [:north_south, :east_west] do
    {:ok, team}
  end

  def validate_team(team) do
    {:error, {:invalid_team, team}}
  end

  @doc """
  Validates a bid amount.

  ## Returns

  - `{:ok, amount}` if valid (6-14)
  - `{:error, {:invalid_bid_amount, value}}` if invalid

  ## Examples

      iex> validate_bid_amount(10)
      {:ok, 10}

      iex> validate_bid_amount(5)
      {:error, {:invalid_bid_amount, 5}}

      iex> validate_bid_amount(15)
      {:error, {:invalid_bid_amount, 15}}
  """
  @spec validate_bid_amount(any()) :: result(Types.bid_amount())
  def validate_bid_amount(amount) when is_integer(amount) and amount >= 6 and amount <= 14 do
    {:ok, amount}
  end

  def validate_bid_amount(amount) do
    {:error, {:invalid_bid_amount, amount}}
  end

  @doc """
  Validates a card tuple.

  ## Returns

  - `{:ok, card}` if valid
  - `{:error, {:invalid_card, value}}` if invalid

  ## Examples

      iex> validate_card({14, :hearts})
      {:ok, {14, :hearts}}

      iex> validate_card({1, :hearts})
      {:error, {:invalid_card, {1, :hearts}}}

      iex> validate_card({14, :invalid})
      {:error, {:invalid_card, {14, :invalid}}}
  """
  @spec validate_card(any()) :: result(Types.card())
  def validate_card({rank, suit} = card)
      when is_integer(rank) and rank >= 2 and rank <= 14 and
             suit in [:hearts, :diamonds, :clubs, :spades] do
    {:ok, card}
  end

  def validate_card(card) do
    {:error, {:invalid_card, card}}
  end

  # =============================================================================
  # Error Construction Helpers
  # =============================================================================

  @doc """
  Creates a standardized error result tuple.

  This is a convenience function for creating `{:error, error}` tuples.

  ## Examples

      iex> error(:not_your_turn)
      {:error, :not_your_turn}

      iex> error({:bid_too_low, 10})
      {:error, {:bid_too_low, 10}}
  """
  @spec error(error()) :: {:error, error()}
  def error(error_value) do
    {:error, error_value}
  end

  @doc """
  Returns a list of all simple error atoms.

  Useful for testing and documentation purposes.
  """
  @spec all_error_atoms() :: [atom()]
  def all_error_atoms do
    [
      :invalid_phase,
      :not_your_turn,
      :invalid_action,
      :invalid_bid_amount,
      :bid_too_low,
      :already_bid,
      :already_passed,
      :invalid_suit,
      :trump_already_declared,
      :trump_not_declared,
      :invalid_card,
      :card_not_in_hand,
      :must_follow_suit,
      :cannot_play_non_trump,
      :must_play_top_killed_card_first,
      :cannot_discard_trump,
      :no_dealer,
      :not_dealer_turn,
      :invalid_card_count,
      :player_eliminated,
      :game_already_complete,
      :invalid_position,
      :invalid_team
    ]
  end
end
