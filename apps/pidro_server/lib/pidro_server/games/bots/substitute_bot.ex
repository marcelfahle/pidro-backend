defmodule PidroServer.Games.Bots.SubstituteBot do
  @moduledoc """
  GenServer that fills in for a disconnected player during a live game.

  Unlike `BotPlayer`, a SubstituteBot does NOT join the room — it takes over
  an existing seat that was vacated by a disconnected human. It subscribes to
  game PubSub updates, detects when it's the bot's turn, and plays moves
  using the random strategy.

  Started under `BotSupervisor` via `start/2`. Stopped by calling
  `GenServer.stop/1` or `DynamicSupervisor.terminate_child/2`.
  """

  use GenServer
  require Logger

  alias PidroServer.Games.Bots.BotBrain
  alias PidroServer.Games.Bots.Strategies.RandomStrategy
  alias PidroServer.Games.GameAdapter

  @delay_ms 500

  ## Public API

  @doc """
  Starts a substitute bot for the given room and position.

  Returns `{:ok, pid}` on success. The bot is started under `BotSupervisor`.
  """
  @spec start(String.t(), atom()) :: {:ok, pid()} | {:error, term()}
  def start(room_code, position) do
    DynamicSupervisor.start_child(
      PidroServer.Games.Bots.BotSupervisor,
      {__MODULE__, room_code: room_code, position: position}
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    room_code = Keyword.fetch!(opts, :room_code)
    position = Keyword.fetch!(opts, :position)

    :ok = GameAdapter.subscribe(room_code)

    Logger.info("SubstituteBot started for room #{room_code} at #{position}")

    state = %{
      room_code: room_code,
      position: position,
      strategy: RandomStrategy
    }

    {:ok, state, {:continue, :check_initial_move}}
  end

  @impl true
  def handle_continue(:check_initial_move, state) do
    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        if BotBrain.should_make_move?(game_state, state.position) do
          BotBrain.schedule_move(@delay_ms)
        end

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:state_update, game_state}, state) do
    if BotBrain.should_make_move?(game_state, state.position) do
      BotBrain.schedule_move(@delay_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:game_over, _winner, _scores}, state) do
    Logger.info("SubstituteBot (#{state.room_code}/#{state.position}) - Game over")
    {:noreply, state}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:make_move, state) do
    BotBrain.execute_move(state, "SubstituteBot")
    {:noreply, state}
  end

  # Ignore disconnect cascade PubSub messages
  @impl true
  def handle_info({:player_reconnecting, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:bot_substitute_active, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_permanently_botted, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_reconnected, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_reclaimed_seat, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:owner_decision_available, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:owner_changed, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_available, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_seat_closed, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_joined, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    GameAdapter.unsubscribe(state.room_code)

    Logger.info("SubstituteBot stopped for room #{state.room_code} at #{state.position}")

    :ok
  end

end
