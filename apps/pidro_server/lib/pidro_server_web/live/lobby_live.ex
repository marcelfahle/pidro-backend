defmodule PidroServerWeb.LobbyLive do
  use PidroServerWeb, :live_view
  alias PidroServer.Games.RoomManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to lobby updates
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    end

    rooms = RoomManager.list_rooms(:all)
    stats = calculate_stats(rooms)

    {:ok,
     socket
     |> assign(:rooms, rooms)
     |> assign(:stats, stats)
     |> assign(:page_title, "Lobby Monitor")}
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket) do
    # RoomManager broadcasts the full list of available rooms
    # We need all rooms (not just available), so refetch
    rooms = RoomManager.list_rooms(:all)
    stats = calculate_stats(rooms)
    {:noreply, socket |> assign(:rooms, rooms) |> assign(:stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-4 py-10 sm:px-6 sm:py-28 lg:px-8 xl:px-28 xl:py-32">
      <div class="mx-auto max-w-7xl">
        <div class="mb-8">
          <h1 class="text-4xl font-bold text-zinc-900">Pidro Server - Lobby Monitor</h1>
          <p class="mt-2 text-lg text-zinc-600">Real-time overview of all game rooms</p>
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
        
    <!-- Rooms Table -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Active Rooms</h3>
            <p class="mt-1 max-w-2xl text-sm text-zinc-500">
              Live updates from all game rooms
            </p>
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
                        <span class={"px-2 inline-flex text-xs leading-5 font-semibold rounded-full #{status_color(room.status)}"}>
                          {room.status}
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {PidroServer.Games.Room.Positions.count(room)} / 4
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {room.host_id |> String.slice(0..7)}...
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                        {format_time(room.created_at)}
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
                        <%= if room.status == :playing do %>
                          <.link
                            navigate={~p"/admin/games/#{room.code}"}
                            class="text-indigo-600 hover:text-indigo-900"
                          >
                            Watch
                          </.link>
                        <% end %>
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
      </div>
    </div>
    """
  end

  # Private functions

  defp calculate_stats(rooms) do
    %{
      total: length(rooms),
      waiting: Enum.count(rooms, &(&1.status == :waiting)),
      playing: Enum.count(rooms, &(&1.status == :playing)),
      finished: Enum.count(rooms, &(&1.status == :finished))
    }
  end

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
end
