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
  alias PidroServer.Dev.BotManager
  alias PidroServer.Games.{GameAdapter, RoomManager}

  @impl true
  def mount(%{"code" => room_code}, _session, socket) do
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        if connected?(socket) do
          # Subscribe to game updates for this specific room
          Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
        end

        # Get initial game state
        game_state = get_game_state(room_code)

        # DEV-901: Fetch legal actions for initial position
        legal_actions = get_legal_actions(room_code, :all)

        # DEV-1106: Initialize bot configuration
        bot_configs = initialize_bot_configs(room_code)

        {:ok,
         socket
         |> assign(:room, room)
         |> assign(:room_code, room_code)
         |> assign(:game_state, game_state)
         |> assign(:selected_position, :all)
         |> assign(:legal_actions, legal_actions)
         |> assign(:executing_action, false)
         |> assign(:copy_feedback, false)
         |> assign(:bot_configs, bot_configs)
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

    {:noreply,
     socket
     |> assign(:game_state, new_state)
     |> assign(:legal_actions, legal_actions)}
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
                <dd class="mt-1 text-sm text-zinc-900">{length(@room.players)} / 4</dd>
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
        
    <!-- Position Selector - DEV-401 -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Position Filter</h3>
            <p class="mt-1 text-sm text-zinc-500">Select a position to view and execute actions</p>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <div class="mb-4">
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
        
    <!-- Bot Configuration - DEV-1106 -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Bot Configuration</h3>
            <p class="mt-1 text-sm text-zinc-500">Configure bot players for each position</p>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <div class="space-y-6">
              <%= for position <- [:north, :south, :east, :west] do %>
                <.render_bot_position_config position={position} config={@bot_configs[position]} />
              <% end %>
            </div>

            <div class="mt-6 pt-6 border-t border-zinc-200">
              <button
                type="button"
                phx-click="apply_bot_config"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 transition-colors"
              >
                Apply Changes
              </button>
            </div>
          </div>
        </div>
        
    <!-- Action Execution - DEV-901 to DEV-904 Implementation -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Quick Actions</h3>
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
                  <dt class="text-sm font-medium text-zinc-500">Current Player</dt>
                  <dd class="mt-1 text-sm text-zinc-900">
                    {inspect(@game_state.current_player)}
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
          
    <!-- Full State JSON (collapsible) -->
          <details class="bg-white shadow overflow-hidden sm:rounded-lg">
            <summary class="px-4 py-5 sm:px-6 cursor-pointer hover:bg-zinc-50">
              <div class="flex items-center justify-between">
                <div>
                  <h3 class="text-lg leading-6 font-medium text-zinc-900 inline">
                    Full Game State (JSON)
                  </h3>
                </div>
                <button
                  id="copy-game-state"
                  type="button"
                  phx-hook="Clipboard"
                  data-clipboard-text={Jason.encode!(@game_state, pretty: true)}
                  class="px-3 py-1 text-sm font-medium rounded-md bg-indigo-600 text-white hover:bg-indigo-700 transition-colors"
                  onclick="event.stopPropagation()"
                >
                  <%= if @copy_feedback do %>
                    <span>Copied!</span>
                  <% else %>
                    <span>Copy JSON</span>
                  <% end %>
                </button>
              </div>
            </summary>
            <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
              <pre class="text-xs bg-zinc-50 p-4 rounded overflow-auto"><%= Jason.encode!(@game_state, pretty: true) %></pre>
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

  # DEV-1106: Render bot position configuration
  defp render_bot_position_config(assigns) do
    ~H"""
    <div class="bg-zinc-50 rounded-lg p-4">
      <div class="flex items-center justify-between mb-4">
        <h4 class="text-sm font-semibold text-zinc-900">
          {format_position(@position)}
        </h4>
        <span class={[
          "px-2 py-1 text-xs font-medium rounded-full",
          if(@config.type == :bot,
            do: "bg-green-100 text-green-800",
            else: "bg-gray-100 text-gray-800"
          )
        ]}>
          <%= if @config.type == :bot do %>
            Bot
          <% else %>
            Human
          <% end %>
        </span>
      </div>

      <div class="space-y-4">
        <!-- Type Selection -->
        <div>
          <label class="block text-sm font-medium text-zinc-700 mb-2">Player Type</label>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="update_bot_config"
              phx-value-position={@position}
              phx-value-type="human"
              class={[
                "flex-1 px-3 py-2 text-sm font-medium rounded-md transition-colors",
                if(@config.type == :human,
                  do: "bg-indigo-600 text-white",
                  else: "bg-white text-zinc-700 border border-zinc-300 hover:bg-zinc-50"
                )
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
                "flex-1 px-3 py-2 text-sm font-medium rounded-md transition-colors",
                if(@config.type == :bot,
                  do: "bg-indigo-600 text-white",
                  else: "bg-white text-zinc-700 border border-zinc-300 hover:bg-zinc-50"
                )
              ]}
            >
              Bot
            </button>
          </div>
        </div>

        <%= if @config.type == :bot do %>
          <!-- Bot Difficulty -->
          <div>
            <label
              for={"bot-difficulty-#{@position}"}
              class="block text-sm font-medium text-zinc-700 mb-2"
            >
              Difficulty
            </label>
            <select
              id={"bot-difficulty-#{@position}"}
              phx-change="update_bot_config"
              phx-value-position={@position}
              name="difficulty"
              class="block w-full rounded-md border-zinc-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
            >
              <option value="random" selected={@config.difficulty == :random}>Random</option>
              <option value="basic" selected={@config.difficulty == :basic}>Basic</option>
              <option value="smart" selected={@config.difficulty == :smart}>Smart</option>
            </select>
          </div>
          <!-- Bot Delay Slider -->
          <div>
            <label
              for={"bot-delay-#{@position}"}
              class="block text-sm font-medium text-zinc-700 mb-2"
            >
              Delay: {@config.delay_ms}ms
            </label>
            <input
              id={"bot-delay-#{@position}"}
              type="range"
              min="0"
              max="3000"
              step="100"
              value={@config.delay_ms}
              phx-change="update_bot_config"
              phx-value-position={@position}
              name="delay_ms"
              class="w-full h-2 bg-zinc-200 rounded-lg appearance-none cursor-pointer"
            />
            <div class="flex justify-between text-xs text-zinc-500 mt-1">
              <span>0ms</span>
              <span>3000ms</span>
            </div>
          </div>
          <!-- Pause/Resume Button -->
          <div>
            <button
              type="button"
              phx-click="toggle_bot_pause"
              phx-value-position={@position}
              class={[
                "w-full px-3 py-2 text-sm font-medium rounded-md transition-colors",
                if(@config.paused,
                  do: "bg-green-600 text-white hover:bg-green-700",
                  else: "bg-yellow-600 text-white hover:bg-yellow-700"
                )
              ]}
            >
              <%= if @config.paused do %>
                Resume Bot
              <% else %>
                Pause Bot
              <% end %>
            </button>
          </div>
        <% end %>
      </div>
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
  defp encode_action(action) do
    Jason.encode!(action)
  end

  defp decode_action(action_json) do
    case Jason.decode(action_json) do
      {:ok, "pass"} -> {:ok, :pass}
      {:ok, ["bid", amount]} -> {:ok, {:bid, amount}}
      {:ok, ["declare_trump", suit]} -> {:ok, {:declare_trump, String.to_existing_atom(suit)}}
      {:ok, ["play_card", [rank, suit]]} -> {:ok, {:play_card, {rank, String.to_existing_atom(suit)}}}
      {:error, error} -> {:error, "Invalid action format: #{inspect(error)}"}
      _ -> {:error, "Invalid action format: #{action_json}"}
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

    case {config.type, bot_exists} do
      {:bot, false} ->
        # Start a new bot
        BotManager.start_bot(room_code, position, config.difficulty, config.delay_ms)

      {:bot, true} ->
        # Bot exists - stop and restart with new config
        BotManager.stop_bot(room_code, position)
        # Small delay to ensure cleanup
        Process.sleep(100)
        BotManager.start_bot(room_code, position, config.difficulty, config.delay_ms)

      {:human, true} ->
        # Stop the bot
        BotManager.stop_bot(room_code, position)

      {:human, false} ->
        # No bot exists, and user wants human - nothing to do
        :ok
    end
  end
end
