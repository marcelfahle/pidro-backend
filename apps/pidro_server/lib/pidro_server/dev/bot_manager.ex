if Mix.env() == :dev do
  defmodule PidroServer.Dev.BotManager do
    @moduledoc """
    GenServer that tracks and manages all bot players across all games.

    This module is only available in the development environment and provides
    a centralized way to manage bot players for testing and development purposes.

    ## Architecture

    The BotManager uses both a GenServer state and an ETS table for fast lookups:
    - GenServer state: `%{game_id => %{position => bot_pid}}`
    - ETS table: `:dev_bots` with key `{room_code, position}` and value `bot_pid`

    Bot processes are supervised by `PidroServer.Dev.BotSupervisor` and the
    BotManager monitors them to handle crashes gracefully.

    ## Usage

        # Start a bot for a specific position
        {:ok, pid} = BotManager.start_bot("A3F9", :north, :random, 1000)

        # Stop a specific bot
        :ok = BotManager.stop_bot("A3F9", :north)

        # Stop all bots for a game
        :ok = BotManager.stop_all_bots("A3F9")

        # Pause/resume a bot
        :ok = BotManager.pause_bot("A3F9", :north)
        :ok = BotManager.resume_bot("A3F9", :north)

        # List all bots for a game
        bots = BotManager.list_bots("A3F9")
        #=> %{north: %{pid: #PID<...>, strategy: :random, status: :running}}

    ## Bot Strategies

    - `:random` - Picks random legal actions
    - `:basic` - Simple heuristics (future implementation)
    - `:smart` - Advanced strategy (future implementation)

    ## Process Lifecycle

    1. `start_bot/4` creates a bot child spec and starts it via DynamicSupervisor
    2. Bot PID is tracked in both GenServer state and ETS
    3. BotManager monitors the bot process
    4. On bot crash/exit, `handle_info({:DOWN, ...})` cleans up state
    5. `stop_bot/2` explicitly terminates a bot and removes tracking
    """

    use GenServer
    require Logger

    @table_name :dev_bots

    ## Client API

    @doc """
    Starts the BotManager GenServer.

    Creates the ETS table for fast bot lookups and initializes state.

    ## Options

    Standard GenServer options can be passed.

    ## Examples

        {:ok, pid} = BotManager.start_link([])
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
    end

    @doc """
    Starts multiple bots for a game.

    This is a convenience function that starts the specified number of bots
    for the first N positions (north, east, south, west).

    ## Parameters

    - `room_code` - The room code (e.g., "A3F9")
    - `bot_count` - Number of bots to start (1-4)
    - `strategy` - The bot strategy (`:random`, `:basic`, `:smart`)
    - `delay_ms` - Delay in milliseconds before bot takes action (default: 1000)

    ## Returns

    - `{:ok, pids}` - List of started bot PIDs
    - `{:error, reason}` - Failed to start bots

    ## Examples

        {:ok, pids} = BotManager.start_bots("A3F9", 3, :random)
        {:ok, pids} = BotManager.start_bots("A3F9", 4, :basic, 500)
    """
    @spec start_bots(String.t(), pos_integer(), atom(), non_neg_integer()) ::
            {:ok, [pid()]} | {:error, term()}
    def start_bots(room_code, bot_count, strategy, delay_ms \\ 1000)
        when bot_count >= 1 and bot_count <= 4 do
      positions = [:north, :east, :south, :west]

      positions
      |> Enum.take(bot_count)
      |> Enum.reduce_while({:ok, []}, fn position, {:ok, pids} ->
        case start_bot(room_code, position, strategy, delay_ms) do
          {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, pids} -> {:ok, Enum.reverse(pids)}
        error -> error
      end
    end

    @doc """
    Starts a bot for a specific room and position.

    The bot will be supervised by `PidroServer.Dev.BotSupervisor` and will
    automatically play when it's their turn.

    ## Parameters

    - `room_code` - The room code (e.g., "A3F9")
    - `position` - The player position (`:north`, `:east`, `:south`, `:west`)
    - `strategy` - The bot strategy (`:random`, `:basic`, `:smart`)
    - `delay_ms` - Delay in milliseconds before bot takes action (0-5000)

    ## Returns

    - `{:ok, pid}` - Bot successfully started
    - `{:error, :already_exists}` - Bot already exists for this position
    - `{:error, reason}` - Failed to start bot

    ## Examples

        {:ok, pid} = BotManager.start_bot("A3F9", :north, :random, 1000)
        {:error, :already_exists} = BotManager.start_bot("A3F9", :north, :random, 1000)
    """
    @spec start_bot(String.t(), atom(), atom(), non_neg_integer()) ::
            {:ok, pid()} | {:error, term()}
    def start_bot(room_code, position, strategy, delay_ms)
        when position in [:north, :east, :south, :west] and
               strategy in [:random, :basic, :smart] and
               is_integer(delay_ms) and delay_ms >= 0 and delay_ms <= 5000 do
      GenServer.call(__MODULE__, {:start_bot, room_code, position, strategy, delay_ms})
    end

    @doc """
    Stops a specific bot.

    Terminates the bot process and removes it from tracking.

    ## Parameters

    - `room_code` - The room code
    - `position` - The player position

    ## Returns

    - `:ok` - Bot stopped successfully
    - `{:error, :not_found}` - No bot exists for this position

    ## Examples

        :ok = BotManager.stop_bot("A3F9", :north)
        {:error, :not_found} = BotManager.stop_bot("A3F9", :west)
    """
    @spec stop_bot(String.t(), atom()) :: :ok | {:error, :not_found}
    def stop_bot(room_code, position) when position in [:north, :east, :south, :west] do
      GenServer.call(__MODULE__, {:stop_bot, room_code, position})
    end

    @doc """
    Stops all bots for a game.

    Terminates all bot processes for the specified room and removes them
    from tracking. This is typically called when a game ends.

    ## Parameters

    - `room_code` - The room code

    ## Returns

    - `:ok` - All bots stopped successfully

    ## Examples

        :ok = BotManager.stop_all_bots("A3F9")
    """
    @spec stop_all_bots(String.t()) :: :ok
    def stop_all_bots(room_code) do
      GenServer.call(__MODULE__, {:stop_all_bots, room_code})
    end

    @doc """
    Pauses a bot.

    The bot will stop taking actions until resumed. Currently, this is
    implemented by sending a pause message to the bot process.

    ## Parameters

    - `room_code` - The room code
    - `position` - The player position

    ## Returns

    - `:ok` - Bot paused successfully
    - `{:error, :not_found}` - No bot exists for this position

    ## Examples

        :ok = BotManager.pause_bot("A3F9", :north)
    """
    @spec pause_bot(String.t(), atom()) :: :ok | {:error, :not_found}
    def pause_bot(room_code, position) when position in [:north, :east, :south, :west] do
      GenServer.call(__MODULE__, {:pause_bot, room_code, position})
    end

    @doc """
    Resumes a paused bot.

    The bot will resume taking actions when it's their turn.

    ## Parameters

    - `room_code` - The room code
    - `position` - The player position

    ## Returns

    - `:ok` - Bot resumed successfully
    - `{:error, :not_found}` - No bot exists for this position

    ## Examples

        :ok = BotManager.resume_bot("A3F9", :north)
    """
    @spec resume_bot(String.t(), atom()) :: :ok | {:error, :not_found}
    def resume_bot(room_code, position) when position in [:north, :east, :south, :west] do
      GenServer.call(__MODULE__, {:resume_bot, room_code, position})
    end

    @doc """
    Lists all bots for a game.

    Returns a map of positions to bot information.

    ## Parameters

    - `room_code` - The room code

    ## Returns

    A map of positions to bot information:

        %{
          north: %{pid: #PID<...>, strategy: :random, status: :running},
          east: %{pid: #PID<...>, strategy: :basic, status: :paused}
        }

    ## Examples

        bots = BotManager.list_bots("A3F9")
        #=> %{north: %{pid: #PID<...>, strategy: :random, status: :running}}
    """
    @spec list_bots(String.t()) :: %{atom() => %{pid: pid(), strategy: atom(), status: atom()}}
    def list_bots(room_code) do
      GenServer.call(__MODULE__, {:list_bots, room_code})
    end

    ## GenServer Callbacks

    @impl true
    def init(:ok) do
      # Create ETS table for fast lookups
      # Type: :set - one bot per {room_code, position} key
      # Access: :public - can be read by other processes
      # Options: :named_table - allows lookup by name
      table = :ets.new(@table_name, [:set, :public, :named_table])

      Logger.info("BotManager started with ETS table #{inspect(table)}")

      {:ok, %{bots: %{}, monitors: %{}}}
    end

    @impl true
    def handle_call({:start_bot, room_code, position, strategy, delay_ms}, _from, state) do
      # Check if bot already exists
      case :ets.lookup(@table_name, {room_code, position}) do
        [{_key, _existing_pid}] ->
          {:reply, {:error, :already_exists}, state}

        [] ->
          # Create bot child spec
          # BotPlayer will be implemented in Phase 2
          bot_spec = {
            PidroServer.Dev.BotPlayer,
            room_code: room_code, position: position, strategy: strategy, delay_ms: delay_ms
          }

          # Start bot via DynamicSupervisor
          case DynamicSupervisor.start_child(PidroServer.Dev.BotSupervisor, bot_spec) do
            {:ok, pid} ->
              # Monitor the bot process
              ref = Process.monitor(pid)

              # Track in ETS
              :ets.insert(@table_name, {{room_code, position}, pid})

              # Track in GenServer state with full bot info
              bot_info = %{pid: pid, strategy: strategy, delay_ms: delay_ms, paused: false}
              new_bots = add_bot_to_state(state.bots, room_code, position, bot_info)
              new_monitors = Map.put(state.monitors, ref, {room_code, position, pid})

              Logger.info(
                "Started bot for room #{room_code}, position #{position}, strategy #{strategy}, delay #{delay_ms}ms"
              )

              {:reply, {:ok, pid}, %{state | bots: new_bots, monitors: new_monitors}}

            {:error, reason} = error ->
              Logger.error("Failed to start bot: #{inspect(reason)}")
              {:reply, error, state}
          end
      end
    end

    @impl true
    def handle_call({:stop_bot, room_code, position}, _from, state) do
      case :ets.lookup(@table_name, {room_code, position}) do
        [{_key, pid}] ->
          # Stop the bot process
          DynamicSupervisor.terminate_child(PidroServer.Dev.BotSupervisor, pid)

          # Clean up will happen in handle_info({:DOWN, ...})
          {:reply, :ok, state}

        [] ->
          {:reply, {:error, :not_found}, state}
      end
    end

    @impl true
    def handle_call({:stop_all_bots, room_code}, _from, state) do
      # Get all bots for this room
      positions = Map.get(state.bots, room_code, %{})

      # Stop each bot
      Enum.each(positions, fn {_position, pid} ->
        DynamicSupervisor.terminate_child(PidroServer.Dev.BotSupervisor, pid)
      end)

      # Clean up will happen in handle_info({:DOWN, ...}) for each bot
      {:reply, :ok, state}
    end

    @impl true
    def handle_call({:pause_bot, room_code, position}, _from, state) do
      case :ets.lookup(@table_name, {room_code, position}) do
        [{_key, pid}] ->
          # Send pause message to bot
          send(pid, :pause)

          # Update paused flag in state
          new_bots =
            Map.update(state.bots, room_code, %{}, fn positions ->
              Map.update(positions, position, %{}, fn bot_info ->
                %{bot_info | paused: true}
              end)
            end)

          {:reply, :ok, %{state | bots: new_bots}}

        [] ->
          {:reply, {:error, :not_found}, state}
      end
    end

    @impl true
    def handle_call({:resume_bot, room_code, position}, _from, state) do
      case :ets.lookup(@table_name, {room_code, position}) do
        [{_key, pid}] ->
          # Send resume message to bot
          send(pid, :resume)

          # Update paused flag in state
          new_bots =
            Map.update(state.bots, room_code, %{}, fn positions ->
              Map.update(positions, position, %{}, fn bot_info ->
                %{bot_info | paused: false}
              end)
            end)

          {:reply, :ok, %{state | bots: new_bots}}

        [] ->
          {:reply, {:error, :not_found}, state}
      end
    end

    @impl true
    def handle_call({:list_bots, room_code}, _from, state) do
      positions = Map.get(state.bots, room_code, %{})

      # Return bot info with status (paused flag is tracked in state)
      bots =
        Enum.reduce(positions, %{}, fn {position, bot_info}, acc ->
          Map.put(acc, position, %{
            pid: bot_info.pid,
            strategy: bot_info.strategy,
            status: if(bot_info.paused, do: :paused, else: :running)
          })
        end)

      {:reply, bots, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, reason}, state) do
      # Bot process died - clean up tracking
      case Map.get(state.monitors, ref) do
        {room_code, position, ^pid} ->
          Logger.info(
            "Bot for room #{room_code}, position #{position} exited: #{inspect(reason)}"
          )

          # Remove from ETS
          :ets.delete(@table_name, {room_code, position})

          # Remove from GenServer state
          new_bots =
            Map.update(state.bots, room_code, %{}, fn positions ->
              Map.delete(positions, position)
            end)

          # Clean up empty room entries
          new_bots =
            if Map.get(new_bots, room_code) == %{} do
              Map.delete(new_bots, room_code)
            else
              new_bots
            end

          new_monitors = Map.delete(state.monitors, ref)

          {:noreply, %{state | bots: new_bots, monitors: new_monitors}}

        nil ->
          # Unknown monitor reference, ignore
          {:noreply, state}
      end
    end

    ## Private Functions

    defp add_bot_to_state(bots, room_code, position, bot_info) do
      Map.update(bots, room_code, %{position => bot_info}, fn positions ->
        Map.put(positions, position, bot_info)
      end)
    end
  end
end
