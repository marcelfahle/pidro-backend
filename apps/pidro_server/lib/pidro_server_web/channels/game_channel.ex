defmodule PidroServerWeb.GameChannel do
  @moduledoc """
  GameChannel handles real-time gameplay for Pidro games.

  Each game has its own channel identified by the room code (e.g., "game:A3F9").
  Players must be authenticated and part of the room to join the channel.

  ## Channel Topics

  * `"game:XXXX"` - Game-specific channel where XXXX is the room code

  ## Incoming Events (from client)

  * `"bid"` - Player makes a bid: `%{"amount" => 8}` or `%{"amount" => "pass"}`
  * `"declare_trump"` - Winner declares trump: `%{"suit" => "hearts"}`
  * `"play_card"` - Player plays a card: `%{"card" => %{"rank" => 14, "suit" => "spades"}}`
  * `"ready"` - Player signals ready to start (optional)

  ## Outgoing Events (to clients)

  * `"game_state"` - Full game state update: `%{state: game_state}`
  * `"player_joined"` - New player joined: `%{player_id: id, position: :north}`
  * `"player_left"` - Player left: `%{player_id: id}`
  * `"turn_changed"` - Current player changed: `%{current_player: :north}`
  * `"game_over"` - Game ended: `%{winner: :north_south, scores: %{...}}`
  * `"presence_state"` - Presence information (who's online)
  * `"presence_diff"` - Presence changes

  ## Examples

      # Join a game channel
      channel.join("game:A3F9", %{"token" => jwt_token})
        .receive("ok", ({state, position}) => console.log("Joined as", position))

      # Make a bid
      channel.push("bid", {amount: 8})
        .receive("ok", () => console.log("Bid accepted"))
        .receive("error", (error) => console.log("Error:", error))

      # Play a card
      channel.push("play_card", {card: {rank: 14, suit: "spades"}})

      # Listen for state updates
      channel.on("game_state", ({state}) => updateUI(state))
  """

  use PidroServerWeb, :channel
  require Logger

  alias PidroServer.Games.{RoomManager, GameAdapter}
  alias PidroServer.Stats
  alias PidroServerWeb.Presence

  # Intercept presence_diff and player_ready broadcasts to handle them explicitly
  intercept ["presence_diff", "player_ready"]

  @doc """
  Authorizes and joins a player to the game channel.

  Verifies that:
  1. The user is authenticated (user_id in socket assigns)
  2. The room exists
  3. The user is a player in the room
  4. The game process exists

  On successful join:
  - Subscribes to game updates via PubSub
  - Tracks presence
  - Returns initial game state and player position
  """
  @impl true
  def join("game:" <> room_code, _params, socket) do
    user_id = socket.assigns.user_id

    with {:ok, room} <- RoomManager.get_room(room_code),
         true <- user_in_room?(user_id, room),
         {:ok, _pid} <- GameAdapter.get_game(room_code),
         :ok <- GameAdapter.subscribe(room_code) do
      # Determine player position (order they joined the room)
      position = get_player_position(room, user_id)

      # Get initial game state
      {:ok, state} = GameAdapter.get_state(room_code)

      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:position, position)

      # Track presence after join
      send(self(), :after_join)

      {:ok, %{state: state, position: position}, socket}
    else
      {:error, :room_not_found} ->
        {:error, %{reason: "Room not found"}}

      {:error, :not_found} ->
        {:error, %{reason: "Game not started yet"}}

      false ->
        {:error, %{reason: "Not a player in this room"}}

      error ->
        Logger.error("Error joining game channel: #{inspect(error)}")
        {:error, %{reason: "Failed to join game"}}
    end
  end

  @doc """
  Handles game actions from players.

  Supports the following actions:
  - `"bid"` - Make a bid or pass
  - `"declare_trump"` - Declare trump suit (after winning bid)
  - `"play_card"` - Play a card from hand
  - `"ready"` - Signal ready status
  """
  @impl true
  def handle_in(event, params, socket)

  def handle_in("bid", %{"amount" => "pass"}, socket) do
    apply_game_action(socket, :pass)
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_integer(amount) do
    apply_game_action(socket, {:bid, amount})
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_binary(amount) do
    case Integer.parse(amount) do
      {num, _} -> apply_game_action(socket, {:bid, num})
      :error -> {:reply, {:error, %{reason: "Invalid bid amount"}}, socket}
    end
  end

  def handle_in("declare_trump", %{"suit" => suit}, socket) when is_binary(suit) do
    suit_atom = String.to_atom(suit)
    apply_game_action(socket, {:declare_trump, suit_atom})
  end

  def handle_in("play_card", %{"card" => %{"rank" => rank, "suit" => suit}}, socket) do
    suit_atom = String.to_atom(suit)
    card = {rank, suit_atom}
    apply_game_action(socket, {:play_card, card})
  end

  def handle_in("ready", _params, socket) do
    Logger.debug("Player #{socket.assigns.position} is ready")
    broadcast(socket, "player_ready", %{position: socket.assigns.position})
    {:reply, :ok, socket}
  end

  @doc """
  Handles internal messages and game events.

  Processes the following events:
  - `:state_update` - Game state changed
  - `:game_over` - Game completed
  - `:close_room` - Scheduled room closure
  - `:after_join` - Presence tracking after join
  """
  @impl true
  def handle_info(msg, socket)

  def handle_info({:state_update, new_state}, socket) do
    broadcast(socket, "game_state", %{state: new_state})
    {:noreply, socket}
  end

  def handle_info({:game_over, winner, scores}, socket) do
    room_code = socket.assigns.room_code

    # Update room status to finished
    RoomManager.update_room_status(room_code, :finished)

    # Save game stats
    save_game_stats(room_code, winner, scores)

    # Broadcast game over to all players
    broadcast(socket, "game_over", %{winner: winner, scores: scores})

    # Schedule room closure after 5 minutes
    Process.send_after(self(), {:close_room, room_code}, :timer.minutes(5))

    {:noreply, socket}
  end

  def handle_info({:close_room, room_code}, socket) do
    Logger.info("Closing room #{room_code} after game completion")
    RoomManager.close_room(room_code)
    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    {:ok, _} =
      Presence.track(socket, user_id, %{
        online_at: DateTime.utc_now() |> DateTime.to_unix(),
        position: socket.assigns.position
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @doc """
  Intercepts outgoing broadcasts.

  This is required when using Presence tracking in channels and for
  custom broadcast messages like player_ready.
  """
  @impl true
  def handle_out("presence_diff", msg, socket) do
    push(socket, "presence_diff", msg)
    {:noreply, socket}
  end

  def handle_out("player_ready", msg, socket) do
    push(socket, "player_ready", msg)
    {:noreply, socket}
  end

  ## Private Helpers

  @spec apply_game_action(Phoenix.Socket.t(), term()) ::
          {:reply, :ok | {:error, map()}, Phoenix.Socket.t()}
  defp apply_game_action(socket, action) do
    room_code = socket.assigns.room_code
    position = socket.assigns.position

    case GameAdapter.apply_action(room_code, position, action) do
      {:ok, _new_state} ->
        # State update is broadcast via PubSub subscription
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.debug("Action failed: #{inspect(reason)}")
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end

  @spec user_in_room?(String.t(), RoomManager.Room.t()) :: boolean()
  defp user_in_room?(user_id, room) do
    # Convert user_id to string if it's an integer
    user_id_str = to_string(user_id)
    Enum.any?(room.player_ids, fn id -> to_string(id) == user_id_str end)
  end

  @spec get_player_position(RoomManager.Room.t(), String.t()) :: atom()
  defp get_player_position(room, user_id) do
    # Positions are assigned in order: north, east, south, west
    positions = [:north, :east, :south, :west]
    user_id_str = to_string(user_id)

    # Find the index of the user in the player list
    index =
      Enum.find_index(room.player_ids, fn id -> to_string(id) == user_id_str end) || 0

    Enum.at(positions, index, :north)
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  @spec save_game_stats(String.t(), atom(), map()) :: :ok
  defp save_game_stats(room_code, winner, scores) do
    # Get room to extract player IDs and game start time
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        # Get game state to extract bid information
        game_state_result = GameAdapter.get_state(room_code)

        bid_info =
          case game_state_result do
            {:ok, state} ->
              # Extract bid and trump info from game state
              %{
                bid_amount: state[:bid_amount],
                bid_team: state[:bid_team]
              }

            _ ->
              %{bid_amount: nil, bid_team: nil}
          end

        # Calculate game duration (use current time - created_at as approximation)
        duration_seconds =
          DateTime.diff(DateTime.utc_now(), room.created_at, :second)

        # Prepare stats attributes
        stats_attrs = %{
          room_code: room_code,
          winner: winner,
          final_scores: scores,
          bid_amount: bid_info.bid_amount,
          bid_team: bid_info.bid_team,
          duration_seconds: duration_seconds,
          completed_at: DateTime.utc_now(),
          player_ids: room.player_ids
        }

        # Save to database
        case Stats.save_game_result(stats_attrs) do
          {:ok, _stats} ->
            Logger.info("Saved game stats for room #{room_code}")
            :ok

          {:error, changeset} ->
            Logger.error("Failed to save game stats for room #{room_code}: #{inspect(changeset)}")
            :ok
        end

      {:error, _} ->
        Logger.error("Could not find room #{room_code} to save stats")
        :ok
    end
  end
end
