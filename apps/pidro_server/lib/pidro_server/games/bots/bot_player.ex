defmodule PidroServer.Games.Bots.BotPlayer do
  @moduledoc """
  GenServer representing a single bot player in a game.

  Subscribes to game PubSub updates, detects when it's the bot's turn,
  and automatically executes legal actions using a configurable strategy.

  ## Features

  - Subscribes to game PubSub updates on start
  - Detects when it's the bot's turn by checking current_turn == position
  - Picks actions via configurable strategy module
  - Applies actions using GameAdapter with configurable delay
  - Can be paused/resumed during gameplay
  """

  use GenServer
  require Logger
  alias PidroServer.Games.Bots.BotBrain
  alias PidroServer.Games.Bots.Strategies.RandomStrategy
  alias PidroServer.Games.GameAdapter

  @default_strategy RandomStrategy
  @default_delay_ms 1000

  ## Public API

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec pause(pid()) :: :ok
  def pause(pid) do
    GenServer.cast(pid, :pause)
  end

  @spec resume(pid()) :: :ok
  def resume(pid) do
    GenServer.cast(pid, :resume)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.cast(pid, :stop)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    room_code = Map.fetch!(opts, :room_code)
    position = Map.fetch!(opts, :position)
    strategy = Map.get(opts, :strategy, @default_strategy)
    delay_ms = Map.get(opts, :delay_ms, @default_delay_ms)
    paused? = Map.get(opts, :paused?, false)

    # Resolve strategy atom to module if needed
    strategy_module = resolve_strategy(strategy)

    bot_user_id = "bot_#{room_code}_#{position}"

    case PidroServer.Games.RoomManager.join_room(room_code, bot_user_id, position) do
      {:ok, _room, ^position} ->
        Logger.info("Bot #{bot_user_id} joined room #{room_code} at #{position}")

      {:ok, _room, other_position} ->
        Logger.warning(
          "Bot #{bot_user_id} requested #{position} but got #{other_position} in room #{room_code}"
        )

      {:error, reason} ->
        Logger.warning("Bot #{bot_user_id} could not join room #{room_code}: #{inspect(reason)}")
    end

    :ok = GameAdapter.subscribe(room_code)

    Logger.info(
      "BotPlayer started for room #{room_code}, position #{position}, strategy #{inspect(strategy_module)}"
    )

    state = %{
      room_code: room_code,
      position: position,
      user_id: bot_user_id,
      strategy: strategy_module,
      delay_ms: delay_ms,
      paused?: paused?
    }

    {:ok, state, {:continue, :check_initial_move}}
  end

  @impl true
  def handle_continue(:check_initial_move, state) do
    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        if should_make_move?(game_state, state) do
          BotBrain.schedule_move(state.delay_ms)
        end

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:state_update, game_state}, state) do
    if should_make_move?(game_state, state) do
      BotBrain.schedule_move(state.delay_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:game_over, _winner, _scores}, state) do
    Logger.info("BotPlayer for room #{state.room_code}, position #{state.position} - Game over")
    {:noreply, state}
  end

  # Ignore Phoenix Channel broadcast messages (presence_diff, game_state, etc.).
  # BotPlayer subscribes to the same PubSub topic as GameChannel, so it receives
  # channel-level broadcasts. Game state updates are already handled via the
  # direct {:state_update, state} PubSub messages above.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:make_move, state) do
    BotBrain.execute_move(state, "BotPlayer")
    {:noreply, state}
  end

  @impl true
  def handle_info(:pause, state) do
    {:noreply, %{state | paused?: true}}
  end

  @impl true
  def handle_info(:resume, state) do
    new_state = %{state | paused?: false}

    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        if should_make_move?(game_state, new_state) do
          BotBrain.schedule_move(new_state.delay_ms)
        end

      {:error, _reason} ->
        :ok
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("BotPlayer paused for room #{state.room_code}, position #{state.position}")
    {:noreply, %{state | paused?: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("BotPlayer resumed for room #{state.room_code}, position #{state.position}")
    new_state = %{state | paused?: false}

    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        if should_make_move?(game_state, new_state) do
          BotBrain.schedule_move(new_state.delay_ms)
        end

        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    Logger.info("BotPlayer stopping for room #{state.room_code}, position #{state.position}")
    PidroServer.Games.RoomManager.leave_room(state.user_id)
    GameAdapter.unsubscribe(state.room_code)
    {:stop, :normal, state}
  end

  ## Private Functions

  defp should_make_move?(game_state, state) do
    not state.paused? and BotBrain.should_make_move?(game_state, state.position)
  end

  defp resolve_strategy(:random), do: RandomStrategy
  defp resolve_strategy(:basic), do: RandomStrategy
  defp resolve_strategy(:smart), do: RandomStrategy
  defp resolve_strategy(module) when is_atom(module), do: module
end
