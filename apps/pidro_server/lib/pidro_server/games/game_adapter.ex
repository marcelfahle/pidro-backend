defmodule PidroServer.Games.GameAdapter do
  @moduledoc """
  Adapter for interacting with Pidro.Server game processes.

  Provides convenience functions for:
  - Applying game actions (bid, declare trump, play card)
  - Retrieving game state (full or player-specific)
  - Getting legal actions for a position
  - PubSub subscription management
  - State update broadcasting

  This module acts as a bridge between the Phoenix web layer and the
  Pidro.Server game engine processes.

  ## Usage

      # Apply an action
      {:ok, _state} = GameAdapter.apply_action("A3F9", :north, {:bid, 8})

      # Get game state
      {:ok, state} = GameAdapter.get_state("A3F9")

      # Get state for a specific player
      {:ok, state} = GameAdapter.get_state("A3F9", :north)

      # Subscribe to game updates
      :ok = GameAdapter.subscribe("A3F9")

  ## PubSub Topics

  - `game:<room_code>` - Game-specific updates (state_update, game_over)
  """

  require Logger
  alias Pidro.Game.Replay
  alias PidroServer.Games.{GameRegistry, GameSupervisor, RoomManager}

  @doc """
  Applies an action to a game.

  Forwards the action to the Pidro.Server process and broadcasts the resulting
  state update to all subscribed clients.

  ## Parameters

    - `room_code` - The room code (e.g., "A3F9")
    - `position` - The player position (`:north`, `:east`, `:south`, `:west`)
    - `action` - The action to apply (e.g., `{:bid, 8}`, `:pass`, `{:play_card, {14, :spades}}`)

  ## Returns

    - `{:ok, new_state}` on success
    - `{:error, :not_found}` if the game doesn't exist
    - `{:error, reason}` for invalid actions

  ## Examples

      # Bid
      GameAdapter.apply_action("A3F9", :north, {:bid, 8})

      # Pass
      GameAdapter.apply_action("A3F9", :east, :pass)

      # Declare trump
      GameAdapter.apply_action("A3F9", :south, {:declare_trump, :hearts})

      # Play card
      GameAdapter.apply_action("A3F9", :west, {:play_card, {14, :spades}})
  """
  @spec apply_action(String.t(), atom(), term()) :: {:ok, term()} | {:error, term()}
  def apply_action(room_code, position, action) do
    with :ok <- validate_room_status(room_code),
         {:ok, pid} <- GameRegistry.lookup(room_code) do
      try do
        case Pidro.Server.apply_action(pid, position, action) do
          {:ok, _state} = result ->
            broadcast_state_update(room_code, pid)
            result

          {:error, _reason} = error ->
            error
        end
      rescue
        e ->
          Logger.error(
            "Error applying action to game #{room_code}: #{Exception.message(e)}\n#{Exception.format_stacktrace()}"
          )

          {:error, Exception.message(e)}
      end
    end
  end

  @doc """
  Gets the current game state.

  Retrieves the full game state from the Pidro.Server process. This includes
  all public information about the game.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, state}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_state("A3F9")
      {:ok, %{phase: :bidding, current_player: :north, ...}}
  """
  @spec get_state(String.t()) :: {:ok, term()} | {:error, :not_found}
  def get_state(room_code) do
    with {:ok, pid} <- GameRegistry.lookup(room_code) do
      state = Pidro.Server.get_state(pid)
      {:ok, state}
    end
  end

  @doc """
  Gets the state for a specific player position.

  Returns the full game state (Pidro.Server does not have position-specific views yet).

  ## Parameters

    - `room_code` - The room code
    - `_position` - The player position (currently unused, for future API compatibility)

  ## Returns

    - `{:ok, state}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_state("A3F9", :north)
      {:ok, %{phase: :bidding, ...}}
  """
  @spec get_state(String.t(), atom()) :: {:ok, term()} | {:error, :not_found}
  def get_state(room_code, _position) do
    # Note: Pidro.Server currently only has get_state/1
    # Position-specific views could be added in the future
    get_state(room_code)
  end

  @doc """
  Gets legal actions for a player position.

  Returns the list of valid actions that the specified player can take in
  the current game state.

  ## Parameters

    - `room_code` - The room code
    - `position` - The player position

  ## Returns

    - `{:ok, actions}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_legal_actions("A3F9", :north)
      {:ok, [{:bid, 6}, {:bid, 7}, ..., :pass]}
  """
  @spec get_legal_actions(String.t(), atom()) :: {:ok, list()} | {:error, :not_found}
  def get_legal_actions(room_code, position) do
    with :ok <- validate_room_status(room_code),
         {:ok, pid} <- GameRegistry.lookup(room_code) do
      actions = Pidro.Server.legal_actions(pid, position)
      {:ok, actions}
    else
      {:error, :room_not_playable} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Subscribes to game updates for a room.

  Subscribes the calling process to receive game update messages via PubSub.
  Messages are broadcast on the topic `game:<room_code>`.

  ## Message Types

    - `{:state_update, new_state}` - Game state changed
    - `{:game_over, winner, scores}` - Game ended

  ## Parameters

    - `room_code` - The room code to subscribe to

  ## Returns

    - `:ok`

  ## Examples

      iex> GameAdapter.subscribe("A3F9")
      :ok
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(room_code) do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
  end

  @doc """
  Unsubscribes from game updates for a room.

  Removes the subscription for the calling process from the game's PubSub topic.

  ## Parameters

    - `room_code` - The room code to unsubscribe from

  ## Returns

    - `:ok`

  ## Examples

      iex> GameAdapter.unsubscribe("A3F9")
      :ok
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(room_code) do
    Phoenix.PubSub.unsubscribe(PidroServer.PubSub, "game:#{room_code}")
  end

  @doc """
  Gets the PID for a game process.

  Looks up the game process in the registry. Useful for debugging or
  advanced use cases.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, pid}` if the game exists
    - `{:error, :not_found}` if no game is registered

  ## Examples

      iex> GameAdapter.get_game("A3F9")
      {:ok, #PID<0.234.0>}
  """
  @spec get_game(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_game(room_code) do
    GameSupervisor.get_game(room_code)
  end

  @doc """
  Undoes the last action in the game.

  Reverts the game state to before the last action was applied. This uses
  the Pidro.Game.Replay.undo/1 function to replay all events except the last one.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, previous_state}` on success
    - `{:error, :not_found}` if the game doesn't exist
    - `{:error, :no_history}` if there are no actions to undo

  ## Examples

      iex> GameAdapter.undo("A3F9")
      {:ok, %{phase: :bidding, ...}}
  """
  @spec undo(String.t()) :: {:ok, term()} | {:error, term()}
  def undo(room_code) do
    with {:ok, pid} <- GameRegistry.lookup(room_code) do
      try do
        # Get current state
        current_state = Pidro.Server.get_state(pid)

        # Call Replay.undo/1
        case Replay.undo(current_state) do
          {:ok, previous_state} ->
            # Set the game state to the previous state
            # We need to call GenServer.call directly since there's no set_state function
            case GenServer.call(pid, {:set_state, previous_state}) do
              :ok ->
                # Broadcast the state update
                broadcast_state_update(room_code, pid)
                {:ok, previous_state}

              error ->
                error
            end

          {:error, _reason} = error ->
            error
        end
      rescue
        e ->
          Logger.error(
            "Error undoing action for game #{room_code}: #{Exception.message(e)}\n#{Exception.format_stacktrace()}"
          )

          {:error, Exception.message(e)}
      end
    end
  end

  ## Private Functions

  @spec validate_room_status(String.t()) :: :ok | {:error, :room_not_playable}
  defp validate_room_status(room_code) do
    case RoomManager.get_room(room_code) do
      {:ok, %{status: :playing}} -> :ok
      {:ok, %{status: _}} -> {:error, :room_not_playable}
      {:error, :room_not_found} -> :ok
    end
  end

  @doc false
  @spec broadcast_state_update(String.t(), pid()) :: :ok | {:error, term()}
  defp broadcast_state_update(room_code, pid) do
    try do
      state = Pidro.Server.get_state(pid)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, state}
      )

      # Check if game is over and broadcast game_over message
      if Map.get(state, :phase) == :game_over do
        broadcast_game_over(room_code, state)
      end

      :ok
    rescue
      e ->
        Logger.error(
          "Error broadcasting state update for room #{room_code}: #{Exception.message(e)}"
        )

        {:error, Exception.message(e)}
    end
  end

  @doc false
  @spec broadcast_game_over(String.t(), map()) :: :ok | {:error, term()}
  defp broadcast_game_over(room_code, state) do
    winner = Map.get(state, :winner)
    scores = Map.get(state, :scores)

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room_code}",
      {:game_over, winner, scores}
    )
  end
end
