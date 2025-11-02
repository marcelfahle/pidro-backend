defmodule PidroServerWeb.Dev.GameListLive do
  @moduledoc """
  Development interface for managing and monitoring game rooms.

  This LiveView provides a real-time view of all game rooms with:
  - Live statistics (total rooms, waiting, active, finished)
  - Detailed room information in a table format
  - Links to watch active games in spectator mode
  - Game creation form with bot configuration (DEV-101)
  - Game name display (DEV-201)
  - Phase filtering (DEV-202)
  - Sort by creation date (DEV-203)
  - Game count badge (DEV-204)
  - Placeholder for deleting games (to be implemented in DEV-301)

  The view subscribes to "lobby:updates" PubSub topic for real-time updates.
  """

  use PidroServerWeb, :live_view
  alias PidroServer.Dev.BotManager
  alias PidroServer.Games.RoomManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to lobby updates
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    end

    rooms = RoomManager.list_rooms(:all)

    {:ok,
     socket
     |> assign(:phase_filter, :all)
     |> assign(:sort_order, :desc)
     |> assign(:game_name, "")
     |> assign(:bot_count, 0)
     |> assign(:bot_difficulty, "random")
     |> assign(:show_create_form, false)
     |> assign(:page_title, "Development Games")
     |> assign_rooms_and_stats(rooms)}
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket) do
    # RoomManager broadcasts the full list of available rooms
    # We need all rooms (not just available), so refetch
    rooms = RoomManager.list_rooms(:all)
    {:noreply, assign_rooms_and_stats(socket, rooms)}
  end

  @impl true
  def handle_event("filter_phase", %{"phase" => phase}, socket) do
    phase_atom = String.to_existing_atom(phase)
    rooms = RoomManager.list_rooms(:all)

    {:noreply,
     socket
     |> assign(:phase_filter, phase_atom)
     |> assign_rooms_and_stats(rooms)}
  end

  @impl true
  def handle_event("toggle_sort", _params, socket) do
    new_sort_order = if socket.assigns.sort_order == :desc, do: :asc, else: :desc
    rooms = RoomManager.list_rooms(:all)

    {:noreply,
     socket
     |> assign(:sort_order, new_sort_order)
     |> assign_rooms_and_stats(rooms)}
  end

  @impl true
  def handle_event("toggle_create_form", _params, socket) do
    {:noreply, assign(socket, :show_create_form, !socket.assigns.show_create_form)}
  end

  @impl true
  def handle_event("update_form", params, socket) do
    socket =
      socket
      |> assign(:game_name, Map.get(params, "game_name", socket.assigns.game_name))
      |> assign(:bot_count, parse_bot_count(Map.get(params, "bot_count")))
      |> assign(:bot_difficulty, Map.get(params, "bot_difficulty", socket.assigns.bot_difficulty))

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_game", params, socket) do
    game_name = Map.get(params, "game_name", "")
    bot_count = parse_bot_count(Map.get(params, "bot_count"))
    bot_difficulty = Map.get(params, "bot_difficulty", "random")

    # Validate game name
    if String.trim(game_name) == "" do
      {:noreply, put_flash(socket, :error, "Game name cannot be empty")}
    else
      # Create the room with the game name as user_id for dev purposes
      metadata = %{
        name: game_name,
        bot_difficulty: bot_difficulty,
        is_dev_room: true
      }

      case RoomManager.create_room(game_name, metadata) do
        {:ok, room} ->
          # Start bots if requested
          start_bots_if_needed(room.code, bot_count, bot_difficulty)

          # Reset form and show success
          {:noreply,
           socket
           |> assign(:game_name, "")
           |> assign(:bot_count, 0)
           |> assign(:bot_difficulty, "random")
           |> assign(:show_create_form, false)
           |> put_flash(
             :info,
             "Game '#{game_name}' created successfully! Room code: #{room.code}"
           )}

        {:error, :already_in_room} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to create game: A room with this name already exists"
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create game: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:game_name, "")
     |> assign(:bot_count, 0)
     |> assign(:bot_difficulty, "random")
     |> assign(:show_create_form, false)}
  end

  @impl true
  def handle_event("request_delete", %{"code" => code}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :delete_single)
     |> assign(:confirm_message, "Delete game #{code}?")
     |> assign(:room_to_delete, code)}
  end

  @impl true
  def handle_event("request_bulk_delete", _params, socket) do
    finished_count = socket.assigns.stats.finished

    if finished_count > 0 do
      {:noreply,
       socket
       |> assign(:show_confirm_modal, true)
       |> assign(:confirm_action, :delete_bulk)
       |> assign(
         :confirm_message,
         "Delete #{finished_count} finished game#{if finished_count > 1, do: "s", else: ""}?"
       )}
    else
      {:noreply, put_flash(socket, :info, "No finished games to delete")}
    end
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    case socket.assigns.confirm_action do
      :delete_single -> handle_single_delete(socket)
      :delete_bulk -> handle_bulk_delete(socket)
      _ -> {:noreply, close_modal(socket)}
    end
  end

  @impl true
  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-4 py-10 sm:px-6 sm:py-28 lg:px-8 xl:px-28 xl:py-32">
      <div class="mx-auto max-w-7xl">
        <div class="mb-8">
          <h1 class="text-4xl font-bold text-zinc-900">Pidro Development Interface - Game List</h1>
          <p class="mt-2 text-lg text-zinc-600">
            Real-time overview and management of all game rooms
          </p>
        </div>
        
    <!-- Create New Game Section -->
        <div class="bg-white shadow sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:p-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Create New Game</h3>
            <div class="mt-2 max-w-xl text-sm text-zinc-500">
              <p>Create a new game room for testing and development.</p>
            </div>
            <div class="mt-5">
              <%= if !@show_create_form do %>
                <button
                  type="button"
                  phx-click="toggle_create_form"
                  class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                >
                  New Game
                </button>
              <% else %>
                <form phx-submit="create_game" phx-change="update_form" class="space-y-4">
                  <!-- Game Name Input -->
                  <div>
                    <label for="game_name" class="block text-sm font-medium text-zinc-700">
                      Game Name
                    </label>
                    <input
                      type="text"
                      name="game_name"
                      id="game_name"
                      value={@game_name}
                      placeholder="My Test Game"
                      class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                    />
                  </div>
                  <!-- Bot Count Radio Buttons -->
                  <div>
                    <label class="block text-sm font-medium text-zinc-700">Bot Count</label>
                    <div class="mt-2 space-x-4">
                      <label class="inline-flex items-center">
                        <input
                          type="radio"
                          name="bot_count"
                          value="0"
                          checked={@bot_count == 0}
                          class="focus:ring-indigo-500 h-4 w-4 text-indigo-600 border-zinc-300"
                        />
                        <span class="ml-2 text-sm text-zinc-700">0</span>
                      </label>
                      <label class="inline-flex items-center">
                        <input
                          type="radio"
                          name="bot_count"
                          value="3"
                          checked={@bot_count == 3}
                          class="focus:ring-indigo-500 h-4 w-4 text-indigo-600 border-zinc-300"
                        />
                        <span class="ml-2 text-sm text-zinc-700">3</span>
                      </label>
                      <label class="inline-flex items-center">
                        <input
                          type="radio"
                          name="bot_count"
                          value="4"
                          checked={@bot_count == 4}
                          class="focus:ring-indigo-500 h-4 w-4 text-indigo-600 border-zinc-300"
                        />
                        <span class="ml-2 text-sm text-zinc-700">4</span>
                      </label>
                    </div>
                  </div>
                  <!-- Bot Difficulty Dropdown -->
                  <div>
                    <label for="bot_difficulty" class="block text-sm font-medium text-zinc-700">
                      Bot Difficulty
                    </label>
                    <select
                      name="bot_difficulty"
                      id="bot_difficulty"
                      class="mt-1 block w-full rounded-md border-zinc-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                    >
                      <option value="random" selected={@bot_difficulty == "random"}>Random</option>
                      <option value="basic" selected={@bot_difficulty == "basic"}>Basic</option>
                      <option value="smart" selected={@bot_difficulty == "smart"}>Smart</option>
                    </select>
                  </div>
                  <!-- Action Buttons -->
                  <div class="flex space-x-3">
                    <button
                      type="submit"
                      class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                    >
                      Create
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_create"
                      class="inline-flex items-center px-4 py-2 border border-zinc-300 text-sm font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                    >
                      Cancel
                    </button>
                  </div>
                </form>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Statistics Cards -->
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4 mb-8">
          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Total Rooms</dt>
              <dd class="mt-1 text-3xl font-semibold text-zinc-900">{@stats.total}</dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Waiting</dt>
              <dd class="mt-1 text-3xl font-semibold text-yellow-600">{@stats.waiting}</dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Active Games</dt>
              <dd class="mt-1 text-3xl font-semibold text-green-600">{@stats.playing}</dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Finished</dt>
              <dd class="mt-1 text-3xl font-semibold text-blue-600">{@stats.finished}</dd>
            </div>
          </div>
        </div>
        
    <!-- Filter and Sort Controls -->
        <div class="bg-white shadow sm:rounded-lg mb-4 px-4 py-4">
          <div class="flex flex-wrap items-center gap-4">
            <!-- Phase Filter -->
            <div class="flex items-center gap-2">
              <label for="phase-filter" class="text-sm font-medium text-zinc-700">
                Filter by Phase:
              </label>
              <select
                id="phase-filter"
                phx-change="filter_phase"
                name="phase"
                class="block rounded-md border-zinc-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              >
                <option value="all" selected={@phase_filter == :all}>All</option>
                <option value="waiting" selected={@phase_filter == :waiting}>Waiting</option>
                <option value="playing" selected={@phase_filter == :playing}>Playing</option>
                <option value="finished" selected={@phase_filter == :finished}>Finished</option>
              </select>
            </div>
            
    <!-- Sort Toggle -->
            <button
              type="button"
              phx-click="toggle_sort"
              class="inline-flex items-center px-3 py-2 border border-zinc-300 shadow-sm text-sm leading-4 font-medium rounded-md text-zinc-700 bg-white hover:bg-zinc-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
            >
              <%= if @sort_order == :desc do %>
                Newest First
              <% else %>
                Oldest First
              <% end %>
            </button>
            
    <!-- Game Count Badge -->
            <div class="ml-auto">
              <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-indigo-100 text-indigo-800">
                Showing {@stats.filtered} of {@stats.total} games
              </span>
            </div>
          </div>
        </div>
        
    <!-- Rooms Table -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg">
          <div class="px-4 py-5 sm:px-6 flex justify-between items-center">
            <div>
              <h3 class="text-lg leading-6 font-medium text-zinc-900">Active Rooms</h3>
              <p class="mt-1 max-w-2xl text-sm text-zinc-500">
                Live updates from all game rooms
              </p>
            </div>
            <%= if @stats.finished > 0 do %>
              <button
                type="button"
                phx-click="request_bulk_delete"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-red-600 hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500"
              >
                Delete All Finished ({@stats.finished})
              </button>
            <% end %>
          </div>
          <div class="border-t border-zinc-200">
            <%= if Enum.empty?(@rooms) do %>
              <div class="px-4 py-8 text-center text-zinc-500">
                No active rooms at the moment
              </div>
            <% else %>
              <table class="min-w-full divide-y divide-zinc-200">
                <thead class="bg-zinc-50">
                  <tr>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Room Code
                    </th>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Name
                    </th>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Status
                    </th>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Players
                    </th>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Host
                    </th>
                    <th
                      scope="col"
                      class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                    >
                      Created
                    </th>
                    <th scope="col" class="relative px-6 py-3">
                      <span class="sr-only">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-zinc-200">
                  <%= for room <- @rooms do %>
                    <tr>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <div class="text-sm font-medium text-zinc-900">{room.code}</div>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <div class="text-sm text-zinc-900">
                          {get_in(room, [:metadata, :name]) || "Game #{room.code}"}
                        </div>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <span class={"px-2 inline-flex text-xs leading-5 font-semibold rounded-full #{status_color(room.status)}"}>
                          {room.status}
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {length(room.player_ids)} / 4
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {room.host_id |> String.slice(0..7)}...
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {format_time(room.created_at)}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
                        <div class="flex justify-end space-x-3">
                          <%= if room.status == :playing do %>
                            <.link
                              navigate={~p"/dev/games/#{room.code}"}
                              class="text-indigo-600 hover:text-indigo-900"
                            >
                              Watch
                            </.link>
                          <% end %>
                          <button
                            type="button"
                            phx-click="request_delete"
                            phx-value-code={room.code}
                            class="text-red-600 hover:text-red-900"
                          >
                            Delete
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
        
    <!-- Auto-refresh indicator -->
        <div class="mt-4 text-center text-sm text-zinc-500">
          <span class="inline-flex items-center">
            <span class="h-2 w-2 bg-green-500 rounded-full mr-2 animate-pulse"></span>
            Live updates enabled
          </span>
        </div>
        
    <!-- Confirmation Modal -->
        <%= if @show_confirm_modal do %>
          <div
            class="fixed z-10 inset-0 overflow-y-auto"
            aria-labelledby="modal-title"
            role="dialog"
            aria-modal="true"
          >
            <div class="flex items-end justify-center min-h-screen pt-4 px-4 pb-20 text-center sm:block sm:p-0">
              <div
                class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity"
                aria-hidden="true"
                phx-click="cancel_confirm"
              >
              </div>

              <span class="hidden sm:inline-block sm:align-middle sm:h-screen" aria-hidden="true">
                &#8203;
              </span>

              <div class="inline-block align-bottom bg-white rounded-lg px-4 pt-5 pb-4 text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:align-middle sm:max-w-lg sm:w-full sm:p-6">
                <div class="sm:flex sm:items-start">
                  <div class="mx-auto flex-shrink-0 flex items-center justify-center h-12 w-12 rounded-full bg-red-100 sm:mx-0 sm:h-10 sm:w-10">
                    <svg
                      class="h-6 w-6 text-red-600"
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                      aria-hidden="true"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                      />
                    </svg>
                  </div>
                  <div class="mt-3 text-center sm:mt-0 sm:ml-4 sm:text-left">
                    <h3 class="text-lg leading-6 font-medium text-gray-900" id="modal-title">
                      Confirm Delete
                    </h3>
                    <div class="mt-2">
                      <p class="text-sm text-gray-500">
                        {@confirm_message}
                      </p>
                    </div>
                  </div>
                </div>
                <div class="mt-5 sm:mt-4 sm:flex sm:flex-row-reverse">
                  <button
                    type="button"
                    phx-click="confirm_delete"
                    class="w-full inline-flex justify-center rounded-md border border-transparent shadow-sm px-4 py-2 bg-red-600 text-base font-medium text-white hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500 sm:ml-3 sm:w-auto sm:text-sm"
                  >
                    Confirm
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_confirm"
                    class="mt-3 w-full inline-flex justify-center rounded-md border border-gray-300 shadow-sm px-4 py-2 bg-white text-base font-medium text-gray-700 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 sm:mt-0 sm:w-auto sm:text-sm"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Private functions

  defp assign_rooms_and_stats(socket, rooms) do
    filtered_rooms = filter_rooms_by_phase(rooms, socket.assigns.phase_filter)
    sorted_rooms = sort_rooms(filtered_rooms, socket.assigns.sort_order)
    stats = calculate_stats(rooms, length(sorted_rooms))

    socket
    |> assign(:rooms, sorted_rooms)
    |> assign(:stats, stats)
  end

  defp filter_rooms_by_phase(rooms, :all), do: rooms

  defp filter_rooms_by_phase(rooms, phase) do
    Enum.filter(rooms, &(&1.status == phase))
  end

  defp sort_rooms(rooms, :desc) do
    Enum.sort_by(rooms, & &1.created_at, {:desc, DateTime})
  end

  defp sort_rooms(rooms, :asc) do
    Enum.sort_by(rooms, & &1.created_at, {:asc, DateTime})
  end

  defp calculate_stats(rooms, filtered_count) do
    %{
      total: length(rooms),
      waiting: Enum.count(rooms, &(&1.status == :waiting)),
      playing: Enum.count(rooms, &(&1.status == :playing)),
      finished: Enum.count(rooms, &(&1.status == :finished)),
      filtered: filtered_count
    }
  end

  defp parse_bot_count(nil), do: 0
  defp parse_bot_count(""), do: 0

  defp parse_bot_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} -> count
      :error -> 0
    end
  end

  defp parse_bot_count(value) when is_integer(value), do: value

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

  defp format_time(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%H:%M:%S")

      _ ->
        "N/A"
    end
  end

  defp start_bots_if_needed(room_code, bot_count, bot_difficulty) when bot_count > 0 do
    strategy = String.to_existing_atom(bot_difficulty)
    BotManager.start_bots(room_code, bot_count, strategy)
  end

  defp start_bots_if_needed(_room_code, _bot_count, _bot_difficulty), do: :ok

  defp handle_single_delete(socket) do
    room_code = socket.assigns.room_to_delete

    case RoomManager.close_room(room_code) do
      :ok ->
        {:noreply,
         socket
         |> close_modal()
         |> put_flash(:info, "Game #{room_code} deleted successfully")}

      {:error, :room_not_found} ->
        {:noreply,
         socket
         |> close_modal()
         |> put_flash(:error, "Game #{room_code} not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> close_modal()
         |> put_flash(:error, "Failed to delete game: #{inspect(reason)}")}
    end
  end

  defp handle_bulk_delete(socket) do
    all_rooms = RoomManager.list_rooms(:all)
    finished_rooms = Enum.filter(all_rooms, &(&1.status == :finished))

    results =
      Enum.map(finished_rooms, fn room ->
        RoomManager.close_room(room.code)
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 != :ok))

    socket = close_modal(socket)

    socket =
      if success_count > 0 do
        put_flash(
          socket,
          :info,
          "Successfully deleted #{success_count} finished game#{if success_count > 1, do: "s", else: ""}"
        )
      else
        socket
      end

    socket =
      if error_count > 0 do
        put_flash(
          socket,
          :error,
          "Failed to delete #{error_count} game#{if error_count > 1, do: "s", else: ""}"
        )
      else
        socket
      end

    {:noreply, socket}
  end

  defp close_modal(socket) do
    socket
    |> assign(:show_confirm_modal, false)
    |> assign(:confirm_action, nil)
    |> assign(:confirm_message, "")
    |> assign(:room_to_delete, nil)
  end
end
