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
  * `"select_hand"` - Dealer selects cards to keep: `%{"cards" => [%{"rank" => 14, "suit" => "hearts"}, ...]}`
  * `"ready"` - Player signals ready to start (optional)

  ## Outgoing Events (to clients)

  * `"game_state"` - Full game state update: `%{state: game_state, transition_delay_ms: integer()}`
  * `"player_joined"` - New player joined: `%{player_id: id, position: :north}`
  * `"player_left"` - Player left: `%{player_id: id}`
  * `"player_disconnected"` - Player disconnected: `%{user_id: id, position: :north, reason: "left"}`
  * `"player_reconnected"` - Player reconnected: `%{user_id: id, position: position}`
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

  alias PidroServer.Games.{GameAdapter, PresenceAggregator, RoomManager}
  alias PidroServer.Games.Room.Seat
  alias PidroServerWeb.Presence
  alias PidroServerWeb.Serializers.GameStateSerializer

  @suit_map %{
    "hearts" => :hearts,
    "diamonds" => :diamonds,
    "clubs" => :clubs,
    "spades" => :spades
  }

  # Intercept presence_diff, player_ready, and player_reconnected broadcasts to handle them explicitly
  intercept ["presence_diff", "player_ready", "player_reconnected", "player_disconnected"]

  @doc """
  Authorizes and joins a player or spectator to the game channel.

  Verifies that:
  1. The user is authenticated (user_id in socket assigns)
  2. The room exists
  3. The user is either a player or spectator in the room
  4. The game process exists

  On successful join:
  - Detects and handles reconnection attempts if player was previously disconnected
  - Subscribes to game updates via PubSub
  - Tracks presence with role (player or spectator)
  - Returns initial game state and role-specific information
  """
  @impl true
  def join("game:" <> room_code, _params, socket) do
    user_id = socket.assigns.user_id

    # First, check if this is a reconnection attempt
    with {:ok, room} <- RoomManager.get_room(room_code) do
      # Determine user role (player or spectator)
      role = determine_user_role(room, user_id)

      case role do
        :player ->
          join_player(room_code, user_id, socket)

        :substitute ->
          # Stranger joining a :playing room with a vacant seat
          case RoomManager.join_as_substitute(room_code, user_id) do
            {:ok, _updated_room, _position} ->
              proceed_with_join(room_code, user_id, socket, :new, :player)

            {:error, reason} ->
              Logger.warning("Substitute join failed for #{user_id}: #{inspect(reason)}")
              {:error, %{reason: "substitute join failed: #{format_error(reason)}"}}
          end

        :spectator ->
          # Spectators join directly without reconnection logic
          proceed_with_join(room_code, user_id, socket, :new, :spectator)

        :unauthorized ->
          {:error, %{reason: "not authorized to join this room"}}
      end
    else
      _ -> {:error, %{reason: "room not found"}}
    end
  end

  defp join_player(room_code, user_id, socket) do
    with :ok <- ensure_player_channel_registered(room_code, user_id),
         {:ok, room} <- RoomManager.get_room(room_code) do
      result =
        cond do
          is_reconnection?(room, user_id) ->
            attempt_player_reconnect(room_code, user_id, socket)

          is_permanently_botted?(room, user_id) ->
            {:error, %{reason: "seat permanently filled by bot"}}

          true ->
            proceed_with_join(room_code, user_id, socket, :new, :player)
        end

      cleanup_failed_player_join(room_code, user_id, result)
    else
      {:error, :room_not_found} ->
        cleanup_failed_player_join(room_code, user_id, {:error, %{reason: "room not found"}})
    end
  end

  defp ensure_player_channel_registered(room_code, user_id) do
    case RoomManager.register_game_channel(room_code, user_id, self()) do
      :ok -> :ok
      {:error, :room_not_found} -> {:error, :room_not_found}
    end
  end

  defp attempt_player_reconnect(room_code, user_id, socket) do
    case RoomManager.handle_player_reconnect(room_code, user_id) do
      {:ok, updated_room} ->
        Logger.info("Player #{user_id} reconnected to room #{room_code}")

        position = get_player_position(updated_room, user_id)
        send(self(), {:broadcast_reconnection, user_id, position})

        proceed_with_join(room_code, user_id, socket, :reconnect, :player)

      {:error, :seat_permanently_filled} ->
        {:error, %{reason: "seat permanently filled by bot"}}

      {:error, :grace_period_expired} ->
        {:error, %{reason: "reconnection grace period expired"}}

      {:error, reason} ->
        Logger.warning("Reconnection failed for #{user_id}: #{inspect(reason)}")
        {:error, %{reason: "reconnection failed: #{format_error(reason)}"}}
    end
  end

  defp cleanup_failed_player_join(_room_code, _user_id, {:ok, _reply_data, _socket} = result),
    do: result

  defp cleanup_failed_player_join(room_code, user_id, result) do
    case RoomManager.unregister_game_channel(room_code, user_id, self()) do
      :last_channel_closed -> :ok
      :channels_remaining -> :ok
      :not_registered -> :ok
    end

    result
  end

  # Extract the common join logic into a helper function
  defp proceed_with_join(room_code, user_id, socket, join_type, role) do
    with {:ok, room} <- RoomManager.get_room(room_code),
         true <- user_authorized?(user_id, room, role) do
      # Subscribe to game PubSub eagerly - works even if game hasn't started yet.
      # When the game starts later, state updates will arrive via this subscription.
      :ok = GameAdapter.subscribe(room_code)

      # Position only applies to players, not spectators
      position = if role == :player, do: get_player_position(room, user_id), else: nil

      # Try to get current game state (may not exist if game hasn't started)
      {serialized_state, legal_actions} = fetch_game_state(room_code, position)

      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:position, position)
        |> assign(:role, role)
        |> assign(:join_type, join_type)

      if role == :player do
        :ok = RoomManager.register_game_channel(room_code, user_id, self())
      end

      # Track presence after join
      send(self(), :after_join)

      {:ok, turn_timer} = RoomManager.get_turn_timer(room_code)

      reply_data = %{
        role: role,
        reconnected: join_type == :reconnect,
        legal_actions: legal_actions,
        turn_timer: turn_timer
      }

      # Add state only if game has started
      reply_data =
        if serialized_state, do: Map.put(reply_data, :state, serialized_state), else: reply_data

      # Add position only for players
      reply_data = if position, do: Map.put(reply_data, :position, position), else: reply_data

      {:ok, reply_data, socket}
    else
      {:error, :room_not_found} ->
        {:error, %{reason: "Room not found"}}

      false ->
        {:error, %{reason: "Not authorized for this room"}}

      error ->
        Logger.error("Error joining game channel: #{inspect(error)}")
        {:error, %{reason: "Failed to join game"}}
    end
  end

  defp fetch_game_state(room_code, position) do
    case GameAdapter.get_game(room_code) do
      {:ok, _pid} ->
        {:ok, state} = GameAdapter.get_state(room_code)
        serialized = GameStateSerializer.serialize(state)

        actions =
          if position do
            case GameAdapter.get_legal_actions(room_code, position) do
              {:ok, a} -> GameStateSerializer.serialize_legal_actions(a)
              _ -> []
            end
          else
            []
          end

        {serialized, actions}

      {:error, :not_found} ->
        {nil, []}
    end
  end

  @doc """
  Handles game actions from players.

  Supports the following actions:
  - `"bid"` - Make a bid or pass (players only)
  - `"declare_trump"` - Declare trump suit (players only)
  - `"play_card"` - Play a card from hand (players only)
  - `"select_hand"` - Select cards to keep during dealer rob (players only)
  - `"ready"` - Signal ready status (players only)

  Spectators cannot perform game actions and will receive an error.
  """
  @impl true
  def handle_in(event, params, socket)

  def handle_in("bid", %{"amount" => "pass"}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot make bids"}}, socket}
    else
      apply_game_action(socket, :pass)
    end
  end

  def handle_in("pass", _params, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot make bids"}}, socket}
    else
      apply_game_action(socket, :pass)
    end
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_integer(amount) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot make bids"}}, socket}
    else
      apply_game_action(socket, {:bid, amount})
    end
  end

  def handle_in("bid", %{"amount" => amount}, socket) when is_binary(amount) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot make bids"}}, socket}
    else
      case Integer.parse(amount) do
        {num, _} -> apply_game_action(socket, {:bid, num})
        :error -> {:reply, {:error, %{reason: "Invalid bid amount"}}, socket}
      end
    end
  end

  def handle_in("declare_trump", %{"suit" => suit}, socket) when is_binary(suit) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot declare trump"}}, socket}
    else
      case parse_suit(suit) do
        {:ok, suit_atom} ->
          apply_game_action(socket, {:declare_trump, suit_atom})

        :error ->
          {:reply, {:error, %{reason: "invalid suit"}}, socket}
      end
    end
  end

  def handle_in("play_card", %{"card" => %{"rank" => rank, "suit" => suit}}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot play cards"}}, socket}
    else
      with {:ok, suit_atom} <- parse_suit(suit),
           true <- is_integer(rank) do
        card = {rank, suit_atom}
        apply_game_action(socket, {:play_card, card})
      else
        false ->
          {:reply, {:error, %{reason: "invalid card rank"}}, socket}

        :error ->
          {:reply, {:error, %{reason: "invalid card suit"}}, socket}
      end
    end
  end

  def handle_in("select_hand", %{"cards" => cards}, socket) when is_list(cards) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot select hand"}}, socket}
    else
      case parse_cards(cards) do
        {:ok, card_tuples} ->
          apply_game_action(socket, {:select_hand, card_tuples})

        {:error, reason} ->
          {:reply, {:error, %{reason: reason}}, socket}
      end
    end
  end

  def handle_in("ready", _params, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot signal ready"}}, socket}
    else
      Logger.debug("Player #{socket.assigns.position} is ready")
      broadcast(socket, "player_ready", %{position: socket.assigns.position})
      {:reply, :ok, socket}
    end
  end

  def handle_in("open_seat", %{"position" => position}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot manage seats"}}, socket}
    else
      case parse_position(position) do
        {:ok, pos_atom} ->
          case RoomManager.open_seat(socket.assigns.room_code, pos_atom, socket.assigns.user_id) do
            {:ok, _room} -> {:reply, :ok, socket}
            {:error, reason} -> {:reply, {:error, %{reason: format_error(reason)}}, socket}
          end

        :error ->
          {:reply, {:error, %{reason: "invalid position"}}, socket}
      end
    end
  end

  def handle_in("close_seat", %{"position" => position}, socket) do
    if socket.assigns[:role] == :spectator do
      {:reply, {:error, %{reason: "spectators cannot manage seats"}}, socket}
    else
      case parse_position(position) do
        {:ok, pos_atom} ->
          case RoomManager.close_seat(socket.assigns.room_code, pos_atom, socket.assigns.user_id) do
            {:ok, _room} -> {:reply, :ok, socket}
            {:error, reason} -> {:reply, {:error, %{reason: format_error(reason)}}, socket}
          end

        :error ->
          {:reply, {:error, %{reason: "invalid position"}}, socket}
      end
    end
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

  def handle_info(
        {:state_update, room_code, payload},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    case extract_state_update(payload) do
      {:ok, new_state, delay_ms} ->
        serialized_state = GameStateSerializer.serialize(new_state)
        legal_actions = legal_actions_for_socket(socket)

        push(socket, "game_state", %{
          state: serialized_state,
          legal_actions: legal_actions,
          transition_delay_ms: delay_ms
        })

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:game_over, room_code, winner, scores},
        %{assigns: %{room_code: room_code}} = socket
      ) do
    # Broadcast game over to all players
    push(socket, "game_over", %{winner: winner, scores: scores})

    # Schedule room closure after 5 minutes
    Process.send_after(self(), {:close_room, room_code}, :timer.minutes(5))

    {:noreply, socket}
  end

  def handle_info({:turn_timer_started, payload}, socket) do
    push(socket, "turn_timer_started", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_timer_cancelled, payload}, socket) do
    push(socket, "turn_timer_cancelled", payload)
    {:noreply, socket}
  end

  def handle_info({:turn_auto_played, payload}, socket) do
    push(socket, "turn_auto_played", payload)
    {:noreply, socket}
  end

  def handle_info({:force_disconnect, :timeout_threshold}, socket) do
    push(socket, "force_disconnect", %{reason: "timeout_threshold"})
    {:stop, {:shutdown, :timeout_threshold}, socket}
  end

  def handle_info({:close_room, room_code}, socket) do
    Logger.info("Closing room #{room_code} after game completion")
    RoomManager.close_room(room_code)
    {:noreply, socket}
  end

  # Disconnect cascade PubSub events — push to client for UI updates
  def handle_info({:player_reconnecting, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reconnecting", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:player_reconnected, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reconnected", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:player_reclaimed_seat, %{user_id: user_id, position: position}}, socket) do
    push(socket, "player_reclaimed_seat", %{user_id: user_id, position: position})
    {:noreply, socket}
  end

  def handle_info({:bot_substitute_active, %{position: position, user_id: user_id}}, socket) do
    push(socket, "bot_substitute_active", %{position: position, user_id: user_id})
    {:noreply, socket}
  end

  def handle_info({:seat_permanently_botted, %{position: position}}, socket) do
    push(socket, "seat_permanently_botted", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:owner_decision_available, %{position: position, owner_id: owner_id}}, socket) do
    push(socket, "owner_decision_available", %{position: position, owner_id: owner_id})
    {:noreply, socket}
  end

  def handle_info(
        {:owner_changed, %{new_owner_id: new_owner_id, new_owner_position: new_owner_position}},
        socket
      ) do
    push(socket, "owner_changed", %{
      new_owner_id: new_owner_id,
      new_owner_position: new_owner_position
    })

    {:noreply, socket}
  end

  def handle_info({:substitute_available, %{position: position}}, socket) do
    push(socket, "substitute_available", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:substitute_seat_closed, %{position: position}}, socket) do
    push(socket, "substitute_seat_closed", %{position: position})
    {:noreply, socket}
  end

  def handle_info({:substitute_joined, %{position: position, user_id: user_id}}, socket) do
    push(socket, "substitute_joined", %{position: position, user_id: user_id})
    {:noreply, socket}
  end

  def handle_info({:broadcast_reconnection, user_id, position}, socket) do
    broadcast_from(socket, "player_reconnected", %{
      user_id: user_id,
      position: position
    })

    {:noreply, socket}
  end

  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id
    role = socket.assigns.role

    presence_data = %{
      online_at: DateTime.utc_now() |> DateTime.to_unix(),
      role: role
    }

    # Add position only for players
    presence_data =
      if socket.assigns.position do
        Map.put(presence_data, :position, socket.assigns.position)
      else
        presence_data
      end

    {:ok, _} = Presence.track(socket, user_id, presence_data)

    activity = if role == :spectator, do: :spectating, else: :playing
    PresenceAggregator.track(user_id, activity)

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

  def handle_out("player_reconnected", msg, socket) do
    push(socket, "player_reconnected", msg)
    {:noreply, socket}
  end

  def handle_out("player_disconnected", msg, socket) do
    push(socket, "player_disconnected", msg)
    {:noreply, socket}
  end

  @doc """
  Handles player or spectator disconnection from the channel.

  Called automatically when a user's channel connection terminates.
  This ensures proper cleanup and notification of other users.

  ## Actions performed:

  1. Extracts room_code, user_id, and role from socket assigns
  2. Notifies RoomManager about the disconnect (players only)
  3. Spectators are removed immediately
  4. Broadcasts disconnect event to other users in the channel

  ## Disconnect reasons:

  - `:normal` - Clean disconnect (e.g., user closed tab)
  - `:shutdown` - Server shutdown or connection lost
  - `{:shutdown, _}` - Forced disconnect
  - Other reasons are treated as errors
  """
  @impl true
  def terminate(reason, socket) do
    room_code = socket.assigns[:room_code]
    user_id = socket.assigns[:user_id]
    role = socket.assigns[:role]

    # Only handle disconnect if we have necessary assigns
    if room_code && user_id && role do
      case role do
        :player ->
          Logger.info(
            "Player #{user_id} disconnected from room #{room_code}: #{format_reason(reason)}"
          )

          last_channel_closed? =
            case RoomManager.unregister_game_channel(room_code, user_id, self()) do
              :last_channel_closed ->
                true

              :channels_remaining ->
                false

              :not_registered ->
                false
            end

          if last_channel_closed? do
            case RoomManager.handle_player_disconnect(room_code, user_id) do
              :ok -> :ok
              error -> Logger.warning("Failed to handle disconnect: #{inspect(error)}")
            end

            # Broadcast to other users in the game channel
            broadcast_from(socket, "player_disconnected", %{
              user_id: user_id,
              position: socket.assigns[:position],
              reason: format_reason(reason),
              grace_period: true
            })
          end

        :spectator ->
          Logger.info(
            "Spectator #{user_id} disconnected from room #{room_code}: #{format_reason(reason)}"
          )

          # Remove spectator immediately (no reconnection grace period)
          RoomManager.leave_spectator(user_id)

          # Broadcast to other users in the game channel
          broadcast_from(socket, "spectator_left", %{
            user_id: user_id,
            reason: format_reason(reason)
          })
      end
    end

    :ok
  end

  ## Private Helpers

  @spec apply_game_action(Phoenix.Socket.t(), term()) ::
          {:reply, :ok | {:error, map()}, Phoenix.Socket.t()}
  defp apply_game_action(socket, action) do
    room_code = socket.assigns.room_code
    position = socket.assigns.position

    case GameAdapter.apply_action(room_code, position, action) do
      {:ok, _new_state} ->
        _ = RoomManager.reset_consecutive_timeouts(room_code, socket.assigns.user_id)
        # State update is broadcast via PubSub subscription
        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.debug("Action failed: #{inspect(reason)}")
        {:reply, {:error, %{reason: format_error(reason)}}, socket}
    end
  end

  @spec user_in_room?(String.t(), RoomManager.Room.t()) :: boolean()
  defp user_in_room?(user_id, room) do
    alias PidroServer.Games.Room.Positions
    # Convert user_id to string if it's an integer
    user_id_str = to_string(user_id)
    Positions.has_player?(room, user_id_str)
  end

  @spec user_authorized?(String.t(), RoomManager.Room.t(), atom()) :: boolean()
  defp user_authorized?(user_id, room, :player) do
    user_in_room?(user_id, room)
  end

  defp user_authorized?(user_id, room, :spectator) do
    user_id_str = to_string(user_id)
    Enum.any?(room.spectator_ids, fn id -> to_string(id) == user_id_str end)
  end

  # Phase 3: seat is a permanent bot (reserved_for cleared) but positions
  # still contains the original user_id. Without this guard, the player
  # would slip through as a normal join instead of being rejected.
  @spec is_permanently_botted?(RoomManager.Room.t(), String.t()) :: boolean()
  defp is_permanently_botted?(room, user_id) do
    alias PidroServer.Games.Room.Positions

    case Positions.get_position(room, user_id) do
      nil ->
        false

      position ->
        seat = Map.get(room.seats, position)
        seat != nil && seat.status == :bot_substitute && seat.reserved_for == nil
    end
  end

  @spec is_reconnection?(RoomManager.Room.t(), String.t()) :: boolean()
  defp is_reconnection?(room, user_id) do
    # Check seat-based disconnect cascade:
    # Phase 1 (:reconnecting) — user_id still on seat
    # Phase 2/3 (:bot_substitute with reserved_for) — user_id cleared from seat but reserved_for still set
    Enum.any?(room.seats || %{}, fn {_pos, seat} ->
      seat.reserved_for == user_id ||
        (seat.status == :reconnecting && seat.user_id == user_id)
    end)
  end

  @spec determine_user_role(RoomManager.Room.t(), String.t()) ::
          :player | :substitute | :spectator | :unauthorized
  defp determine_user_role(room, user_id) do
    alias PidroServer.Games.Room.Positions
    user_id_str = to_string(user_id)

    cond do
      Positions.has_player?(room, user_id_str) ->
        :player

      # Player whose seat was taken by a bot still has reserved_for set
      Seat.reserved_for_user?(room.seats || %{}, user_id_str) ->
        :player

      # In a :playing room, vacant seats can only exist via Seat.open_for_substitute/1,
      # which requires the owner to explicitly open them. Safe to grant :substitute role.
      room.status == :playing && Seat.any_vacant?(room.seats || %{}) ->
        :substitute

      Enum.any?(room.spectator_ids, fn id -> to_string(id) == user_id_str end) ->
        :spectator

      true ->
        :unauthorized
    end
  end

  @spec get_player_position(RoomManager.Room.t(), String.t()) :: atom()
  defp get_player_position(room, user_id) do
    alias PidroServer.Games.Room.Positions
    user_id_str = to_string(user_id)
    Positions.get_position(room, user_id_str) || :north
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  @spec legal_actions_for_socket(Phoenix.Socket.t()) :: list()
  defp legal_actions_for_socket(socket) do
    position = socket.assigns[:position]
    room_code = socket.assigns[:room_code]

    if position && room_code do
      case GameAdapter.get_legal_actions(room_code, position) do
        {:ok, actions} -> GameStateSerializer.serialize_legal_actions(actions)
        _ -> []
      end
    else
      []
    end
  end

  @position_map %{
    "north" => :north,
    "south" => :south,
    "east" => :east,
    "west" => :west
  }

  @spec parse_position(String.t()) :: {:ok, atom()} | :error
  defp parse_position(position) when is_binary(position) do
    Map.fetch(@position_map, position)
  end

  @spec parse_suit(String.t()) :: {:ok, atom()} | :error
  defp parse_suit(suit) when is_binary(suit) do
    Map.fetch(@suit_map, suit)
  end

  @spec parse_cards(list()) :: {:ok, list({integer(), atom()})} | {:error, String.t()}
  defp parse_cards(cards) when is_list(cards) do
    Enum.reduce_while(cards, {:ok, []}, fn
      %{"rank" => rank, "suit" => suit}, {:ok, acc} when is_integer(rank) ->
        case parse_suit(suit) do
          {:ok, suit_atom} -> {:cont, {:ok, [{rank, suit_atom} | acc]}}
          :error -> {:halt, {:error, "invalid card suit"}}
        end

      _, _acc ->
        {:halt, {:error, "invalid card payload"}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(:normal), do: "left"
  defp format_reason({:shutdown, :left}), do: "left"
  defp format_reason({:shutdown, :timeout_threshold}), do: "timeout"
  defp format_reason(:shutdown), do: "connection_lost"
  defp format_reason({:shutdown, _}), do: "connection_lost"
  defp format_reason(_), do: "error"

  defp extract_state_update(%{state: game_state, transition_delay_ms: delay_ms})
       when is_map(game_state) and is_integer(delay_ms),
       do: {:ok, game_state, delay_ms}

  defp extract_state_update(%{state: game_state}) when is_map(game_state),
    do: {:ok, game_state, 0}

  defp extract_state_update(game_state) when is_map(game_state), do: {:ok, game_state, 0}
  defp extract_state_update(_payload), do: :error
end
