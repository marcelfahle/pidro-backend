if Mix.env() == :dev do
  defmodule PidroServer.Dev.BotPlayer do
    @moduledoc """
    GenServer representing a single bot player in a game.

    This module implements an automated player that subscribes to game updates,
    detects when it's the bot's turn, and automatically executes legal actions
    using a configurable strategy.

    ## Features

    - Subscribes to game PubSub updates on start
    - Detects when it's the bot's turn by checking current_player == position
    - Fetches legal actions using GameAdapter.get_legal_actions/2
    - Picks actions via configurable strategy module (default: RandomStrategy)
    - Applies actions using GameAdapter.apply_action/3 with configurable delay
    - Handles errors gracefully without crashing
    - Can be paused/resumed during gameplay
    - Supports graceful shutdown

    ## Usage

        # Start a bot player for the North position
        {:ok, pid} = BotPlayer.start_link(%{
          room_code: "A3F9",
          position: :north,
          strategy: PidroServer.Dev.Strategies.RandomStrategy,
          delay_ms: 1000,
          paused?: false
        })

        # Pause the bot (it will stop making moves)
        BotPlayer.pause(pid)

        # Resume the bot
        BotPlayer.resume(pid)

        # Stop the bot gracefully
        BotPlayer.stop(pid)

    ## State

    The bot maintains the following state:
    - `room_code` - The game room code to subscribe to
    - `position` - The player position (`:north`, `:south`, `:east`, `:west`)
    - `strategy` - The strategy module name (default: `RandomStrategy`)
    - `delay_ms` - Delay in milliseconds before making a move (default: 1000)
    - `paused?` - Boolean indicating if the bot is paused (default: false)

    ## Strategy Modules

    Strategy modules must implement a `pick_action/2` function:

        @spec pick_action(list(), map()) :: term()
        def pick_action(legal_actions, game_state)

    The function receives the list of legal actions and the current game state,
    and returns the selected action.

    ## Error Handling

    The bot handles errors gracefully:
    - If an action fails, the error is logged and the bot continues
    - If the game doesn't exist, the bot logs a warning
    - If there are no legal actions, the bot waits for the next state update
    """

    use GenServer
    require Logger
    alias PidroServer.Dev.Event
    alias PidroServer.Dev.Strategies.RandomStrategy
    alias PidroServer.Games.GameAdapter

    @default_strategy RandomStrategy
    @default_delay_ms 1000

    ## Public API

    @doc """
    Starts a BotPlayer GenServer.

    ## Options

      - `:room_code` (required) - The game room code to join
      - `:position` (required) - The player position (`:north`, `:south`, `:east`, `:west`)
      - `:strategy` (optional) - The strategy module (default: `RandomStrategy`)
      - `:delay_ms` (optional) - Delay before making moves in milliseconds (default: 1000)
      - `:paused?` (optional) - Start in paused state (default: false)

    ## Examples

        {:ok, pid} = BotPlayer.start_link(%{
          room_code: "A3F9",
          position: :north
        })

        {:ok, pid} = BotPlayer.start_link(%{
          room_code: "B4K7",
          position: :south,
          strategy: MyCustomStrategy,
          delay_ms: 2000
        })

    ## Returns

      - `{:ok, pid}` on success
      - `{:error, reason}` on failure
    """
    @spec start_link(map()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @doc """
    Pauses the bot, preventing it from making moves.

    The bot will continue to receive state updates but will not execute actions
    until resumed.

    ## Parameters

      - `pid` - The bot process PID

    ## Examples

        BotPlayer.pause(bot_pid)

    ## Returns

      - `:ok`
    """
    @spec pause(pid()) :: :ok
    def pause(pid) do
      GenServer.cast(pid, :pause)
    end

    @doc """
    Resumes the bot, allowing it to make moves again.

    If it's currently the bot's turn, it will evaluate and execute an action
    immediately (after the configured delay).

    ## Parameters

      - `pid` - The bot process PID

    ## Examples

        BotPlayer.resume(bot_pid)

    ## Returns

      - `:ok`
    """
    @spec resume(pid()) :: :ok
    def resume(pid) do
      GenServer.cast(pid, :resume)
    end

    @doc """
    Stops the bot gracefully.

    The bot will unsubscribe from PubSub and terminate.

    ## Parameters

      - `pid` - The bot process PID

    ## Examples

        BotPlayer.stop(bot_pid)

    ## Returns

      - `:ok`
    """
    @spec stop(pid()) :: :ok
    def stop(pid) do
      GenServer.cast(pid, :stop)
    end

    ## GenServer Callbacks

    @impl true
    def init(opts) do
      # Convert keyword list to map if needed (for child spec compatibility)
      opts = if is_list(opts), do: Map.new(opts), else: opts

      room_code = Map.fetch!(opts, :room_code)
      position = Map.fetch!(opts, :position)
      strategy = Map.get(opts, :strategy, @default_strategy)
      delay_ms = Map.get(opts, :delay_ms, @default_delay_ms)
      paused? = Map.get(opts, :paused?, false)

      # Create a bot user ID based on room and position
      bot_user_id = "bot_#{room_code}_#{position}"

      # Join the room as a player
      case PidroServer.Games.RoomManager.join_room(room_code, bot_user_id) do
        {:ok, _room} ->
          Logger.info("Bot #{bot_user_id} joined room #{room_code}")

        {:error, reason} ->
          Logger.warning(
            "Bot #{bot_user_id} could not join room #{room_code}: #{inspect(reason)}"
          )
      end

      # Subscribe to game updates
      :ok = GameAdapter.subscribe(room_code)

      Logger.info(
        "BotPlayer started for room #{room_code}, position #{position}, strategy #{inspect(strategy)}"
      )

      state = %{
        room_code: room_code,
        position: position,
        user_id: bot_user_id,
        strategy: strategy,
        delay_ms: delay_ms,
        paused?: paused?
      }

      {:ok, state}
    end

    @impl true
    def handle_info({:state_update, game_state}, state) do
      if should_make_move?(game_state, state) do
        schedule_move(state.delay_ms)
      end

      {:noreply, state}
    end

    @impl true
    def handle_info({:game_over, _winner, _scores}, state) do
      Logger.info("BotPlayer for room #{state.room_code}, position #{state.position} - Game over")

      {:noreply, state}
    end

    @impl true
    def handle_info(:make_move, state) do
      execute_move(state)
      {:noreply, state}
    end

    @impl true
    def handle_cast(:pause, state) do
      Logger.info("BotPlayer paused for room #{state.room_code}, position #{state.position}")

      {:noreply, %{state | paused?: true}}
    end

    @impl true
    def handle_cast(:resume, state) do
      Logger.info("BotPlayer resumed for room #{state.room_code}, position #{state.position}")

      # Check if it's our turn and make a move if needed
      new_state = %{state | paused?: false}

      case GameAdapter.get_state(state.room_code) do
        {:ok, game_state} ->
          if should_make_move?(game_state, new_state) do
            schedule_move(new_state.delay_ms)
          end

          {:noreply, new_state}

        {:error, _reason} ->
          {:noreply, new_state}
      end
    end

    @impl true
    def handle_cast(:stop, state) do
      Logger.info("BotPlayer stopping for room #{state.room_code}, position #{state.position}")

      # Leave the room
      PidroServer.Games.RoomManager.leave_room(state.user_id)

      GameAdapter.unsubscribe(state.room_code)
      {:stop, :normal, state}
    end

    ## Private Functions

    @doc false
    defp should_make_move?(game_state, state) do
      not state.paused? and
        Map.get(game_state, :current_player) == state.position and
        Map.get(game_state, :phase) != :game_over
    end

    @doc false
    defp schedule_move(delay_ms) do
      Process.send_after(self(), :make_move, delay_ms)
    end

    @doc false
    defp execute_move(state) do
      case GameAdapter.get_legal_actions(state.room_code, state.position) do
        {:ok, legal_actions} when legal_actions != [] ->
          # Use the strategy to pick an action (now returns {:ok, action, reasoning})
          game_state = get_game_state(state.room_code)

          case state.strategy.pick_action(legal_actions, game_state) do
            {:ok, action, reasoning} ->
              Logger.debug(
                "BotPlayer (#{state.room_code}/#{state.position}) executing action: #{inspect(action)} - #{reasoning}"
              )

              # Emit bot reasoning event
              event =
                Event.new(:bot_reasoning, state.position, %{
                  action: action,
                  reasoning: reasoning,
                  alternatives_count: length(legal_actions)
                })

              emit_bot_reasoning_event(state.room_code, event)

              # Apply the action
              case GameAdapter.apply_action(state.room_code, state.position, action) do
                {:ok, _new_state} ->
                  Logger.debug(
                    "BotPlayer (#{state.room_code}/#{state.position}) successfully executed action"
                  )

                {:error, reason} ->
                  Logger.warning(
                    "BotPlayer (#{state.room_code}/#{state.position}) failed to execute action: #{inspect(reason)}"
                  )
              end

            # Fallback for old strategies that don't return reasoning
            action when not is_tuple(action) or elem(action, 0) != :ok ->
              Logger.debug(
                "BotPlayer (#{state.room_code}/#{state.position}) executing action: #{inspect(action)} (legacy strategy)"
              )

              # Apply the action
              case GameAdapter.apply_action(state.room_code, state.position, action) do
                {:ok, _new_state} ->
                  Logger.debug(
                    "BotPlayer (#{state.room_code}/#{state.position}) successfully executed action"
                  )

                {:error, reason} ->
                  Logger.warning(
                    "BotPlayer (#{state.room_code}/#{state.position}) failed to execute action: #{inspect(reason)}"
                  )
              end
          end

        {:ok, []} ->
          Logger.debug("BotPlayer (#{state.room_code}/#{state.position}) has no legal actions")

        {:error, :not_found} ->
          Logger.warning("BotPlayer (#{state.room_code}/#{state.position}) - game not found")

        {:error, reason} ->
          Logger.warning(
            "BotPlayer (#{state.room_code}/#{state.position}) error fetching legal actions: #{inspect(reason)}"
          )
      end
    end

    @doc false
    defp get_game_state(room_code) do
      case GameAdapter.get_state(room_code) do
        {:ok, state} -> state
        {:error, _} -> %{}
      end
    end

    @doc false
    defp emit_bot_reasoning_event(room_code, event) do
      # Try to record the event via EventRecorder
      case Registry.lookup(PidroServer.Dev.EventRecorderRegistry, room_code) do
        [{pid, _}] when is_pid(pid) ->
          # Send the event directly to the EventRecorder
          send(pid, {:bot_reasoning, event})
          :ok

        [] ->
          # EventRecorder not running - skip logging
          :ok
      end
    end
  end
end
