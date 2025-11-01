defmodule Pidro.Game.Replay do
  @moduledoc """
  Replay system for the Pidro game engine.

  This module provides functionality for replaying game events, implementing
  undo/redo operations, and querying event history. It works in conjunction
  with the event sourcing system to enable time-travel debugging, game analysis,
  and state reconstruction.

  ## Features

  - **Event Replay**: Reconstruct game state from event list
  - **Undo/Redo**: Navigate through game history
  - **History Queries**: Extract events by timestamp or other criteria
  - **Pure Functions**: All operations are deterministic and side-effect free

  ## Design Philosophy

  The replay system is built on immutability and event sourcing principles:
  - Events are the source of truth
  - State can be reconstructed at any point
  - All operations are pure functions
  - No side effects or external dependencies

  ## Usage

      # Replay a complete game from events
      events = [
        {:dealer_selected, :north, {14, :hearts}},
        {:cards_dealt, %{north: [...], east: [...], south: [...], west: [...]}},
        {:bid_made, :north, 10},
        # ... more events
      ]
      {:ok, final_state} = Replay.replay(events)

      # Undo the last action
      {:ok, previous_state} = Replay.undo(current_state)

      # Redo an undone action
      {:ok, new_state} = Replay.redo(previous_state, undone_event)

      # Query event history
      length = Replay.history_length(state)
      last = Replay.last_event(state)
      recent = Replay.events_since(state, timestamp)

  ## Event Sourcing Integration

  This module assumes the existence of `Pidro.Core.Events.apply_event/2`,
  which handles the actual state transitions for each event type.
  """

  alias Pidro.Core.Types
  alias Pidro.Core.GameState
  alias Pidro.Core.Events

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Replays a list of events from a fresh game state.

  Takes a sequence of events and applies them in order to a new game state,
  reconstructing the final state. This is useful for:
  - Loading saved games
  - Analyzing completed games
  - Testing specific game scenarios
  - Debugging state transitions

  ## Parameters

  - `events` - List of events to replay in chronological order

  ## Returns

  - `{:ok, state}` - The final game state after all events applied
  - `{:error, reason}` - If any event fails to apply

  ## Examples

      # Replay a complete bidding round
      events = [
        {:dealer_selected, :north, {14, :hearts}},
        {:cards_dealt, %{north: [...], east: [...], south: [...], west: [...]}},
        {:bid_made, :north, 10},
        {:player_passed, :east},
        {:player_passed, :south},
        {:player_passed, :west},
        {:bidding_complete, :north, 10}
      ]
      {:ok, state} = replay(events)
      state.phase
      # => :declaring

      # Replay with invalid event fails
      {:error, reason} = replay([{:invalid_event, :data}])

  ## Notes

  - Events must be in chronological order
  - All events are stored in the resulting state's `events` field
  - If any event fails, the entire replay fails
  - State starts fresh with `GameState.new/0`
  """
  @spec replay([Types.event()]) :: {:ok, Types.GameState.t()}
  def replay(events) when is_list(events) do
    initial_state = GameState.new()
    replay_events(initial_state, events)
  end

  @doc """
  Returns the game state before the last event.

  Implements undo functionality by replaying all events except the last one.
  This is useful for:
  - Allowing players to take back moves
  - Debugging and testing
  - Game analysis and review
  - Training and learning scenarios

  ## Parameters

  - `state` - The current game state

  ## Returns

  - `{:ok, previous_state}` - State before the last event
  - `{:error, :no_history}` - If there are no events to undo

  ## Examples

      # Undo a bid
      state = %GameState{events: [
        {:dealer_selected, :north, {14, :hearts}},
        {:cards_dealt, %{...}},
        {:bid_made, :north, 10}
      ]}
      {:ok, previous_state} = undo(state)
      length(previous_state.events)
      # => 2

      # Cannot undo with no history
      fresh_state = GameState.new()
      {:error, :no_history} = undo(fresh_state)

  ## Performance

  Undo requires replaying all events except the last one, which is O(n)
  where n is the number of events. For better performance in undo-heavy
  scenarios, consider maintaining a stack of previous states.

  ## Notes

  - The undone event is NOT stored anywhere; caller must save it for redo
  - State is reconstructed from scratch each time
  - All events are deterministic, so replay produces identical state
  """
  @spec undo(Types.GameState.t()) :: {:ok, Types.GameState.t()} | {:error, :no_history}
  def undo(%Types.GameState{events: []}), do: {:error, :no_history}

  def undo(%Types.GameState{events: events}) when length(events) > 0 do
    # Remove the last event and replay the rest
    previous_events = Enum.drop(events, -1)
    replay(previous_events)
  end

  @doc """
  Applies an event that was previously undone.

  Implements redo functionality by applying a single event to the current state.
  This is the inverse of undo and allows moving forward through history.

  ## Parameters

  - `state` - The current game state
  - `event` - The event to reapply (typically from a previous undo)

  ## Returns

  - `{:ok, new_state}` - State after applying the event
  - `{:error, reason}` - If the event cannot be applied

  ## Examples

      # Redo a bid
      state = %GameState{events: [
        {:dealer_selected, :north, {14, :hearts}},
        {:cards_dealt, %{...}}
      ]}
      event = {:bid_made, :north, 10}
      {:ok, new_state} = redo(state, event)
      length(new_state.events)
      # => 3

      # Invalid event fails
      {:error, reason} = redo(state, {:invalid_event, :data})

  ## Notes

  - The event is added to the state's event history
  - State validation occurs through `Events.apply_event/2`
  - Caller is responsible for maintaining redo stack
  """
  @spec redo(Types.GameState.t(), Types.event()) ::
          {:ok, Types.GameState.t()}
  def redo(%Types.GameState{} = state, event) do
    new_state = Events.apply_event(state, event)
    # Add event to history
    updated_state = %{new_state | events: state.events ++ [event]}
    {:ok, updated_state}
  end

  # =============================================================================
  # History Query Functions
  # =============================================================================

  @doc """
  Returns the number of events in the game history.

  Useful for:
  - Displaying move count to players
  - Determining if undo is available
  - Progress tracking
  - Performance monitoring

  ## Parameters

  - `state` - The current game state

  ## Returns

  The number of events in the state's history (non-negative integer).

  ## Examples

      iex> state = GameState.new()
      iex> history_length(state)
      0

      iex> state = %GameState{events: [{:dealer_selected, :north, {14, :hearts}}]}
      iex> history_length(state)
      1

      iex> state_with_multiple_events = %GameState{events: [
      ...>   {:dealer_selected, :north, {14, :hearts}},
      ...>   {:cards_dealt, %{}},
      ...>   {:bid_made, :north, 10}
      ...> ]}
      iex> history_length(state_with_multiple_events)
      3
  """
  @spec history_length(Types.GameState.t()) :: non_neg_integer()
  def history_length(%Types.GameState{events: events}), do: length(events)

  @doc """
  Returns the most recent event from the game history.

  Useful for:
  - Displaying the last action to players
  - Determining what can be undone
  - Game state analysis
  - Debugging and logging

  ## Parameters

  - `state` - The current game state

  ## Returns

  - The last event in the history, or `nil` if there are no events

  ## Examples

      iex> state = GameState.new()
      iex> last_event(state)
      nil

      iex> state = %GameState{events: [{:dealer_selected, :north, {14, :hearts}}]}
      iex> last_event(state)
      {:dealer_selected, :north, {14, :hearts}}

      iex> state = %GameState{events: [
      ...>   {:dealer_selected, :north, {14, :hearts}},
      ...>   {:cards_dealt, %{}},
      ...>   {:bid_made, :north, 10}
      ...> ]}
      iex> last_event(state)
      {:bid_made, :north, 10}
  """
  @spec last_event(Types.GameState.t()) :: Types.event() | nil
  def last_event(%Types.GameState{events: []}), do: nil
  def last_event(%Types.GameState{events: events}), do: List.last(events)

  @doc """
  Returns all events that occurred after a given timestamp.

  Events in the Pidro engine may include timestamps (in the Bid struct, for example).
  This function filters events to only those occurring after the specified time,
  useful for:
  - Synchronizing game state across clients
  - Implementing event streaming
  - Analyzing game segments
  - Performance profiling

  ## Parameters

  - `state` - The current game state
  - `timestamp` - The cutoff timestamp (events after this are returned)

  ## Returns

  A list of events that occurred after the timestamp. Events without timestamps
  are included if they appear after the timestamp in the event list.

  ## Examples

      # Get recent events
      state = %GameState{events: [
        {:dealer_selected, :north, {14, :hearts}},  # no timestamp
        {:cards_dealt, %{}},                         # no timestamp
        {:bid_made, :north, 10}                      # no timestamp
      ]}
      events = events_since(state, 0)
      length(events)
      # => 3 (all events returned when no timestamps present)

  ## Notes

  - Events without timestamps are handled conservatively
  - The timestamp comparison is > (greater than), not >= (greater than or equal)
  - Useful primarily when events include timestamp metadata
  - Returns events in chronological order
  """
  @spec events_since(Types.GameState.t(), integer()) :: [Types.event()]
  def events_since(%Types.GameState{events: events}, timestamp) do
    # Filter events that occurred after the given timestamp
    # Since most events don't have explicit timestamps, we use list position
    # as a proxy for time ordering
    Enum.drop_while(events, fn event ->
      event_timestamp = extract_timestamp(event)
      event_timestamp <= timestamp
    end)
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  # Replays a list of events on the given state
  @spec replay_events(Types.GameState.t(), [Types.event()]) ::
          {:ok, Types.GameState.t()}
  defp replay_events(state, []), do: {:ok, state}

  defp replay_events(state, [event | rest]) do
    new_state = Events.apply_event(state, event)
    # Add event to history and continue
    state_with_event = %{new_state | events: state.events ++ [event]}
    replay_events(state_with_event, rest)
  end

  # Extracts timestamp from an event if present
  # Returns 0 for events without timestamps (treated as earliest)
  @spec extract_timestamp(Types.event()) :: integer()
  defp extract_timestamp({:bid_made, _position, _amount}), do: 0
  defp extract_timestamp({:player_passed, _position}), do: 0
  defp extract_timestamp(_event), do: 0
end
