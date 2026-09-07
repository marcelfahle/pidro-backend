defmodule Pidro.Server do
  @moduledoc """
  GenServer wrapper for the Pidro game engine.

  Provides a stateful interface to the pure functional game engine core,
  suitable for Phoenix/LiveView integration via process registry.

  ## Features

  - Wraps pure functional game engine in a GenServer
  - Maintains game state in process state
  - Provides synchronous API for game actions
  - Optional telemetry events for monitoring
  - Supports game history and replay

  ## Usage

      # Start a game server
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123")

      # Apply an action
      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 10})

      # Get legal actions
      actions = Pidro.Server.legal_actions(pid, :north)

      # Get current state
      state = Pidro.Server.get_state(pid)

      # Check if game is over
      game_over? = Pidro.Server.game_over?(pid)

  ## Registry Integration

  Games can be registered by ID for lookup:

      # Start with registry
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123", name: {:via, Registry, {Pidro.Registry, "game_123"}})

      # Look up by game ID
      [{pid, _}] = Registry.lookup(Pidro.Registry, "game_123")

  ## Telemetry Events

  The server emits the following telemetry events (when telemetry is enabled):

  - `[:pidro, :server, :action, :start]` - Before processing an action
  - `[:pidro, :server, :action, :stop]` - After successfully processing an action
  - `[:pidro, :server, :action, :exception]` - When action processing fails
  - `[:pidro, :server, :game, :complete]` - When a game finishes
  - `[:pidro, :server, :redeal, :complete]` - When second_deal phase completes
  - `[:pidro, :server, :kill_rule, :applied]` - When kill rule is applied (cards killed)
  - `[:pidro, :server, :dealer_rob, :complete]` - When dealer robs the pack

  ## State Structure

  The server maintains:
  - `game_state` - The current game state from the engine
  - `game_id` - Optional game identifier
  - `telemetry_enabled?` - Whether to emit telemetry events
  """

  use GenServer

  alias Pidro.Core.Types
  alias Pidro.Core.GameState, as: GS
  alias Pidro.Core.Types.GameState
  alias Pidro.Game.Engine

  # Override default child_spec to use :temporary restart strategy
  # This prevents games from being automatically restarted when they crash
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # Client API

  @doc """
  Starts a game server.

  ## Options

  - `:game_id` - Optional identifier for the game
  - `:name` - Optional registration name (supports {:via, module, term} tuples)
  - `:telemetry` - Whether to emit telemetry events (default: true)
  - `:initial_state` - Optional initial game state (default: new game)

  ## Examples

      # Start with auto-generated name
      {:ok, pid} = Pidro.Server.start_link()

      # Start with game ID
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123")

      # Start with registry
      {:ok, pid} = Pidro.Server.start_link(
        game_id: "game_123",
        name: {:via, Registry, {Pidro.Registry, "game_123"}}
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_server_opts)
  end

  @doc """
  Applies an action to the game.

  ## Parameters

  - `server` - The server pid or registered name
  - `position` - The position of the player making the action
  - `action` - The action to perform
  - `timeout` - Maximum wait in milliseconds (defaults to 5000)

  ## Returns

  - `{:ok, new_state}` if successful
  - `{:error, reason}` if the action is invalid

  ## Examples

      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 10})
      {:ok, state} = Pidro.Server.apply_action(pid, :east, :pass)
  """
  @spec apply_action(GenServer.server(), Types.position(), Types.action()) ::
          {:ok, GameState.t()} | {:error, term()}
  @spec apply_action(GenServer.server(), Types.position(), Types.action(), timeout()) ::
          {:ok, GameState.t()} | {:error, term()}
  def apply_action(server, position, action, timeout \\ 5_000) do
    GenServer.call(server, {:apply_action, position, action}, timeout)
  end

  @doc """
  Applies an action and returns the previous state plus the atomically committed
  server snapshot. This is used by real-time adapters that must publish phase
  timing from the same commit as the game state.
  """
  @spec apply_action_with_snapshot(
          GenServer.server(),
          Types.position(),
          Types.action(),
          timeout()
        ) :: {:ok, GameState.t(), map()} | {:error, term()}
  def apply_action_with_snapshot(server, position, action, timeout \\ 5_000) do
    GenServer.call(server, {:apply_action_with_snapshot, position, action}, timeout)
  end

  @doc """
  Gets the list of legal actions for a position.

  ## Parameters

  - `server` - The server pid or registered name
  - `position` - The position to get legal actions for

  ## Returns

  List of legal actions for the position.

  ## Examples

      actions = Pidro.Server.legal_actions(pid, :north)
      # => [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]
  """
  @spec legal_actions(GenServer.server(), Types.position()) :: [Types.action()]
  def legal_actions(server, position) do
    GenServer.call(server, {:legal_actions, position})
  end

  @doc """
  Gets the current game state.

  ## Parameters

  - `server` - The server pid or registered name
  - `timeout` - Maximum wait in milliseconds (defaults to 5000)

  ## Returns

  The current game state.

  ## Examples

      state = Pidro.Server.get_state(pid)
      IO.inspect(state.phase)
  """
  @spec get_state(GenServer.server()) :: GameState.t()
  @spec get_state(GenServer.server(), timeout()) :: GameState.t()
  def get_state(server, timeout \\ 5_000) do
    GenServer.call(server, :get_state, timeout)
  end

  @doc """
  Gets an atomic game-state snapshot with server-owned presentation timing.
  """
  @spec get_snapshot(GenServer.server(), timeout()) :: map()
  def get_snapshot(server, timeout \\ 5_000) do
    GenServer.call(server, :get_snapshot, timeout)
  end

  @doc """
  Checks if the game is over.

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  `true` if the game is complete, `false` otherwise.

  ## Examples

      if Pidro.Server.game_over?(pid) do
        IO.puts("Game finished!")
      end
  """
  @spec game_over?(GenServer.server()) :: boolean()
  def game_over?(server) do
    GenServer.call(server, :game_over?)
  end

  @doc """
  Gets the winner of the game (if complete).

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  - `{:ok, team}` if the game is complete
  - `{:error, :game_not_over}` if the game is still in progress

  ## Examples

      case Pidro.Server.winner(pid) do
        {:ok, team} -> IO.puts("Winner: \#{team}")
        {:error, :game_not_over} -> IO.puts("Game still in progress")
      end
  """
  @spec winner(GenServer.server()) :: {:ok, Types.team()} | {:error, :game_not_over}
  def winner(server) do
    GenServer.call(server, :winner)
  end

  @doc """
  Gets the game history (list of events).

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  List of game events in chronological order.

  ## Examples

      events = Pidro.Server.get_history(pid)
      Enum.each(events, &IO.inspect/1)
  """
  @spec get_history(GenServer.server()) :: [Types.event()]
  def get_history(server) do
    GenServer.call(server, :get_history)
  end

  @doc """
  Resets the game to a new state.

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  `:ok`

  ## Examples

      :ok = Pidro.Server.reset(pid)
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    game_id = Keyword.get(opts, :game_id)
    telemetry_enabled? = Keyword.get(opts, :telemetry, true)
    initial_state = Keyword.get(opts, :initial_state, GS.new())

    dealer_selection_delay_ms = Keyword.get(opts, :dealer_selection_delay_ms, 3_000)
    pubsub = Keyword.get(opts, :pubsub)

    state =
      %{
        game_state: initial_state,
        game_id: game_id,
        telemetry_enabled?: telemetry_enabled?,
        dealer_selection_delay_ms: dealer_selection_delay_ms,
        pubsub: pubsub,
        game_instance_id: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        state_revision: 0,
        dealer_selection_presentation: nil,
        dealer_selection_timer_ref: nil,
        dealer_selection_token: nil
      }
      |> maybe_schedule_dealer_selection_advance()

    {:ok, state}
  end

  @impl true
  def handle_call({:apply_action, position, action}, _from, state) do
    apply_game_action(position, action, :state, state)
  end

  def handle_call({:apply_action_with_snapshot, position, action}, _from, state) do
    apply_game_action(position, action, :snapshot, state)
  end

  @impl true
  def handle_call({:legal_actions, position}, _from, state) do
    actions = Engine.legal_actions(state.game_state, position)
    {:reply, actions, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.game_state, state}
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_call(:game_over?, _from, state) do
    result = Engine.game_over?(state.game_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:winner, _from, state) do
    result = Engine.winner(state.game_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    events = state.game_state.events
    {:reply, events, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_state = replace_game_state(state, GS.new())
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_state, new_game_state}, _from, state) do
    new_state = replace_game_state(state, new_game_state)
    {:reply, :ok, new_state}
  end

  defp apply_game_action(position, action, reply_kind, state) do
    %{game_state: game_state, telemetry_enabled?: telemetry?} = state

    if telemetry? do
      emit_telemetry(:start, %{position: position, action: action}, state)
    end

    start_time = System.monotonic_time()

    case Engine.apply_action(game_state, position, action) do
      {:ok, new_game_state} ->
        if telemetry? do
          duration = System.monotonic_time() - start_time

          emit_telemetry(
            :stop,
            %{position: position, action: action, duration: duration},
            state
          )

          # Check if game just completed
          if new_game_state.phase == :complete and game_state.phase != :complete do
            emit_telemetry(:game_complete, %{winner: new_game_state.winner}, state)
          end

          # Emit redeal-specific telemetry events
          emit_redeal_telemetry(game_state, new_game_state, state)
        end

        new_state =
          state
          |> Map.put(:game_state, new_game_state)
          |> Map.update!(:state_revision, &(&1 + 1))
          |> maybe_schedule_dealer_selection_advance()

        reply =
          case reply_kind do
            :state -> {:ok, new_game_state}
            :snapshot -> {:ok, game_state, snapshot(new_state)}
          end

        {:reply, reply, new_state}

      {:error, _reason} = error ->
        if telemetry? do
          duration = System.monotonic_time() - start_time

          emit_telemetry(
            :exception,
            %{position: position, action: action, reason: error, duration: duration},
            state
          )
        end

        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(
        {:advance_from_dealer_selection, token},
        %{dealer_selection_token: token} = state
      )
      when not is_nil(token) do
    %{game_state: game_state} = state

    case Engine.advance_from_dealer_selection(game_state) do
      {:ok, new_game_state} ->
        new_state =
          state
          |> Map.put(:game_state, new_game_state)
          |> Map.update!(:state_revision, &(&1 + 1))
          |> clear_dealer_selection_presentation()

        broadcast_state_change(new_state)
        {:noreply, new_state}

      {:error, _reason} ->
        # Already advanced (e.g., by a concurrent action) — ignore
        {:noreply, clear_dealer_selection_presentation(state)}
    end
  end

  def handle_info({:advance_from_dealer_selection, _stale_token}, state), do: {:noreply, state}

  # Private Helpers

  defp maybe_schedule_dealer_selection_advance(
         %{
           game_state: %{phase: :dealer_selection, dealer_selection_cuts: cuts},
           dealer_selection_delay_ms: delay_ms
         } = state
       )
       when not is_nil(cuts) do
    state = clear_dealer_selection_presentation(state)
    token = make_ref()
    started_at_ms = System.system_time(:millisecond)
    timer_ref = Process.send_after(self(), {:advance_from_dealer_selection, token}, delay_ms)

    %{
      state
      | dealer_selection_presentation: %{
          started_at_ms: started_at_ms,
          ends_at_ms: started_at_ms + delay_ms
        },
        dealer_selection_timer_ref: timer_ref,
        dealer_selection_token: token
    }
  end

  defp maybe_schedule_dealer_selection_advance(state), do: state

  defp broadcast_state_change(%{pubsub: nil}), do: :ok

  defp broadcast_state_change(%{pubsub: pubsub, game_id: game_id} = state) do
    apply(Phoenix.PubSub, :broadcast, [
      pubsub,
      "game:#{game_id}",
      {:state_update, game_id, Map.put(snapshot(state), :transition_delay_ms, 0)}
    ])
  end

  defp snapshot(state) do
    %{
      game_instance_id: state.game_instance_id,
      state_revision: state.state_revision,
      server_time_ms: System.system_time(:millisecond),
      state: state.game_state,
      presentation: %{dealer_selection: state.dealer_selection_presentation}
    }
  end

  defp replace_game_state(state, game_state) do
    state
    |> clear_dealer_selection_presentation()
    |> Map.put(:game_state, game_state)
    |> Map.update!(:state_revision, &(&1 + 1))
    |> maybe_schedule_dealer_selection_advance()
  end

  defp clear_dealer_selection_presentation(state) do
    if state.dealer_selection_timer_ref do
      Process.cancel_timer(state.dealer_selection_timer_ref)
    end

    %{
      state
      | dealer_selection_presentation: nil,
        dealer_selection_timer_ref: nil,
        dealer_selection_token: nil
    }
  end

  defp emit_telemetry(event_suffix, measurements, state) do
    metadata = %{
      game_id: state.game_id,
      phase: state.game_state.phase,
      hand_number: state.game_state.hand_number
    }

    # Only emit if telemetry is available
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [
        [:pidro, :server, :action, event_suffix],
        measurements,
        metadata
      ])
    end
  end

  defp emit_redeal_telemetry(old_state, new_state, server_state) do
    # Emit event when second_deal phase completes with cards_requested data
    if old_state.phase == :second_deal and new_state.phase == :playing and
         map_size(new_state.cards_requested) > 0 do
      metadata = %{
        game_id: server_state.game_id,
        phase: :second_deal,
        hand_number: new_state.hand_number,
        cards_requested: new_state.cards_requested,
        dealer_pool_size: new_state.dealer_pool_size
      }

      measurements = %{
        total_cards_dealt: Enum.sum(Map.values(new_state.cards_requested))
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :redeal, :complete],
          measurements,
          metadata
        ])
      end
    end

    # Emit event when cards are killed (entering playing phase with killed_cards)
    if old_state.phase != :playing and new_state.phase == :playing and
         map_size(new_state.killed_cards) > 0 do
      metadata = %{
        game_id: server_state.game_id,
        phase: :playing,
        hand_number: new_state.hand_number,
        killed_cards_count:
          Enum.map(new_state.killed_cards, fn {pos, cards} -> {pos, length(cards)} end)
          |> Map.new()
      }

      measurements = %{
        total_killed:
          Enum.sum(Enum.map(new_state.killed_cards, fn {_pos, cards} -> length(cards) end))
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :kill_rule, :applied],
          measurements,
          metadata
        ])
      end
    end

    # Emit event when dealer robs pack (dealer_pool_size set)
    if is_nil(old_state.dealer_pool_size) and not is_nil(new_state.dealer_pool_size) do
      metadata = %{
        game_id: server_state.game_id,
        phase: new_state.phase,
        hand_number: new_state.hand_number,
        dealer: new_state.current_dealer,
        pool_size: new_state.dealer_pool_size
      }

      measurements = %{
        dealer_pool_size: new_state.dealer_pool_size
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :dealer_rob, :complete],
          measurements,
          metadata
        ])
      end
    end
  end
end
