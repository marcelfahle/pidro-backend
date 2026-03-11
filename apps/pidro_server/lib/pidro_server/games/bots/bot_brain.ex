defmodule PidroServer.Games.Bots.BotBrain do
  @moduledoc """
  Shared move logic for BotPlayer and SubstituteBot.

  Contains the decision-making and action execution code common to both
  bot types. Each bot GenServer handles its own lifecycle (join vs takeover,
  pause/resume) and delegates move logic here.
  """

  require Logger

  alias Pidro.Game.DealerRob
  alias PidroServer.Games.{GameAdapter, Lifecycle}

  @doc """
  Returns true if the game state indicates it's this bot's turn.

  Checks that the phase is active (not :complete or nil) and that either
  `current_turn` matches the bot's position or the phase is :dealer_selection.

  Note: Does NOT check paused state — callers that support pausing should
  check that separately before calling this function.
  """
  @spec should_make_move?(map(), atom()) :: boolean()
  def should_make_move?(game_state, position) do
    phase = Map.get(game_state, :phase)

    phase not in [:complete, nil] and
      (Map.get(game_state, :current_turn) == position or
         phase == :dealer_selection)
  end

  @doc """
  Computes a bot delay using a base delay, symmetric random variance, and floor.
  """
  @spec compute_delay(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def compute_delay(base_ms, variance_ms, min_ms) do
    raw_delay =
      if variance_ms > 0 do
        base_ms + Enum.random(-variance_ms..variance_ms)
      else
        base_ms
      end

    max(raw_delay, min_ms)
  end

  @doc """
  Schedules a `:make_move` message using the current pacing config.

  `transition_delay_ms` is added on top of the computed bot delay. Optional
  schedule opts allow tests or explicit callers to override the base delay.
  """
  @spec schedule_move(non_neg_integer(), keyword()) :: reference()
  def schedule_move(transition_delay_ms \\ 0, opts \\ []) do
    base_ms = Keyword.get(opts, :base_delay_ms, Lifecycle.config(:bot_delay_ms))
    variance_ms = Keyword.get(opts, :variance_ms, Lifecycle.config(:bot_delay_variance_ms))
    min_ms = Keyword.get(opts, :min_delay_ms, Lifecycle.config(:bot_min_delay_ms))
    delay_ms = compute_delay(base_ms, variance_ms, min_ms) + transition_delay_ms

    Process.send_after(self(), :make_move, delay_ms)
  end

  @doc """
  Schedules a move only if one is not already pending.
  """
  @spec schedule_move_once(map(), non_neg_integer(), keyword()) :: map()
  def schedule_move_once(state, transition_delay_ms \\ 0, opts \\ []) do
    if Map.get(state, :move_scheduled?, false) do
      state
    else
      schedule_move(transition_delay_ms, opts)
      Map.put(state, :move_scheduled?, true)
    end
  end

  @doc """
  Executes a bot move: fetches legal actions, picks one via the strategy,
  resolves it, and applies it through the GameAdapter.

  `bot_label` is used for log messages (e.g., "BotPlayer" or "SubstituteBot").
  """
  @spec execute_move(map(), String.t()) :: :ok
  def execute_move(state, bot_label) do
    case GameAdapter.get_legal_actions(state.room_code, state.position) do
      {:ok, legal_actions} when legal_actions != [] ->
        game_state = get_game_state(state.room_code)

        case state.strategy.pick_action(legal_actions, game_state) do
          {:ok, action, reasoning} ->
            action = resolve_action(action, game_state, state.position)

            Logger.debug(
              "#{bot_label} (#{state.room_code}/#{state.position}) executing: #{inspect(action)} - #{reasoning}"
            )

            case GameAdapter.apply_action(state.room_code, state.position, action) do
              {:ok, _new_state} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "#{bot_label} (#{state.room_code}/#{state.position}) action failed: #{inspect(reason)}"
                )
            end

          action ->
            action = resolve_action(action, game_state, state.position)

            Logger.debug(
              "#{bot_label} (#{state.room_code}/#{state.position}) executing: #{inspect(action)} (legacy)"
            )

            case GameAdapter.apply_action(state.room_code, state.position, action) do
              {:ok, _new_state} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "#{bot_label} (#{state.room_code}/#{state.position}) action failed: #{inspect(reason)}"
                )
            end
        end

      {:ok, []} ->
        Logger.debug("#{bot_label} (#{state.room_code}/#{state.position}) has no legal actions")

      {:error, :not_found} ->
        Logger.warning("#{bot_label} (#{state.room_code}/#{state.position}) - game not found")

      {:error, reason} ->
        Logger.warning(
          "#{bot_label} (#{state.room_code}/#{state.position}) error: #{inspect(reason)}"
        )
    end
  end

  @doc """
  Resolves placeholder actions into concrete actions.

  `{:select_hand, :choose_6_cards}` is a marker -- bots must compute actual
  card selection using `DealerRob.select_best_cards/2`.
  """
  @spec resolve_action(term(), map(), atom()) :: term()
  def resolve_action({:select_hand, :choose_6_cards}, game_state, position) do
    player = Map.get(game_state.players, position, %{})
    hand = Map.get(player, :hand, [])
    deck = Map.get(game_state, :deck, [])
    trump = Map.get(game_state, :trump_suit)
    pool = hand ++ deck
    selected = DealerRob.select_best_cards(pool, trump)
    {:select_hand, selected}
  end

  def resolve_action(action, _game_state, _position), do: action

  @doc """
  Fetches the current game state from the GameAdapter.
  Returns an empty map if the game is not found.
  """
  @spec get_game_state(String.t()) :: map()
  def get_game_state(room_code) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} -> state
      {:error, _} -> %{}
    end
  end
end
