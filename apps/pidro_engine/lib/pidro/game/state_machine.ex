defmodule Pidro.Game.StateMachine do
  @moduledoc """
  State machine for managing game phase transitions in Pidro.

  This module defines the valid phase transitions and provides functions for
  validating and determining the next phase based on the current game state.

  ## Phase Flow

  The game progresses through these phases in order:

  1. `:dealer_selection` -> `:dealing`
  2. `:dealing` -> `:bidding`
  3. `:bidding` -> `:declaring`
  4. `:declaring` -> `:discarding`
  5. `:discarding` -> `:second_deal`
  6. `:second_deal` -> `:playing`
  7. `:playing` -> `:scoring`
  8. `:scoring` -> `:hand_complete` (no winner yet) or `:complete` (game over)
  9. `:hand_complete` -> `:dealer_selection` (start new hand)

  ## Usage

      iex> StateMachine.valid_transition?(:dealing, :bidding)
      true

      iex> StateMachine.valid_transition?(:dealing, :playing)
      false

      iex> state = %GameState{phase: :scoring, cumulative_scores: %{north_south: 50, east_west: 45}}
      iex> StateMachine.next_phase(:scoring, state)
      :hand_complete

      iex> state = %GameState{phase: :scoring, cumulative_scores: %{north_south: 62, east_west: 45}}
      iex> StateMachine.next_phase(:scoring, state)
      :complete
  """

  alias Pidro.Core.Types.GameState

  # =============================================================================
  # Phase Transition Validation
  # =============================================================================

  @doc """
  Validates whether a transition from one phase to another is allowed.

  ## Parameters

  - `from_phase` - The current phase
  - `to_phase` - The desired next phase

  ## Returns

  `true` if the transition is valid, `false` otherwise.

  ## Examples

      iex> valid_transition?(:dealer_selection, :dealing)
      true

      iex> valid_transition?(:bidding, :declaring)
      true

      iex> valid_transition?(:bidding, :playing)
      false

      iex> valid_transition?(:scoring, :hand_complete)
      true

      iex> valid_transition?(:scoring, :complete)
      true

      iex> valid_transition?(:hand_complete, :dealer_selection)
      true
  """
  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(from_phase, to_phase)

  # Dealer selection -> Dealing
  def valid_transition?(:dealer_selection, :dealing), do: true

  # Dealing -> Bidding
  def valid_transition?(:dealing, :bidding), do: true

  # Bidding -> Declaring
  def valid_transition?(:bidding, :declaring), do: true

  # Declaring -> Discarding
  def valid_transition?(:declaring, :discarding), do: true

  # Discarding -> Second Deal
  def valid_transition?(:discarding, :second_deal), do: true

  # Second Deal -> Playing
  def valid_transition?(:second_deal, :playing), do: true

  # Playing -> Scoring
  def valid_transition?(:playing, :scoring), do: true

  # Scoring -> Hand Complete (no winner yet)
  def valid_transition?(:scoring, :hand_complete), do: true

  # Scoring -> Complete (game over)
  def valid_transition?(:scoring, :complete), do: true

  # Hand Complete -> Dealer Selection (new hand)
  def valid_transition?(:hand_complete, :dealer_selection), do: true

  # All other transitions are invalid
  def valid_transition?(_, _), do: false

  # =============================================================================
  # Next Phase Determination
  # =============================================================================

  @doc """
  Determines the next phase based on the current phase and game state.

  This function implements the game logic for automatic phase transitions,
  including conditional transitions based on game state (e.g., checking if
  there's a winner after scoring).

  ## Parameters

  - `current_phase` - The current game phase
  - `game_state` - The current game state (used for conditional transitions)

  ## Returns

  The next phase as an atom, or `{:error, reason}` if the transition cannot
  be determined.

  ## Examples

      iex> next_phase(:dealer_selection, %GameState{})
      :dealing

      iex> next_phase(:bidding, %GameState{})
      :declaring

      iex> state = %GameState{cumulative_scores: %{north_south: 50, east_west: 45}, config: %{winning_score: 62}}
      iex> next_phase(:scoring, state)
      :hand_complete

      iex> state = %GameState{cumulative_scores: %{north_south: 62, east_west: 45}, config: %{winning_score: 62}}
      iex> next_phase(:scoring, state)
      :complete
  """
  @spec next_phase(atom(), GameState.t()) :: atom() | {:error, String.t()}
  def next_phase(current_phase, game_state)

  # Standard linear transitions
  def next_phase(:dealer_selection, _state), do: :dealing
  def next_phase(:dealing, _state), do: :bidding
  def next_phase(:bidding, _state), do: :declaring
  def next_phase(:declaring, _state), do: :discarding
  def next_phase(:discarding, _state), do: :second_deal
  def next_phase(:second_deal, _state), do: :playing
  def next_phase(:playing, _state), do: :scoring

  # Conditional transition: scoring -> hand_complete or complete
  def next_phase(:scoring, %GameState{} = state) do
    if game_has_winner?(state) do
      :complete
    else
      :hand_complete
    end
  end

  # New hand: hand_complete -> dealer_selection
  def next_phase(:hand_complete, _state), do: :dealer_selection

  # Terminal state
  def next_phase(:complete, _state) do
    {:error, "Game is already complete"}
  end

  # Unknown phase
  def next_phase(unknown_phase, _state) do
    {:error, "Unknown phase: #{inspect(unknown_phase)}"}
  end

  # =============================================================================
  # Phase Transition Guards
  # =============================================================================

  @doc """
  Checks if the game is ready to transition from the dealer_selection phase.

  ## Requirements

  - A dealer must be selected (current_dealer is not nil)

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_dealer_selection?(GameState.t()) :: boolean()
  def can_transition_from_dealer_selection?(%GameState{current_dealer: dealer}) do
    dealer != nil
  end

  @doc """
  Checks if the game is ready to transition from the dealing phase.

  ## Requirements

  - All 4 players must have exactly 9 cards in their hands

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_dealing?(GameState.t()) :: boolean()
  def can_transition_from_dealing?(%GameState{players: players, config: config}) do
    initial_count = Map.get(config, :initial_deal_count, 9)

    Enum.all?(players, fn {_pos, player} ->
      length(player.hand) == initial_count
    end)
  end

  @doc """
  Checks if the game is ready to transition from the bidding phase.

  ## Requirements

  - Bidding must be complete (highest_bid is set)
  - At least one bid must have been made

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_bidding?(GameState.t()) :: boolean()
  def can_transition_from_bidding?(%GameState{highest_bid: highest_bid, bids: bids}) do
    highest_bid != nil and length(bids) > 0
  end

  @doc """
  Checks if the game is ready to transition from the declaring phase.

  ## Requirements

  - Trump suit must be declared (trump_suit is not nil)

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_declaring?(GameState.t()) :: boolean()
  def can_transition_from_declaring?(%GameState{trump_suit: trump_suit}) do
    trump_suit != nil
  end

  @doc """
  Checks if the game is ready to transition from the discarding phase.

  ## Requirements

  - All players must have discarded their non-trump cards
  - This is verified by checking that all players have discarded some cards
    (indicated by non-empty discarded_cards list or ready state)

  ## Returns

  `true` if ready to transition, `false` otherwise.

  ## Note

  The actual implementation will depend on how discarding is tracked in the
  game state. This is a placeholder that should be refined based on the
  actual discard tracking mechanism.
  """
  @spec can_transition_from_discarding?(GameState.t()) :: boolean()
  def can_transition_from_discarding?(%GameState{} = _state) do
    # TODO: Implement proper discard tracking verification
    # This should check that all players have completed their discards
    # For now, we return true as a placeholder
    true
  end

  @doc """
  Checks if the game is ready to transition from the second_deal phase.

  ## Requirements

  - All players must have exactly 6 cards (final hand size)
  - Dealer must have robbed the pack

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_second_deal?(GameState.t()) :: boolean()
  def can_transition_from_second_deal?(%GameState{players: players, config: config}) do
    final_hand_size = Map.get(config, :final_hand_size, 6)

    Enum.all?(players, fn {_pos, player} ->
      length(player.hand) == final_hand_size
    end)
  end

  @doc """
  Checks if the game is ready to transition from the playing phase.

  ## Requirements

  - All tricks must be complete
  - All players must have empty hands (or be eliminated)

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_playing?(GameState.t()) :: boolean()
  def can_transition_from_playing?(%GameState{players: players}) do
    # All players should have empty hands or be eliminated
    Enum.all?(players, fn {_pos, player} ->
      length(player.hand) == 0 or player.eliminated?
    end)
  end

  @doc """
  Checks if the game is ready to transition from the scoring phase.

  ## Requirements

  - Hand points must be calculated for both teams
  - Cumulative scores must be updated

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_scoring?(GameState.t()) :: boolean()
  def can_transition_from_scoring?(%GameState{hand_points: hand_points}) do
    # Verify that hand points have been calculated
    hand_points != %{north_south: 0, east_west: 0}
  end

  @doc """
  Checks if the game is ready to transition from the hand_complete phase.

  ## Requirements

  - Players should be reset for a new hand
  - Dealer should be rotated (or at least current_dealer should be set)

  ## Returns

  `true` if ready to transition, `false` otherwise.
  """
  @spec can_transition_from_hand_complete?(GameState.t()) :: boolean()
  def can_transition_from_hand_complete?(%GameState{} = _state) do
    # The hand_complete phase is primarily a marker state
    # We can always transition to dealer_selection for a new hand
    true
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Checks if any team has reached the winning score
  @spec game_has_winner?(GameState.t()) :: boolean()
  defp game_has_winner?(%GameState{cumulative_scores: scores, config: config}) do
    winning_score = Map.get(config, :winning_score, 62)

    scores.north_south >= winning_score or scores.east_west >= winning_score
  end
end
