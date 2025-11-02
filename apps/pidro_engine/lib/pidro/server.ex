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

  ## Returns

  - `{:ok, new_state}` if successful
  - `{:error, reason}` if the action is invalid

  ## Examples

      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 10})
      {:ok, state} = Pidro.Server.apply_action(pid, :east, :pass)
  """
  @spec apply_action(GenServer.server(), Types.position(), Types.action()) ::
          {:ok, GameState.t()} | {:error, term()}
  def apply_action(server, position, action) do
    GenServer.call(server, {:apply_action, position, action})
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

  ## Returns

  The current game state.

  ## Examples

      state = Pidro.Server.get_state(pid)
      IO.inspect(state.phase)
  """
  @spec get_state(GenServer.server()) :: GameState.t()
  def get_state(server) do
    GenServer.call(server, :get_state)
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

    state = %{
      game_state: initial_state,
      game_id: game_id,
      telemetry_enabled?: telemetry_enabled?
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:apply_action, position, action}, _from, state) do
    %{game_state: game_state, telemetry_enabled?: telemetry?} = state

    if telemetry? do
      emit_telemetry(:start, %{position: position, action: action}, state)
    end

    start_time = System.monotonic_time()

    result =
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
          end

          new_state = %{state | game_state: new_game_state}
          {:reply, {:ok, new_game_state}, new_state}

        {:error, reason} = error ->
          if telemetry? do
            duration = System.monotonic_time() - start_time

            emit_telemetry(
              :exception,
              %{position: position, action: action, reason: reason, duration: duration},
              state
            )
          end

          {:reply, error, state}
      end

    result
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
    new_state = %{state | game_state: GS.new()}
    {:reply, :ok, new_state}
  end

  # Private Helpers

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
end
