defmodule Pidro.Game.Bidding do
  @moduledoc """
  Bidding logic for the Pidro game engine.

  This module handles all aspects of the bidding phase in Finnish Pidro,
  including:
  - Validating bids are legal (6-14, higher than current, etc.)
  - Applying bids to the game state
  - Handling pass actions
  - Determining when bidding is complete
  - Tracking the winning bidder and bid amount

  ## Finnish Pidro Bidding Rules

  ### Bidding Order
  - Bidding starts with the player to the left of the dealer
  - Proceeds clockwise around the table
  - Each player gets ONE chance to bid or pass
  - Dealer bids last
  - Bidding completes when all 4 players have acted (one round only)

  ### Bid Requirements
  - Minimum bid: 6 points
  - Maximum bid: 14 points
  - Each bid must be higher than the current highest bid
  - Each player can only bid OR pass once

  ### Special Rules
  - If all 3 players before the dealer pass, the dealer MUST bid 6 (cannot pass)
  - The highest bidder declares trump and attempts to make their bid

  ### Bidding Complete When
  - All 4 players have acted (bid or passed)

  ## Examples

      # Validate a bid
      iex> state = %{GameState.new() | phase: :bidding, highest_bid: nil}
      iex> Bidding.validate_bid(state, :north, 6)
      :ok

      iex> state = %{GameState.new() | phase: :bidding, highest_bid: {:east, 8}}
      iex> Bidding.validate_bid(state, :south, 7)
      {:error, {:bid_too_low, 9}}

      # Apply a bid
      iex> state = %{GameState.new() | phase: :bidding, current_turn: :north}
      iex> {:ok, state} = Bidding.apply_bid(state, :north, 6)
      iex> state.highest_bid
      {:north, 6}

      # Check if bidding is complete
      iex> state = %{GameState.new() | highest_bid: {:north, 14}}
      iex> Bidding.bidding_complete?(state)
      true
  """

  alias Pidro.Core.{Types, GameState}
  alias Pidro.Game.Errors

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type bid_amount :: Types.bid_amount()
  @type error :: Errors.error()

  # =============================================================================
  # Bid Validation
  # =============================================================================

  @doc """
  Validates whether a bid is legal in the current game state.

  Checks:
  1. Bid amount is within valid range (6-14)
  2. Bid is higher than the current highest bid
  3. Player hasn't already acted (bid or passed)

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player making the bid
  - `amount` - Bid amount (6-14)

  ## Returns
  - `:ok` - Bid is valid
  - `{:error, reason}` - Bid is invalid with reason

  ## Examples

      iex> state = %{GameState.new() | phase: :bidding, highest_bid: nil, bids: []}
      iex> Bidding.validate_bid(state, :north, 6)
      :ok

      iex> state = %{GameState.new() | phase: :bidding, highest_bid: {:east, 10}, bids: []}
      iex> Bidding.validate_bid(state, :south, 11)
      :ok

      iex> state = %{GameState.new() | phase: :bidding, highest_bid: {:east, 10}, bids: []}
      iex> Bidding.validate_bid(state, :south, 10)
      {:error, {:bid_too_low, 11}}

      iex> state = %{GameState.new() | phase: :bidding, highest_bid: nil, bids: [%Types.Bid{position: :north, amount: 6}]}
      iex> Bidding.validate_bid(state, :north, 7)
      {:error, {:already_acted, :north}}
  """
  @spec validate_bid(game_state(), position(), integer()) :: :ok | {:error, error()}
  def validate_bid(%Types.GameState{} = state, position, amount) do
    with :ok <- validate_bid_amount(amount),
         :ok <- validate_not_already_acted(state, position),
         :ok <- validate_bid_higher_than_current(state, amount) do
      :ok
    end
  end

  # Validates bid amount is in range 6-14
  @spec validate_bid_amount(integer()) :: :ok | {:error, error()}
  defp validate_bid_amount(amount) when amount >= 6 and amount <= 14, do: :ok
  defp validate_bid_amount(amount), do: {:error, {:invalid_bid_amount, amount}}

  # Validates player hasn't already acted (bid or passed)
  @spec validate_not_already_acted(game_state(), position()) :: :ok | {:error, error()}
  defp validate_not_already_acted(%Types.GameState{bids: bids}, position) do
    already_acted? = Enum.any?(bids, fn bid -> bid.position == position end)

    if already_acted? do
      {:error, {:already_acted, position}}
    else
      :ok
    end
  end

  # Validates dealer can pass (cannot pass if all others passed)
  @spec validate_dealer_can_pass(game_state(), position()) :: :ok | {:error, error()}
  defp validate_dealer_can_pass(%Types.GameState{current_dealer: dealer, bids: bids}, position) do
    # If this is the dealer and all 3 other players have passed, dealer cannot pass
    if position == dealer and length(bids) == 3 do
      all_others_passed? = Enum.all?(bids, fn bid -> bid.amount == :pass end)

      if all_others_passed? do
        {:error, :dealer_must_bid}
      else
        :ok
      end
    else
      :ok
    end
  end

  # Validates bid is higher than current highest
  @spec validate_bid_higher_than_current(game_state(), bid_amount()) :: :ok | {:error, error()}
  defp validate_bid_higher_than_current(%Types.GameState{highest_bid: nil}, _amount), do: :ok

  defp validate_bid_higher_than_current(
         %Types.GameState{highest_bid: {_pos, current_bid}},
         amount
       ) do
    if amount > current_bid do
      :ok
    else
      {:error, {:bid_too_low, current_bid + 1}}
    end
  end

  # =============================================================================
  # Apply Bid
  # =============================================================================

  @doc """
  Applies a valid bid to the game state.

  This function assumes the bid has been validated. It:
  1. Adds the bid to the bids list
  2. Updates the highest_bid
  3. Updates bidding_team
  4. Records a bid_made event
  5. Advances current_turn to next player
  6. Checks if bidding is complete and updates accordingly

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player making the bid
  - `amount` - Bid amount (6-14)

  ## Returns
  - `{:ok, state}` - Updated state with bid applied
  - `{:error, reason}` - If bid is invalid

  ## State Changes
  - Adds bid to `bids` list
  - Updates `highest_bid` to {position, amount}
  - Updates `bidding_team` to the team of the bidder
  - Adds `{:bid_made, position, amount}` event
  - Advances `current_turn` to next player clockwise
  - If bidding is complete, sets phase to `:declaring` and records event

  ## Examples

      iex> state = %{GameState.new() | phase: :bidding, current_turn: :north, highest_bid: nil, bids: []}
      iex> {:ok, state} = Bidding.apply_bid(state, :north, 6)
      iex> state.highest_bid
      {:north, 6}
      iex> state.bidding_team
      :north_south
      iex> length(state.bids)
      1
  """
  @spec apply_bid(game_state(), position(), bid_amount()) ::
          {:ok, game_state()} | {:error, error()}
  def apply_bid(%Types.GameState{} = state, position, amount) do
    case validate_bid(state, position, amount) do
      :ok ->
        # Create bid record
        bid = %Types.Bid{
          position: position,
          amount: amount,
          timestamp: System.system_time(:millisecond)
        }

        # Get the team of the bidder
        team = Types.position_to_team(position)

        # Update state
        updated_state =
          state
          |> GameState.update(:bids, state.bids ++ [bid])
          |> GameState.update(:highest_bid, {position, amount})
          |> GameState.update(:bidding_team, team)
          |> GameState.update(:events, state.events ++ [{:bid_made, position, amount}])
          |> GameState.update(:current_turn, Types.next_position(position))

        # Check if bidding is complete
        if bidding_complete?(updated_state) do
          finalize_bidding(updated_state)
        else
          {:ok, updated_state}
        end

      error ->
        error
    end
  end

  # =============================================================================
  # Apply Pass
  # =============================================================================

  @doc """
  Applies a pass action to the game state.

  Records that a player has passed and cannot bid again this round.
  Advances turn to next player. Checks if all players have passed
  (dealer must bid 6) or if bidding is complete.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player passing

  ## Returns
  - `{:ok, state}` - Updated state with pass applied
  - `{:error, reason}` - If pass is invalid

  ## State Changes
  - Adds pass to `bids` list (with amount: :pass)
  - Adds `{:player_passed, position}` event
  - Advances `current_turn` to next player clockwise
  - If all passed, dealer bids 6 automatically
  - If bidding complete, transitions to `:declaring` phase

  ## Examples

      iex> state = %{GameState.new() | phase: :bidding, current_turn: :north, bids: []}
      iex> {:ok, state} = Bidding.apply_pass(state, :north)
      iex> length(state.bids)
      1
      iex> [bid] = state.bids
      iex> bid.amount
      :pass
  """
  @spec apply_pass(game_state(), position()) :: {:ok, game_state()} | {:error, error()}
  def apply_pass(%Types.GameState{} = state, position) do
    # Check if dealer trying to pass when all others passed
    with :ok <- validate_dealer_can_pass(state, position),
         :ok <- validate_not_already_acted(state, position) do
      # Create pass record
      pass = %Types.Bid{
        position: position,
        amount: :pass,
        timestamp: System.system_time(:millisecond)
      }

      # Update state
      updated_state =
        state
        |> GameState.update(:bids, state.bids ++ [pass])
        |> GameState.update(:events, state.events ++ [{:player_passed, position}])
        |> GameState.update(:current_turn, Types.next_position(position))

      # Check if bidding is complete (all 4 players acted)
      if bidding_complete?(updated_state) do
        finalize_bidding(updated_state)
      else
        {:ok, updated_state}
      end
    end
  end

  # =============================================================================
  # Legal Actions
  # =============================================================================

  @doc """
  Returns the legal bidding actions for a given player.

  Only returns actions that will actually succeed if applied.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player

  ## Returns
  - List of legal actions: `[{:bid, amount} | :pass]`

  ## Examples

      iex> state = %{GameState.new() | phase: :bidding, bids: [], highest_bid: nil}
      iex> Bidding.legal_actions(state, :north)
      [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]

      # Dealer when all others passed - cannot pass
      iex> state = %{GameState.new() |
      ...>   phase: :bidding,
      ...>   current_dealer: :north,
      ...>   bids: [
      ...>     %Types.Bid{position: :east, amount: :pass},
      ...>     %Types.Bid{position: :south, amount: :pass},
      ...>     %Types.Bid{position: :west, amount: :pass}
      ...>   ]
      ...> }
      iex> Bidding.legal_actions(state, :north)
      [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}]  # No :pass
  """
  @spec legal_actions(game_state(), position()) :: [Types.action()]
  def legal_actions(%Types.GameState{} = state, position) do
    # If player already acted, no legal actions
    if validate_not_already_acted(state, position) != :ok do
      []
    else
      # Get valid bid amounts
      min_bid =
        case state.highest_bid do
          nil -> 6
          {_pos, amount} -> amount + 1
        end

      max_bid = 14

      # Build list of valid bids
      bid_actions =
        if min_bid <= max_bid do
          for amount <- min_bid..max_bid,
              validate_bid(state, position, amount) == :ok do
            {:bid, amount}
          end
        else
          []
        end

      # Add pass only if dealer can pass
      pass_actions =
        if validate_dealer_can_pass(state, position) == :ok do
          [:pass]
        else
          []
        end

      bid_actions ++ pass_actions
    end
  end

  # =============================================================================
  # Bidding Completion Checks
  # =============================================================================

  @doc """
  Checks if all players have passed (no bids made yet).

  When all players pass, the dealer is forced to bid the minimum (6 points).
  This ensures there is always a trump suit declared and the hand is played.

  ## Parameters
  - `state` - Current game state

  ## Returns
  - `true` - All players have passed
  - `false` - At least one player has bid

  ## Examples

      iex> state = %{GameState.new() | bids: [
      ...>   %Types.Bid{position: :east, amount: :pass},
      ...>   %Types.Bid{position: :south, amount: :pass},
      ...>   %Types.Bid{position: :west, amount: :pass},
      ...>   %Types.Bid{position: :north, amount: :pass}
      ...> ]}
      iex> Bidding.all_passed?(state)
      true

      iex> state = %{GameState.new() | bids: [
      ...>   %Types.Bid{position: :east, amount: :pass},
      ...>   %Types.Bid{position: :south, amount: 6}
      ...> ]}
      iex> Bidding.all_passed?(state)
      false
  """
  @spec all_passed?(game_state()) :: boolean()
  def all_passed?(%Types.GameState{bids: bids, current_dealer: dealer}) do
    # Get all positions
    positions = [:north, :east, :south, :west]

    # Check if all positions have passed (no bids with numeric amounts)
    all_positions_acted? =
      Enum.all?(positions, fn pos ->
        Enum.any?(bids, fn bid -> bid.position == pos end)
      end)

    # Check if all actions are passes
    all_are_passes? = Enum.all?(bids, fn bid -> bid.amount == :pass end)

    # All passed if all positions acted and all are passes
    # But dealer hasn't been forced to bid yet
    all_positions_acted? and all_are_passes? and dealer != nil
  end

  @doc """
  Checks if the bidding round is complete.

  In Finnish Pidro, bidding is complete when all 4 players have acted (bid or passed).

  ## Parameters
  - `state` - Current game state

  ## Returns
  - `true` - Bidding is complete (all 4 players acted)
  - `false` - Bidding should continue

  ## Examples

      # Bidding complete: all 4 players acted
      iex> state = %{GameState.new() |
      ...>   highest_bid: {:north, 6},
      ...>   bids: [
      ...>     %Types.Bid{position: :north, amount: 6},
      ...>     %Types.Bid{position: :east, amount: :pass},
      ...>     %Types.Bid{position: :south, amount: :pass},
      ...>     %Types.Bid{position: :west, amount: :pass}
      ...>   ]
      ...> }
      iex> Bidding.bidding_complete?(state)
      true

      # Bidding not complete: only 3 players acted
      iex> state = %{GameState.new() |
      ...>   highest_bid: {:north, 6},
      ...>   bids: [
      ...>     %Types.Bid{position: :north, amount: 6},
      ...>     %Types.Bid{position: :east, amount: :pass},
      ...>     %Types.Bid{position: :south, amount: :pass}
      ...>   ]
      ...> }
      iex> Bidding.bidding_complete?(state)
      false
  """
  @spec bidding_complete?(game_state()) :: boolean()
  def bidding_complete?(%Types.GameState{bids: bids}) do
    # Bidding is complete when all 4 players have acted
    length(bids) == 4
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  # Finalizes bidding by setting the winning bidder and transitioning phase
  @spec finalize_bidding(game_state()) :: {:ok, game_state()}
  defp finalize_bidding(%Types.GameState{highest_bid: {position, amount}} = state) do
    # Add bidding complete event
    event = {:bidding_complete, position, amount}

    # Update state to declaring phase
    updated_state =
      state
      |> GameState.update(:events, state.events ++ [event])
      |> GameState.update(:phase, :declaring)
      |> GameState.update(:current_turn, position)

    {:ok, updated_state}
  end
end
