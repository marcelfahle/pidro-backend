defmodule PidroServerWeb.Dev.GameDetailLive do
  @moduledoc """
  Development UI for detailed game state viewing and interaction.

  This LiveView provides:
  - Real-time game state display
  - Position-based filtering (implemented in DEV-401)
  - Action execution capabilities (implemented in DEV-901 to DEV-904)
  - Raw state inspection with clipboard support (implemented in DEV-801)

  Unlike GameMonitorLive (read-only monitoring), this view is designed
  for active development and debugging with interactive controls.
  """

  use PidroServerWeb, :live_view
  require Logger
  alias PidroServer.Dev.{BotManager, Event, EventRecorder, GameHelpers, ReplayController}
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServerWeb.CardComponents

  @impl true
  def mount(%{"code" => room_code}, _session, socket) do
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        if connected?(socket) do
          # Subscribe to game updates for this specific room
          Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

          # Start event recorder for this game
          case DynamicSupervisor.start_child(
                 PidroServer.Dev.BotSupervisor,
                 {EventRecorder, room_code: room_code}
               ) do
            {:ok, _pid} ->
              Logger.debug("EventRecorder started for #{room_code}")

            {:error, {:already_started, _pid}} ->
              Logger.debug("EventRecorder already running for #{room_code}")

            {:error, reason} ->
              Logger.error("Failed to start EventRecorder: #{inspect(reason)}")
          end
        end

        # Get initial game state
        game_state = get_game_state(room_code)

        # DEV-901: Fetch legal actions for initial position
        legal_actions = get_legal_actions(room_code, :all)

        # DEV-1106: Initialize bot configuration
        bot_configs = initialize_bot_configs(room_code)

        # DEV-1301: Initialize replay state
        {:ok, event_count} = ReplayController.get_event_count(room_code)

        {:ok,
         socket
         |> assign(:room, room)
         |> assign(:room_code, room_code)
         |> assign(:game_state, game_state)
         |> assign(:selected_position, :all)
         |> assign(:view_mode, :single)
         |> assign(:legal_actions, legal_actions)
         |> assign(:executing_action, false)
         |> assign(:copy_feedback, false)
         |> assign(:bot_configs, bot_configs)
         |> assign(:events, EventRecorder.get_events(room_code, limit: 50))
         |> assign(:event_filter_type, nil)
         |> assign(:event_filter_player, nil)
         |> assign(:show_bot_reasoning, true)
         |> assign(:show_event_export, false)
         |> assign(:replay_mode, false)
         |> assign(:replay_index, event_count - 1)
         |> assign(:replay_total_events, event_count)
         |> assign(:replay_playing, false)
         |> assign(:replay_speed, 1000)
         |> assign(:page_title, "Game Detail - Dev")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Room not found")
         |> redirect(to: ~p"/dev/games")}
    end
  end

  @impl true
  def handle_info({:state_update, new_state}, socket) do
    # DEV-901: Refetch legal actions when state updates
    legal_actions = get_legal_actions(socket.assigns.room_code, socket.assigns.selected_position)
    events = EventRecorder.get_events(socket.assigns.room_code, limit: 50)

    {:noreply,
     socket
     |> assign(:game_state, new_state)
     |> assign(:legal_actions, legal_actions)
     |> assign(:events, events)}
  end

  @impl true
  def handle_info({:game_over, _winner, _scores}, socket) do
    # Reload the game state to get the final state
    game_state = get_game_state(socket.assigns.room_code)

    {:noreply,
     socket
     |> assign(:game_state, game_state)
     |> assign(:legal_actions, [])
     |> put_flash(:info, "Game Over!")}
  end

  @impl true
  def handle_info({:room_updated, room}, socket) do
    {:noreply, assign(socket, :room, room)}
  end

  @impl true
  def handle_info({:auto_bid_complete, :success}, socket) do
    {:noreply, put_flash(socket, :info, "Auto-bidding completed successfully")}
  end

  @impl true
  def handle_info({:auto_bid_complete, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "Auto-bidding failed: #{reason}")}
  end

  @impl true
  def handle_event("clipboard_copied", _params, socket) do
    {:noreply, assign(socket, :copy_feedback, true)}
  end

  @impl true
  def handle_event("reset_clipboard_feedback", _params, socket) do
    {:noreply, assign(socket, :copy_feedback, false)}
  end

  @impl true
  def handle_event("select_position", %{"position" => position}, socket) do
    position_atom =
      case position do
        "north" -> :north
        "south" -> :south
        "east" -> :east
        "west" -> :west
        "all" -> :all
        _ -> :all
      end

    # DEV-901: Fetch legal actions when position changes
    legal_actions = get_legal_actions(socket.assigns.room_code, position_atom)

    {:noreply,
     socket
     |> assign(:selected_position, position_atom)
     |> assign(:legal_actions, legal_actions)}
  end

  @impl true
  def handle_event("toggle_view_mode", _params, socket) do
    # DEV-502: Toggle between single and split view
    new_mode =
      case socket.assigns.view_mode do
        :single -> :split
        :split -> :single
      end

    {:noreply, assign(socket, :view_mode, new_mode)}
  end

  @impl true
  def handle_event("update_bot_config", params, socket) do
    # DEV-1106: Update bot configuration in assigns
    position = String.to_existing_atom(params["position"])
    bot_configs = socket.assigns.bot_configs

    updated_config =
      Map.update!(bot_configs, position, fn config ->
        config
        |> maybe_update_type(params)
        |> maybe_update_difficulty(params)
        |> maybe_update_delay(params)
      end)

    {:noreply, assign(socket, :bot_configs, updated_config)}
  end

  @impl true
  def handle_event("apply_bot_config", _params, socket) do
    # DEV-1106: Apply bot configuration changes
    room_code = socket.assigns.room_code
    bot_configs = socket.assigns.bot_configs

    # Process each position
    Enum.each([:north, :south, :east, :west], fn position ->
      config = Map.get(bot_configs, position)
      apply_position_config(room_code, position, config)
    end)

    {:noreply, put_flash(socket, :info, "Bot configuration applied successfully")}
  end

  @impl true
  def handle_event("toggle_bot_pause", %{"position" => position}, socket) do
    # DEV-1106: Pause or resume a specific bot
    position_atom = String.to_existing_atom(position)
    room_code = socket.assigns.room_code
    bot_configs = socket.assigns.bot_configs

    config = Map.get(bot_configs, position_atom)

    result =
      if config.paused do
        BotManager.resume_bot(room_code, position_atom)
      else
        BotManager.pause_bot(room_code, position_atom)
      end

    socket =
      case result do
        :ok ->
          # Update the paused state
          updated_configs =
            Map.update!(bot_configs, position_atom, fn c ->
              %{c | paused: !c.paused}
            end)

          socket
          |> assign(:bot_configs, updated_configs)
          |> put_flash(
            :info,
            "Bot #{position} #{if config.paused, do: "resumed", else: "paused"}"
          )

        {:error, :not_found} ->
          put_flash(socket, :error, "Bot not found for position #{position}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_action", %{"action" => action_json}, socket) do
    # DEV-903: Execute action implementation
    socket = assign(socket, :executing_action, true)
    position = socket.assigns.selected_position
    room_code = socket.assigns.room_code

    case decode_action(action_json) do
      {:ok, action} ->
        # Apply the action
        case GameAdapter.apply_action(room_code, position, action) do
          {:ok, _new_state} ->
            # Refetch game state and legal actions
            game_state = get_game_state(room_code)
            legal_actions = get_legal_actions(room_code, position)

            {:noreply,
             socket
             |> assign(:game_state, game_state)
             |> assign(:legal_actions, legal_actions)
             |> assign(:executing_action, false)
             |> put_flash(:info, "Action executed successfully: #{format_action(action)}")}

          {:error, reason} ->
            # DEV-904: Error handling
            error_message = format_error(reason)
            Logger.error("Action execution failed: #{error_message}")

            {:noreply,
             socket
             |> assign(:executing_action, false)
             |> put_flash(:error, "Action failed: #{error_message}")}
        end

      {:error, error_message} ->
        # DEV-904: Exception handling
        Logger.error("Exception executing action: #{error_message}")

        {:noreply,
         socket
         |> assign(:executing_action, false)
         |> put_flash(:error, "Action failed: #{error_message}")}
    end
  end

  @impl true
  def handle_event("play_card", %{"card" => card_string}, socket) do
    # DEV-1505: Handle card click from card table
    position = socket.assigns.selected_position
    room_code = socket.assigns.room_code

    # Don't allow actions in god mode
    if position == :all do
      {:noreply, put_flash(socket, :error, "Select a specific position to play cards")}
    else
      # Decode card from string format "rank:suit"
      card = PidroServerWeb.CardHelpers.decode_card(card_string)
      action = {:play_card, card}

      socket = assign(socket, :executing_action, true)

      case GameAdapter.apply_action(room_code, position, action) do
        {:ok, _new_state} ->
          game_state = get_game_state(room_code)
          legal_actions = get_legal_actions(room_code, position)

          {:noreply,
           socket
           |> assign(:game_state, game_state)
           |> assign(:legal_actions, legal_actions)
           |> assign(:executing_action, false)
           |> put_flash(:info, "Played #{PidroServerWeb.CardHelpers.format_card(card)}")}

        {:error, reason} ->
          error_message = format_error(reason)
          Logger.error("Card play failed: #{error_message}")

          {:noreply,
           socket
           |> assign(:executing_action, false)
           |> put_flash(:error, "Cannot play card: #{error_message}")}
      end
    end
  end

  @impl true
  def handle_event("refresh_events", _params, socket) do
    events =
      EventRecorder.get_events(socket.assigns.room_code,
        limit: 50,
        type: socket.assigns.event_filter_type,
        player: socket.assigns.event_filter_player
      )

    {:noreply, assign(socket, :events, events)}
  end

  @impl true
  def handle_event("filter_events", %{"type" => type}, socket) do
    type_atom = if type == "all", do: nil, else: String.to_existing_atom(type)

    events =
      EventRecorder.get_events(socket.assigns.room_code,
        limit: 50,
        type: type_atom,
        player: socket.assigns.event_filter_player
      )

    {:noreply,
     socket
     |> assign(:event_filter_type, type_atom)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("filter_events_by_player", %{"player" => player}, socket) do
    player_atom = if player == "all", do: nil, else: String.to_existing_atom(player)

    events =
      EventRecorder.get_events(socket.assigns.room_code,
        limit: 50,
        type: socket.assigns.event_filter_type,
        player: player_atom
      )

    {:noreply,
     socket
     |> assign(:event_filter_player, player_atom)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("clear_events", _params, socket) do
    EventRecorder.clear_events(socket.assigns.room_code)

    {:noreply,
     socket
     |> assign(:events, [])
     |> put_flash(:info, "Event log cleared")}
  end

  @impl true
  def handle_event("toggle_bot_reasoning", _params, socket) do
    # Toggle bot reasoning visibility and refresh events
    new_value = !socket.assigns.show_bot_reasoning
    events = get_filtered_events(socket.assigns, new_value)

    {:noreply,
     socket
     |> assign(:show_bot_reasoning, new_value)
     |> assign(:events, events)}
  end

  @impl true
  def handle_event("toggle_export_modal", _params, socket) do
    {:noreply, assign(socket, :show_event_export, !socket.assigns.show_event_export)}
  end

  @impl true
  def handle_event("export_events_json", _params, socket) do
    # This will be handled by a LiveView hook for downloading
    {:noreply, socket}
  end

  @impl true
  def handle_event("undo_last_action", _params, socket) do
    # DEV-1001: Undo last action
    room_code = socket.assigns.room_code

    case GameAdapter.undo(room_code) do
      {:ok, previous_state} ->
        # Refetch legal actions
        legal_actions = get_legal_actions(room_code, socket.assigns.selected_position)

        {:noreply,
         socket
         |> assign(:game_state, previous_state)
         |> assign(:legal_actions, legal_actions)
         |> put_flash(:info, "Action undone successfully")}

      {:error, :no_history} ->
        {:noreply, put_flash(socket, :error, "No actions to undo")}

      {:error, reason} ->
        error_message = format_error(reason)

        {:noreply, put_flash(socket, :error, "Undo failed: #{error_message}")}
    end
  end

  @impl true
  def handle_event("auto_bid", _params, socket) do
    # DEV-1002: Auto-complete bidding phase
    room_code = socket.assigns.room_code

    # Start auto-bidding in a separate process to avoid blocking
    parent = self()

    Task.start(fn ->
      case GameHelpers.auto_bid(room_code, delay_ms: 500) do
        {:ok, _final_state} ->
          send(parent, {:auto_bid_complete, :success})

        {:error, :not_in_bidding_phase} ->
          send(parent, {:auto_bid_complete, {:error, "Game is not in bidding phase"}})

        {:error, reason} ->
          send(parent, {:auto_bid_complete, {:error, inspect(reason)}})
      end
    end)

    {:noreply, put_flash(socket, :info, "Auto-bidding started...")}
  end

  @impl true
  def handle_event("fast_forward", _params, socket) do
    # DEV-1003: Fast-forward game to completion
    room_code = socket.assigns.room_code

    case GameHelpers.fast_forward(room_code, delay_ms: 100) do
      {:ok, :started} ->
        {:noreply,
         put_flash(socket, :info, "Fast-forward started - bots will play automatically")}

      {:error, reason} ->
        error_message = format_error(reason)

        {:noreply, put_flash(socket, :error, "Fast-forward failed: #{error_message}")}
    end
  end

  # DEV-1301: Replay Controls Event Handlers

  @impl true
  def handle_event("toggle_replay_mode", _params, socket) do
    new_mode = !socket.assigns.replay_mode

    socket =
      if new_mode do
        # Entering replay mode - preserve current state
        socket
        |> assign(:replay_mode, true)
        |> put_flash(:info, "Replay mode activated")
      else
        # Exiting replay mode - restore live state
        game_state = get_game_state(socket.assigns.room_code)

        legal_actions =
          get_legal_actions(socket.assigns.room_code, socket.assigns.selected_position)

        socket
        |> assign(:replay_mode, false)
        |> assign(:replay_playing, false)
        |> assign(:game_state, game_state)
        |> assign(:legal_actions, legal_actions)
        |> put_flash(:info, "Replay mode deactivated")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_step_backward", _params, socket) do
    if socket.assigns.replay_mode do
      case ReplayController.step_backward(socket.assigns.room_code, socket.assigns.replay_index) do
        {:ok, state, new_index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_start} ->
          {:noreply, put_flash(socket, :info, "Already at the start")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Step backward failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_step_forward", _params, socket) do
    if socket.assigns.replay_mode do
      case ReplayController.step_forward(socket.assigns.room_code, socket.assigns.replay_index) do
        {:ok, state, new_index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_end} ->
          {:noreply, put_flash(socket, :info, "Already at the end")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Step forward failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_jump_to", %{"index" => index_str}, socket) do
    if socket.assigns.replay_mode do
      index = String.to_integer(index_str)

      case ReplayController.get_state_at_event(socket.assigns.room_code, index) do
        {:ok, state} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, index)
           |> assign(:legal_actions, [])}

        {:error, :invalid_index} ->
          {:noreply, put_flash(socket, :error, "Invalid event index")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Jump failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_jump_to_phase", %{"phase" => phase}, socket) do
    if socket.assigns.replay_mode do
      phase_atom = String.to_existing_atom(phase)

      case ReplayController.jump_to_phase(socket.assigns.room_code, phase_atom) do
        {:ok, state, index} ->
          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, index)
           |> assign(:legal_actions, [])
           |> put_flash(:info, "Jumped to #{format_phase(phase_atom)} phase")}

        {:error, :phase_not_found} ->
          {:noreply, put_flash(socket, :error, "Phase not reached yet")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Jump to phase failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_toggle_play", _params, socket) do
    if socket.assigns.replay_mode do
      new_playing = !socket.assigns.replay_playing

      socket =
        if new_playing do
          # Start auto-play
          send(self(), :replay_tick)
          assign(socket, :replay_playing, true)
        else
          # Stop auto-play
          assign(socket, :replay_playing, false)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("replay_set_speed", %{"speed" => speed_str}, socket) do
    speed = String.to_integer(speed_str)
    {:noreply, assign(socket, :replay_speed, speed)}
  end

  @impl true
  def handle_info(:replay_tick, socket) do
    if socket.assigns.replay_playing && socket.assigns.replay_mode do
      case ReplayController.step_forward(socket.assigns.room_code, socket.assigns.replay_index) do
        {:ok, state, new_index} ->
          # Schedule next tick
          Process.send_after(self(), :replay_tick, socket.assigns.replay_speed)

          {:noreply,
           socket
           |> assign(:game_state, state)
           |> assign(:replay_index, new_index)
           |> assign(:legal_actions, [])}

        {:error, :at_end} ->
          # Stop playing when we reach the end
          {:noreply, assign(socket, :replay_playing, false)}

        {:error, _reason} ->
          # Stop on error
          {:noreply, assign(socket, :replay_playing, false)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl">
        <!-- Header -->
        <div class="mb-8">
          <.link
            navigate={~p"/dev/games"}
            class="text-sm text-indigo-600 hover:text-indigo-900 mb-2 inline-block"
          >
            &larr; Back to Games
          </.link>
          <h1 class="text-4xl font-bold text-zinc-900">
            Game: {@room_code}
          </h1>
          <p class="mt-2 text-lg text-zinc-600">
            Development game detail view with interactive controls
          </p>
        </div>
        
    <!-- Room Info Card -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Room Information</h3>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-3">
              <div>
                <dt class="text-sm font-medium text-zinc-500">Status</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  <span class={"px-2 inline-flex text-xs leading-5 font-semibold rounded-full #{status_color(@room.status)}"}>
                    {@room.status}
                  </span>
                </dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Players</dt>
                <dd class="mt-1 text-sm text-zinc-900">{length(@room.player_ids)} / 4</dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Host</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {@room.host_id |> String.slice(0..7)}...
                </dd>
              </div>
            </dl>
          </div>
        </div>
        
    <!-- Position Selector - DEV-401 & DEV-502 -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6 flex justify-between items-start">
            <div>
              <h3 class="text-lg leading-6 font-medium text-zinc-900">Position Filter & View Mode</h3>
              <p class="mt-1 text-sm text-zinc-500">Select a position to view and execute actions</p>
            </div>
            <%!-- DEV-502: Split View Toggle --%>
            <button
              type="button"
              phx-click="toggle_view_mode"
              class={[
                "px-4 py-2 text-sm font-medium rounded-md transition-all shadow-sm",
                if(@view_mode == :split,
                  do: "bg-purple-600 text-white ring-2 ring-purple-300",
                  else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                )
              ]}
              title="Toggle split screen view (4 quadrants)"
            >
              <%= if @view_mode == :split do %>
                <svg class="w-5 h-5 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM14 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zM14 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"
                  />
                </svg>
                Split View Active
              <% else %>
                <svg class="w-5 h-5 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 5a1 1 0 011-1h14a1 1 0 011 1v14a1 1 0 01-1 1H5a1 1 0 01-1-1V5z"
                  />
                </svg>
                Enable Split View
              <% end %>
            </button>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <div class="mb-4 flex justify-between items-center">
              <div class={[
                "inline-flex items-center px-3 py-1 rounded-md text-sm font-medium",
                if(@selected_position == :all,
                  do: "bg-purple-100 text-purple-800",
                  else: "bg-blue-100 text-blue-800"
                )
              ]}>
                <%= if @selected_position == :all do %>
                  God Mode (All Players)
                <% else %>
                  Playing as: {format_position(@selected_position)}
                <% end %>
              </div>
              <%= if @view_mode == :split do %>
                <div class="text-xs text-purple-600 font-medium">
                  Split view: {format_position(@selected_position)} highlighted
                </div>
              <% end %>
            </div>

            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="select_position"
                phx-value-position="north"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-colors",
                  if(@selected_position == :north,
                    do: "bg-indigo-600 text-white",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                North
              </button>

              <button
                type="button"
                phx-click="select_position"
                phx-value-position="south"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-colors",
                  if(@selected_position == :south,
                    do: "bg-indigo-600 text-white",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                South
              </button>

              <button
                type="button"
                phx-click="select_position"
                phx-value-position="east"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-colors",
                  if(@selected_position == :east,
                    do: "bg-indigo-600 text-white",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                East
              </button>

              <button
                type="button"
                phx-click="select_position"
                phx-value-position="west"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-colors",
                  if(@selected_position == :west,
                    do: "bg-indigo-600 text-white",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                West
              </button>

              <button
                type="button"
                phx-click="select_position"
                phx-value-position="all"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-colors",
                  if(@selected_position == :all,
                    do: "bg-purple-600 text-white",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                God Mode (All)
              </button>
            </div>
          </div>
        </div>
        
    <!-- Bot Configuration - DEV-1106 (Compact) -->
        <details class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <summary class="px-4 py-3 cursor-pointer hover:bg-zinc-50 flex justify-between items-center">
            <div>
              <h3 class="text-sm font-medium text-zinc-900">Bot Configuration</h3>
              <p class="text-xs text-zinc-500">Configure bot players</p>
            </div>
          </summary>
          <div class="border-t border-zinc-200 px-4 py-4">
            <div class="grid grid-cols-2 gap-3 mb-3">
              <%= for position <- [:north, :south, :east, :west] do %>
                <.render_bot_position_config position={position} config={@bot_configs[position]} />
              <% end %>
            </div>
            <button
              type="button"
              phx-click="apply_bot_config"
              class="w-full px-3 py-2 text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Apply Changes
            </button>
          </div>
        </details>
        
    <!-- Dev Quick Actions - DEV-1001 to DEV-1003 Implementation -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Dev Quick Actions</h3>
            <p class="mt-1 text-sm text-zinc-500">
              Testing shortcuts for rapid development iteration
            </p>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <div class="flex flex-wrap gap-3">
              <button
                type="button"
                phx-click="undo_last_action"
                class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
                title="Undo the last game action"
              >
                <svg
                  class="w-5 h-5 mr-2"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"
                  />
                </svg>
                Undo Last Action
              </button>

              <button
                type="button"
                phx-click="auto_bid"
                class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
                title="Automatically complete the bidding phase"
              >
                <svg
                  class="w-5 h-5 mr-2"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 10V3L4 14h7v7l9-11h-7z"
                  />
                </svg>
                Auto-complete Bidding
              </button>

              <button
                type="button"
                phx-click="fast_forward"
                class="inline-flex items-center px-4 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 transition-colors"
                title="Fast forward the game to completion"
              >
                <svg
                  class="w-5 h-5 mr-2"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 3l14 9-14 9V3z"
                  />
                </svg>
                Fast Forward
              </button>
            </div>
          </div>
        </div>
        
    <!-- DEV-1301: Hand Replay Controls -->
        <%= if @replay_total_events > 0 do %>
          <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
            <div class="px-4 py-5 sm:px-6 flex justify-between items-center">
              <div>
                <h3 class="text-lg leading-6 font-medium text-zinc-900">Hand Replay</h3>
                <p class="mt-1 text-sm text-zinc-500">
                  Step through game history event by event
                </p>
              </div>
              <button
                type="button"
                phx-click="toggle_replay_mode"
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md transition-all shadow-sm",
                  if(@replay_mode,
                    do: "bg-amber-600 text-white ring-2 ring-amber-300",
                    else: "bg-zinc-100 text-zinc-700 hover:bg-zinc-200"
                  )
                ]}
              >
                <%= if @replay_mode do %>
                  <svg
                    class="w-5 h-5 inline mr-1"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                  Exit Replay
                <% else %>
                  <svg
                    class="w-5 h-5 inline mr-1"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0019 16V8a1 1 0 00-1.6-.8l-5.333 4zM4.066 11.2a1 1 0 000 1.6l5.334 4A1 1 0 0011 16V8a1 1 0 00-1.6-.8l-5.334 4z"
                    />
                  </svg>
                  Enter Replay Mode
                <% end %>
              </button>
            </div>
            <%= if @replay_mode do %>
              <div class="border-t border-zinc-200 px-4 py-5 sm:p-6 bg-amber-50">
                <!-- Event Progress Bar -->
                <div class="mb-4">
                  <div class="flex justify-between text-sm text-zinc-700 mb-2">
                    <span>Event {@replay_index + 1} of {@replay_total_events}</span>
                    <%= if @replay_index >= 0 && @replay_index < @replay_total_events do %>
                      <%= case ReplayController.get_event_info(@room_code, @replay_index) do %>
                        <% {:ok, event_info} -> %>
                          <span class="text-zinc-600 italic">{event_info.description}</span>
                        <% _ -> %>
                          <span></span>
                      <% end %>
                    <% end %>
                  </div>
                  <input
                    type="range"
                    min="0"
                    max={@replay_total_events - 1}
                    value={@replay_index}
                    phx-change="replay_jump_to"
                    name="index"
                    class="w-full h-2 bg-zinc-200 rounded-lg appearance-none cursor-pointer accent-amber-600"
                  />
                </div>
                <!-- Playback Controls -->
                <div class="flex items-center justify-between gap-3">
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="replay_step_backward"
                      class="px-3 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 disabled:opacity-50"
                      disabled={@replay_index <= 0}
                    >
                      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M15 19l-7-7 7-7"
                        />
                      </svg>
                    </button>
                    <button
                      type="button"
                      phx-click="replay_toggle_play"
                      class={[
                        "px-4 py-2 shadow-sm text-sm font-medium rounded-md text-white transition-colors",
                        if(@replay_playing,
                          do: "bg-red-600 hover:bg-red-700",
                          else: "bg-green-600 hover:bg-green-700"
                        )
                      ]}
                    >
                      <%= if @replay_playing do %>
                        <svg class="w-5 h-5 inline" fill="currentColor" viewBox="0 0 24 24">
                          <path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z" />
                        </svg>
                        Pause
                      <% else %>
                        <svg class="w-5 h-5 inline" fill="currentColor" viewBox="0 0 24 24">
                          <path d="M8 5v14l11-7z" />
                        </svg>
                        Play
                      <% end %>
                    </button>
                    <button
                      type="button"
                      phx-click="replay_step_forward"
                      class="px-3 py-2 border border-zinc-300 shadow-sm text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 disabled:opacity-50"
                      disabled={@replay_index >= @replay_total_events - 1}
                    >
                      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M9 5l7 7-7 7"
                        />
                      </svg>
                    </button>
                  </div>
                  <div class="flex items-center gap-3">
                    <label class="text-sm text-zinc-700">Speed:</label>
                    <select
                      name="speed"
                      phx-change="replay_set_speed"
                      class="px-2 py-1 text-sm border border-zinc-300 rounded-md bg-white"
                    >
                      <option value="2000" selected={@replay_speed == 2000}>0.5x</option>
                      <option value="1000" selected={@replay_speed == 1000}>1x</option>
                      <option value="500" selected={@replay_speed == 500}>2x</option>
                      <option value="250" selected={@replay_speed == 250}>4x</option>
                    </select>
                  </div>
                  <!-- Jump to Phase -->
                  <div class="flex items-center gap-2">
                    <label class="text-sm text-zinc-700">Jump to:</label>
                    <select
                      phx-change="replay_jump_to_phase"
                      name="phase"
                      class="px-2 py-1 text-sm border border-zinc-300 rounded-md bg-white"
                    >
                      <option value="">Select phase...</option>
                      <option value="dealer_selection">Dealer Selection</option>
                      <option value="dealing">Dealing</option>
                      <option value="bidding">Bidding</option>
                      <option value="declaring">Trump Declaration</option>
                      <option value="discarding">Discarding</option>
                      <option value="second_deal">Second Deal</option>
                      <option value="playing">Playing</option>
                      <option value="scoring">Scoring</option>
                    </select>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
        
    <!-- Card Table UI - DEV-1505 & DEV-502: Visual Card Table Integration with Split View -->
        <%= if @game_state do %>
          <%= if @view_mode == :split && @game_state.phase == :playing do %>
            <%!-- DEV-502: Split View Layout (2x2 Grid) --%>
            <div class="mb-8">
              <div class="bg-gradient-to-br from-purple-50 to-purple-100 p-4 rounded-lg shadow-lg">
                <div class="text-center mb-3">
                  <h3 class="text-lg font-semibold text-purple-900">Split View Mode</h3>
                  <p class="text-sm text-purple-700">
                    Viewing all 4 player perspectives simultaneously
                  </p>
                </div>
                <div class="grid grid-cols-2 gap-4">
                  <%= for position <- [:north, :south, :east, :west] do %>
                    <.render_position_view
                      position={position}
                      game_state={@game_state}
                      selected_position={@selected_position}
                      room_code={@room_code}
                    />
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <%!-- Single View Layout --%>
            <%= cond do %>
              <% @game_state.phase == :bidding -> %>
                <div class="mb-8">
                  <CardComponents.bidding_panel
                    current_bid={get_current_bid(@game_state)}
                    bidder={get_current_bidder(@game_state)}
                    legal_actions={@legal_actions}
                    bid_history={get_bid_history(@game_state)}
                  />
                </div>
              <% @game_state.phase == :trump_selection -> %>
                <div class="mb-8">
                  <CardComponents.trump_selection_panel
                    legal_actions={@legal_actions}
                    hand={get_selected_hand(@game_state, @selected_position)}
                  />
                </div>
              <% @game_state.phase == :playing -> %>
                <div class="mb-8">
                  <CardComponents.card_table
                    game_state={@game_state}
                    selected_position={@selected_position}
                    god_mode={@selected_position == :all}
                    legal_actions={@legal_actions}
                  />
                </div>
              <% true -> %>
                <%!-- Other phases like dealer_selection, hand_scoring, etc. --%>
                <div class="mb-8 bg-white shadow overflow-hidden sm:rounded-lg p-6">
                  <p class="text-sm text-gray-600">
                    Phase: <span class="font-semibold">{@game_state.phase}</span>
                  </p>
                  <p class="text-xs text-gray-500 mt-2">
                    Visual card table available during playing phase
                  </p>
                </div>
            <% end %>
          <% end %>
        <% end %>
        
    <!-- Action Execution - DEV-901 to DEV-904 Implementation -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Legal Actions</h3>
            <p class="mt-1 text-sm text-zinc-500">
              <%= if @selected_position == :all do %>
                Select a specific position to view and execute actions
              <% else %>
                Execute game actions for position:
                <span class="font-semibold">{@selected_position}</span>
              <% end %>
            </p>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <%= if @selected_position == :all do %>
              <div class="text-sm text-zinc-500 italic">
                Please select a specific position above to view legal actions.
              </div>
            <% else %>
              <%= if @executing_action do %>
                <div class="flex items-center justify-center py-8">
                  <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600"></div>
                  <span class="ml-3 text-sm text-zinc-600">Executing action...</span>
                </div>
              <% else %>
                <%= if Enum.empty?(@legal_actions) do %>
                  <div class="text-sm text-zinc-500 italic">
                    No legal actions available for this position at this time.
                  </div>
                <% else %>
                  <%!-- DEV-902: Render action buttons grouped by type --%>
                  <.render_action_groups legal_actions={@legal_actions} />
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
        
    <!-- Game State Card -->
        <%= if @game_state do %>
          <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
            <div class="px-4 py-5 sm:px-6">
              <h3 class="text-lg leading-6 font-medium text-zinc-900">Game State</h3>
              <p class="mt-1 max-w-2xl text-sm text-zinc-500">
                Current phase: <span class="font-semibold">{@game_state.phase}</span>
              </p>
            </div>
            <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
              <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
                <div>
                  <dt class="text-sm font-medium text-zinc-500">Current Turn</dt>
                  <dd class="mt-1 text-sm text-zinc-900">
                    {inspect(@game_state.current_turn)}
                  </dd>
                </div>
                <%= if Map.has_key?(@game_state, :dealer) do %>
                  <div>
                    <dt class="text-sm font-medium text-zinc-500">Dealer</dt>
                    <dd class="mt-1 text-sm text-zinc-900">{inspect(@game_state.dealer)}</dd>
                  </div>
                <% end %>
                <%= if Map.has_key?(@game_state, :trump_suit) && @game_state.trump_suit do %>
                  <div>
                    <dt class="text-sm font-medium text-zinc-500">Trump Suit</dt>
                    <dd class="mt-1 text-sm text-zinc-900">
                      {format_suit(@game_state.trump_suit)}
                    </dd>
                  </div>
                <% end %>
                <%= if Map.has_key?(@game_state, :winning_bid) && @game_state.winning_bid do %>
                  <div>
                    <dt class="text-sm font-medium text-zinc-500">Winning Bid</dt>
                    <dd class="mt-1 text-sm text-zinc-900">
                      {@game_state.winning_bid.amount} by {@game_state.winning_bid.team}
                    </dd>
                  </div>
                <% end %>
              </dl>
              
    <!-- Scores -->
              <%= if Map.has_key?(@game_state, :scores) do %>
                <div class="mt-6">
                  <h4 class="text-sm font-medium text-zinc-500 mb-3">Scores</h4>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="bg-blue-50 p-4 rounded-lg">
                      <div class="text-sm font-medium text-blue-900">North-South</div>
                      <div class="text-2xl font-bold text-blue-700">
                        {@game_state.scores.north_south}
                      </div>
                    </div>
                    <div class="bg-green-50 p-4 rounded-lg">
                      <div class="text-sm font-medium text-green-900">East-West</div>
                      <div class="text-2xl font-bold text-green-700">
                        {@game_state.scores.east_west}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Event Log Panel (FR-7 / DEV-704) --%>
          <div class="bg-white rounded-lg shadow-md p-6 mb-8">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-xl font-semibold">Event Log</h2>
              <div class="flex gap-2">
                <button
                  phx-click="refresh_events"
                  class="px-3 py-1 text-sm bg-blue-500 text-white rounded hover:bg-blue-600"
                >
                  Refresh
                </button>
                <button
                  phx-click="clear_events"
                  data-confirm="Are you sure you want to clear the event log?"
                  class="px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600"
                >
                  Clear
                </button>
                <button
                  phx-click="toggle_export_modal"
                  class="px-3 py-1 text-sm bg-green-500 text-white rounded hover:bg-green-600"
                >
                  Export
                </button>
              </div>
            </div>

            <%!-- Filters --%>
            <div class="flex gap-4 mb-4 items-end">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Filter by Type</label>
                <select
                  phx-change="filter_events"
                  name="type"
                  class="rounded border-gray-300"
                >
                  <option value="all" selected={is_nil(@event_filter_type)}>All Events</option>
                  <option value="bid_made" selected={@event_filter_type == :bid_made}>Bids</option>
                  <option value="bid_passed" selected={@event_filter_type == :bid_passed}>
                    Passes
                  </option>
                  <option value="trump_declared" selected={@event_filter_type == :trump_declared}>
                    Trump Declared
                  </option>
                  <option value="card_played" selected={@event_filter_type == :card_played}>
                    Cards Played
                  </option>
                  <option value="trick_won" selected={@event_filter_type == :trick_won}>
                    Tricks Won
                  </option>
                  <option value="hand_scored" selected={@event_filter_type == :hand_scored}>
                    Hand Scored
                  </option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Filter by Player</label>
                <select
                  phx-change="filter_events_by_player"
                  name="player"
                  class="rounded border-gray-300"
                >
                  <option value="all" selected={is_nil(@event_filter_player)}>All Players</option>
                  <option value="north" selected={@event_filter_player == :north}>North</option>
                  <option value="south" selected={@event_filter_player == :south}>South</option>
                  <option value="east" selected={@event_filter_player == :east}>East</option>
                  <option value="west" selected={@event_filter_player == :west}>West</option>
                </select>
              </div>

              <div class="flex items-center">
                <label class="inline-flex items-center cursor-pointer">
                  <input
                    type="checkbox"
                    phx-click="toggle_bot_reasoning"
                    checked={@show_bot_reasoning}
                    class="rounded border-gray-300 text-indigo-600 shadow-sm focus:border-indigo-300 focus:ring focus:ring-indigo-200 focus:ring-opacity-50"
                  />
                  <span class="ml-2 text-sm text-gray-700">Show Bot Reasoning</span>
                </label>
              </div>
            </div>

            <%!-- Event List --%>
            <div class="bg-gray-50 rounded p-4 max-h-96 overflow-y-auto font-mono text-sm">
              <%= if Enum.empty?(@events) do %>
                <p class="text-gray-500 italic">No events recorded yet</p>
              <% else %>
                <div class="space-y-1">
                  <%= for event <- @events do %>
                    <div class="flex gap-2">
                      <span class="text-gray-500">[{format_event_timestamp(event)}]</span>
                      <span class={event_type_color(event.type)}>
                        {Event.format(event)}
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="mt-2 text-sm text-gray-600">
              Showing {length(@events)} events (max 50)
            </div>
          </div>

          <%!-- Export Modal (FR-7 / DEV-705) --%>
          <%= if @show_event_export do %>
            <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
              <div class="bg-white rounded-lg shadow-xl p-6 max-w-2xl w-full mx-4">
                <div class="flex items-center justify-between mb-4">
                  <h3 class="text-lg font-semibold">Export Events</h3>
                  <button
                    phx-click="toggle_export_modal"
                    class="text-gray-500 hover:text-gray-700"
                  >
                    ✕
                  </button>
                </div>

                <div class="space-y-4">
                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-2">JSON Format</label>
                    <textarea
                      id="export-json"
                      readonly
                      class="w-full h-64 font-mono text-xs border rounded p-2"
                    >{Jason.encode!(@events |> Enum.map(&Event.to_json/1), pretty: true)}</textarea>
                    <button
                      id="copy-json-button"
                      phx-hook="CopyToClipboard"
                      data-target="export-json"
                      class="mt-2 px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
                    >
                      Copy JSON
                    </button>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-2">Text Format</label>
                    <textarea
                      id="export-text"
                      readonly
                      class="w-full h-64 font-mono text-xs border rounded p-2"
                    >{Enum.map_join(@events, "\n", fn event ->
                      "[#{Calendar.strftime(event.timestamp, "%H:%M:%S")}] #{Event.format(event)}"
                    end)}</textarea>
                    <button
                      id="copy-text-button"
                      phx-hook="CopyToClipboard"
                      data-target="export-text"
                      class="mt-2 px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
                    >
                      Copy Text
                    </button>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
          
    <!-- Full State JSON (collapsible) -->
          <details class="bg-white shadow overflow-hidden sm:rounded-lg">
            <summary class="px-4 py-5 sm:px-6 cursor-pointer hover:bg-zinc-50">
              <div class="flex items-center justify-between">
                <div>
                  <h3 class="text-lg leading-6 font-medium text-zinc-900 inline">
                    Full Game State (Raw)
                  </h3>
                </div>
                <button
                  id="copy-game-state"
                  type="button"
                  phx-hook="Clipboard"
                  data-clipboard-text={inspect(@game_state, pretty: true)}
                  class="px-3 py-1 text-sm font-medium rounded-md bg-indigo-600 text-white hover:bg-indigo-700 transition-colors"
                  onclick="event.stopPropagation()"
                >
                  <%= if @copy_feedback do %>
                    <span>Copied!</span>
                  <% else %>
                    <span>Copy State</span>
                  <% end %>
                </button>
              </div>
            </summary>
            <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
              <pre class="text-xs bg-zinc-50 p-4 rounded overflow-auto"><%= inspect(@game_state, pretty: true, limit: :infinity) %></pre>
            </div>
          </details>
        <% else %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6">
            <p class="text-yellow-800">
              Game has not started yet or state is unavailable.
            </p>
          </div>
        <% end %>
        
    <!-- Auto-refresh indicator -->
        <div class="mt-4 text-center text-sm text-zinc-500">
          <span class="inline-flex items-center">
            <span class="h-2 w-2 bg-green-500 rounded-full mr-2 animate-pulse"></span>
            Live updates enabled
          </span>
        </div>
      </div>
    </div>
    """
  end

  # DEV-502: Render individual position view quadrant for split view
  defp render_position_view(assigns) do
    position = assigns.position
    is_active = assigns.selected_position == position
    legal_actions = if is_active, do: get_legal_actions(assigns.room_code, position), else: []

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:position_legal_actions, legal_actions)

    ~H"""
    <div class={[
      "bg-white rounded-lg shadow-md border-2 transition-all",
      if(@is_active, do: "border-indigo-500 ring-2 ring-indigo-300", else: "border-gray-200")
    ]}>
      <%!-- Position Header --%>
      <div class={[
        "px-3 py-2 rounded-t-lg border-b flex justify-between items-center",
        if(@is_active, do: "bg-indigo-50 border-indigo-200", else: "bg-gray-50 border-gray-200")
      ]}>
        <div class="flex items-center gap-2">
          <span class={[
            "font-semibold text-sm",
            if(@is_active, do: "text-indigo-900", else: "text-gray-700")
          ]}>
            {format_position(@position)}
          </span>
          <%= if @is_active do %>
            <span class="text-xs bg-indigo-600 text-white px-2 py-0.5 rounded">Active</span>
          <% end %>
          <%= if @game_state.current_turn == @position do %>
            <span class="text-xs bg-green-500 text-white px-2 py-0.5 rounded animate-pulse">
              Turn
            </span>
          <% end %>
        </div>
        <%!-- Card count --%>
        <span class="text-xs text-gray-600">
          {length(get_selected_hand(@game_state, @position))} cards
        </span>
      </div>
      <%!-- Position Content --%>
      <div class="p-3">
        <%!-- Hand Display (Compact) --%>
        <div class="mb-2">
          <div class="text-xs font-medium text-gray-500 mb-1">Hand:</div>
          <div class="flex flex-wrap gap-1">
            <%= for card <- get_selected_hand(@game_state, @position) |> Enum.take(12) do %>
              <div class="inline-block">
                <CardComponents.card card={card} size={:sm} face_down={false} />
              </div>
            <% end %>
            <%= if length(get_selected_hand(@game_state, @position)) > 12 do %>
              <span class="text-xs text-gray-500 self-center">
                +{length(get_selected_hand(@game_state, @position)) - 12} more
              </span>
            <% end %>
          </div>
        </div>
        <%!-- Legal Actions Count --%>
        <%= if @is_active && @position_legal_actions != [] do %>
          <div class="mt-2 text-xs">
            <span class="text-green-600 font-medium">
              {length(@position_legal_actions)} legal actions
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # DEV-1106: Render bot position configuration
  defp render_bot_position_config(assigns) do
    ~H"""
    <div class="bg-zinc-50 rounded p-2 text-xs">
      <div class="font-semibold text-zinc-900 mb-1">{format_position(@position)}</div>
      <div class="flex gap-1 mb-1">
        <button
          type="button"
          phx-click="update_bot_config"
          phx-value-position={@position}
          phx-value-type="human"
          class={[
            "flex-1 px-2 py-1 rounded",
            if(@config.type == :human, do: "bg-indigo-600 text-white", else: "bg-white text-zinc-700")
          ]}
        >
          Human
        </button>
        <button
          type="button"
          phx-click="update_bot_config"
          phx-value-position={@position}
          phx-value-type="bot"
          class={[
            "flex-1 px-2 py-1 rounded",
            if(@config.type == :bot, do: "bg-indigo-600 text-white", else: "bg-white text-zinc-700")
          ]}
        >
          Bot
        </button>
      </div>
      <%= if @config.type == :bot do %>
        <select
          phx-change="update_bot_config"
          phx-value-position={@position}
          name="difficulty"
          class="w-full rounded border-zinc-300 text-xs"
        >
          <option value="random" selected={@config.difficulty == :random}>Random</option>
          <option value="basic" selected={@config.difficulty == :basic}>Basic</option>
          <option value="smart" selected={@config.difficulty == :smart}>Smart</option>
        </select>
      <% end %>
    </div>
    """
  end

  # DEV-902: Render action buttons grouped by type
  defp render_action_groups(assigns) do
    grouped = group_actions(assigns.legal_actions)
    assigns = assign(assigns, :grouped_actions, grouped)

    ~H"""
    <div class="space-y-6">
      <%= for {group_name, group_actions} <- @grouped_actions do %>
        <div>
          <h4 class="text-sm font-medium text-zinc-700 mb-2">{group_name}</h4>
          <div class="flex flex-wrap gap-2">
            <%= for action <- group_actions do %>
              <button
                type="button"
                phx-click="execute_action"
                phx-value-action={encode_action(action)}
                class="px-3 py-2 text-sm font-medium rounded-md bg-indigo-600 text-white hover:bg-indigo-700 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {format_action_text(action)}
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Private functions

  defp get_game_state(room_code) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} -> state
      {:error, _} -> nil
    end
  end

  # DEV-901: Fetch legal actions for a position
  defp get_legal_actions(_room_code, :all), do: []

  defp get_legal_actions(room_code, position) when is_atom(position) do
    case GameAdapter.get_legal_actions(room_code, position) do
      {:ok, actions} -> actions
      {:error, _} -> []
    end
  end

  # DEV-902: Format action text for display
  defp format_action_text(action) do
    case action do
      :pass -> "Pass"
      {:bid, amount} -> "Bid #{amount}"
      {:play_card, {rank, suit}} -> "Play #{format_card(rank, suit)}"
      {:declare_trump, suit} -> "Declare #{format_suit(suit)}"
      _ -> inspect(action)
    end
  end

  defp format_card(rank, suit) do
    "#{format_rank(rank)}#{format_suit_symbol(suit)}"
  end

  defp format_rank(rank) do
    case rank do
      14 -> "A"
      13 -> "K"
      12 -> "Q"
      11 -> "J"
      n -> to_string(n)
    end
  end

  defp format_suit_symbol(suit) do
    case suit do
      :hearts -> "♥"
      :diamonds -> "♦"
      :clubs -> "♣"
      :spades -> "♠"
      _ -> to_string(suit)
    end
  end

  defp format_action(action) do
    case action do
      :pass -> "Pass"
      {:bid, amount} -> "Bid #{amount}"
      {:play_card, {rank, suit}} -> "Play #{format_card(rank, suit)}"
      {:declare_trump, suit} -> "Declare #{format_suit(suit)}"
      _ -> inspect(action)
    end
  end

  # DEV-902: Group actions by type
  defp group_actions(actions) do
    actions
    |> Enum.group_by(&action_type/1)
    |> Enum.map(fn {type, acts} -> {type_label(type), acts} end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp action_type(action) do
    case action do
      :pass -> :bidding
      {:bid, _} -> :bidding
      {:declare_trump, _} -> :trump
      {:play_card, _} -> :cards
      _ -> :other
    end
  end

  defp type_label(type) do
    case type do
      :bidding -> "Bidding Actions"
      :trump -> "Trump Declaration"
      :cards -> "Card Play"
      :other -> "Other Actions"
    end
  end

  # Encode/decode actions for phx-click
  defp encode_action(:pass), do: Jason.encode!("pass")
  defp encode_action(:select_dealer), do: Jason.encode!("select_dealer")
  defp encode_action({:bid, amount}), do: Jason.encode!(["bid", amount])
  defp encode_action({:declare_trump, suit}), do: Jason.encode!(["declare_trump", suit])
  defp encode_action({:play_card, {rank, suit}}), do: Jason.encode!(["play_card", [rank, suit]])
  defp encode_action(action), do: Jason.encode!(action)

  defp decode_action(action_json) do
    case Jason.decode(action_json) do
      {:ok, "pass"} ->
        {:ok, :pass}

      {:ok, "select_dealer"} ->
        {:ok, :select_dealer}

      {:ok, ["bid", amount]} ->
        {:ok, {:bid, amount}}

      {:ok, ["declare_trump", suit]} ->
        {:ok, {:declare_trump, String.to_existing_atom(suit)}}

      {:ok, ["play_card", [rank, suit]]} ->
        {:ok, {:play_card, {rank, String.to_existing_atom(suit)}}}

      {:error, error} ->
        {:error, "Invalid action format: #{inspect(error)}"}

      _ ->
        {:error, "Invalid action format: #{action_json}"}
    end
  rescue
    ArgumentError -> {:error, "Invalid action format: unknown atom in #{action_json}"}
    error -> {:error, "Invalid action format: #{Exception.message(error)}"}
  end

  # DEV-904: Format error messages
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_error(reason), do: inspect(reason)

  defp status_color(status) do
    case status do
      :waiting -> "bg-yellow-100 text-yellow-800"
      :ready -> "bg-blue-100 text-blue-800"
      :playing -> "bg-green-100 text-green-800"
      :finished -> "bg-gray-100 text-gray-800"
      :closed -> "bg-red-100 text-red-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp format_suit(suit) do
    case suit do
      :hearts -> "♥ Hearts"
      :diamonds -> "♦ Diamonds"
      :clubs -> "♣ Clubs"
      :spades -> "♠ Spades"
      _ -> inspect(suit)
    end
  end

  defp format_position(position) do
    case position do
      :north -> "North"
      :south -> "South"
      :east -> "East"
      :west -> "West"
      :all -> "All Players"
      _ -> inspect(position)
    end
  end

  # DEV-1106: Bot configuration helper functions

  defp initialize_bot_configs(room_code) do
    # Fetch current bots from BotManager
    current_bots = BotManager.list_bots(room_code)

    # Initialize config for each position
    [:north, :south, :east, :west]
    |> Enum.map(fn position ->
      config =
        case Map.get(current_bots, position) do
          nil ->
            # No bot exists - default to human
            %{type: :human, difficulty: :random, delay_ms: 1000, paused: false}

          bot_info ->
            # Bot exists - populate config
            %{
              type: :bot,
              difficulty: bot_info.strategy,
              delay_ms: 1000,
              paused: bot_info.status == :paused
            }
        end

      {position, config}
    end)
    |> Map.new()
  end

  defp maybe_update_type(config, %{"type" => type}) when type in ["human", "bot"] do
    %{config | type: String.to_existing_atom(type)}
  end

  defp maybe_update_type(config, _params), do: config

  defp maybe_update_difficulty(config, %{"difficulty" => difficulty})
       when difficulty in ["random", "basic", "smart"] do
    %{config | difficulty: String.to_existing_atom(difficulty)}
  end

  defp maybe_update_difficulty(config, _params), do: config

  defp maybe_update_delay(config, %{"delay_ms" => delay_str}) do
    case Integer.parse(delay_str) do
      {delay, _} when delay >= 0 and delay <= 3000 ->
        %{config | delay_ms: delay}

      _ ->
        config
    end
  end

  defp maybe_update_delay(config, _params), do: config

  defp apply_position_config(room_code, position, config) do
    current_bots = BotManager.list_bots(room_code)
    bot_exists = Map.has_key?(current_bots, position)

    # Default :unknown strategy to :random
    difficulty = if config.difficulty == :unknown, do: :random, else: config.difficulty

    case {config.type, bot_exists} do
      {:bot, false} ->
        # Start a new bot
        BotManager.start_bot(room_code, position, difficulty, config.delay_ms)

      {:bot, true} ->
        # Bot exists - stop and restart with new config
        BotManager.stop_bot(room_code, position)
        # Small delay to ensure cleanup
        Process.sleep(100)
        BotManager.start_bot(room_code, position, difficulty, config.delay_ms)

      {:human, true} ->
        # Stop the bot
        BotManager.stop_bot(room_code, position)

      {:human, false} ->
        # No bot exists, and user wants human - nothing to do
        :ok
    end
  end

  # Event log helper functions

  defp format_event_timestamp(event) do
    event.timestamp
    |> Calendar.strftime("%H:%M:%S")
  end

  defp event_type_color(type) do
    case type do
      :bid_made -> "text-blue-600"
      :bid_passed -> "text-gray-500"
      :trump_declared -> "text-purple-600"
      :card_played -> "text-green-600"
      :trick_won -> "text-yellow-600"
      :hand_scored -> "text-orange-600"
      :game_over -> "text-red-600"
      :bot_reasoning -> "text-indigo-600 italic"
      _ -> "text-gray-700"
    end
  end

  # DEV-1505 & DEV-1506: Helper functions for card table and phase displays

  defp get_current_bid(state) do
    get_in(state, [:winning_bid, :amount])
  end

  defp get_current_bidder(state) do
    case get_in(state, [:winning_bid, :team]) do
      :north_south -> :north
      :east_west -> :east
      team -> team
    end
  end

  defp get_bid_history(state) do
    # Extract bid history from game state if available
    Map.get(state, :bid_history, [])
  end

  defp get_selected_hand(_state, :all), do: []

  defp get_selected_hand(state, position) when is_atom(position) do
    get_in(state, [:players, position, :hand]) || []
  end

  # Helper function to get filtered events
  defp get_filtered_events(assigns, show_bot_reasoning) do
    events =
      EventRecorder.get_events(assigns.room_code,
        limit: 50,
        type: assigns.event_filter_type,
        player: assigns.event_filter_player
      )

    if show_bot_reasoning do
      events
    else
      Enum.reject(events, &(&1.type == :bot_reasoning))
    end
  end

  # DEV-1301: Format phase names for display
  defp format_phase(phase) do
    case phase do
      :dealer_selection -> "Dealer Selection"
      :dealing -> "Dealing"
      :bidding -> "Bidding"
      :declaring -> "Trump Declaration"
      :discarding -> "Discarding"
      :second_deal -> "Second Deal"
      :playing -> "Playing"
      :scoring -> "Scoring"
      :complete -> "Complete"
      _ -> phase |> to_string() |> String.capitalize()
    end
  end
end
