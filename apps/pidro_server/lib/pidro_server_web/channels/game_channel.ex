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
  alias PidroServer.Accounts
  alias PidroServerWeb.Presence

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
  Handles the bid action from a player.

  Players can either bid an amount (6-14) or pass.

  ## Message Format

      %{"amount" => 8}        # Bid 8 points
      %{"amount" => "pass"}   # Pass on bidding
  """
  @impl true
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

  @doc """
  Handles the declare_trump action from the bid winner.

  ## Message Format

      %{"suit" => "hearts"}
      %{"suit" => "diamonds"}
      %{"suit" => "clubs"}
      %{"suit" => "spades"}
  """
  @impl true
  def handle_in("declare_trump", %{"suit" => suit}, socket) when is_binary(suit) do
    suit_atom = String.to_atom(suit)
    apply_game_action(socket, {:declare_trump, suit_atom})
  end

  @doc """
  Handles the play_card action from a player.

  ## Message Format

      %{"card" => %{"rank" => 14, "suit" => "spades"}}

  Rank values: 2-14 (where 14 = Ace, 13 = King, 12 = Queen, 11 = Jack)
  """
  @impl true
  def handle_in("play_card", %{"card" => %{"rank" => rank, "suit" => suit}}, socket) do
    suit_atom = String.to_atom(suit)
    card = {rank, suit_atom}
    apply_game_action(socket, {:play_card, card})
  end

  @doc """
  Handles the ready signal from a player.

  This is optional and could be used to signal that a player is ready to start
  or ready for the next round.
  """
  @impl true
  def handle_in("ready", _params, socket) do
    Logger.debug("Player #{socket.assigns.position} is ready")
    broadcast(socket, "player_ready", %{position: socket.assigns.position})
    {:reply, :ok, socket}
  end

  @doc """
  Handles state updates broadcast from the game engine via PubSub.

  When the game state changes, this receives the update and broadcasts
  it to all players in the channel.
  """
  @impl true
  def handle_info({:state_update, new_state}, socket) do
    broadcast(socket, "game_state", %{state: new_state})
    {:noreply, socket}
  end

  @doc """
  Handles game over events from the game engine.

  Broadcasts the final results to all players.
  """
  @impl true
  def handle_info({:game_over, winner, scores}, socket) do
    broadcast(socket, "game_over", %{winner: winner, scores: scores})
    {:noreply, socket}
  end

  @doc """
  Tracks presence after a player joins.

  This is delayed until after join completes to ensure the socket
  is fully initialized.
  """
  @impl true
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
end
