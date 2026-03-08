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

  alias Pidro.Game.DealerRob
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
        if should_make_move?(game_state, state) do
          schedule_move()
        end

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:state_update, game_state}, state) do
    if should_make_move?(game_state, state) do
      schedule_move()
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
    execute_move(state)
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
  def terminate(_reason, state) do
    GameAdapter.unsubscribe(state.room_code)

    Logger.info("SubstituteBot stopped for room #{state.room_code} at #{state.position}")

    :ok
  end

  ## Private Functions

  defp should_make_move?(game_state, state) do
    phase = Map.get(game_state, :phase)

    phase not in [:complete, nil] and
      (Map.get(game_state, :current_turn) == state.position or
         phase == :dealer_selection)
  end

  defp schedule_move do
    Process.send_after(self(), :make_move, @delay_ms)
  end

  defp execute_move(state) do
    case GameAdapter.get_legal_actions(state.room_code, state.position) do
      {:ok, legal_actions} when legal_actions != [] ->
        game_state = get_game_state(state.room_code)

        case state.strategy.pick_action(legal_actions, game_state) do
          {:ok, action, reasoning} ->
            action = resolve_action(action, game_state, state.position)

            Logger.debug(
              "SubstituteBot (#{state.room_code}/#{state.position}) executing: #{inspect(action)} - #{reasoning}"
            )

            case GameAdapter.apply_action(state.room_code, state.position, action) do
              {:ok, _new_state} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "SubstituteBot (#{state.room_code}/#{state.position}) action failed: #{inspect(reason)}"
                )
            end

          action ->
            action = resolve_action(action, game_state, state.position)

            Logger.debug(
              "SubstituteBot (#{state.room_code}/#{state.position}) executing: #{inspect(action)} (legacy)"
            )

            case GameAdapter.apply_action(state.room_code, state.position, action) do
              {:ok, _new_state} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "SubstituteBot (#{state.room_code}/#{state.position}) action failed: #{inspect(reason)}"
                )
            end
        end

      {:ok, []} ->
        Logger.debug("SubstituteBot (#{state.room_code}/#{state.position}) has no legal actions")

      {:error, :not_found} ->
        Logger.warning("SubstituteBot (#{state.room_code}/#{state.position}) - game not found")

      {:error, reason} ->
        Logger.warning(
          "SubstituteBot (#{state.room_code}/#{state.position}) error: #{inspect(reason)}"
        )
    end
  end

  defp resolve_action({:select_hand, :choose_6_cards}, game_state, position) do
    player = Map.get(game_state.players, position, %{})
    hand = Map.get(player, :hand, [])
    deck = Map.get(game_state, :deck, [])
    trump = Map.get(game_state, :trump_suit)
    pool = hand ++ deck
    selected = DealerRob.select_best_cards(pool, trump)
    {:select_hand, selected}
  end

  defp resolve_action(action, _game_state, _position), do: action

  defp get_game_state(room_code) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} -> state
      {:error, _} -> %{}
    end
  end
end
