defmodule PidroServerWeb.Dev.AnalyticsLive do
  @moduledoc """
  Development analytics dashboard for monitoring server metrics and game statistics.

  This LiveView provides real-time analytics including:
  - Server status and uptime
  - Game statistics (total rooms, active games, waiting rooms, finished games)
  - Room status breakdown
  - System information

  The dashboard subscribes to lobby updates and refreshes metrics every second
  for live monitoring during development.
  """

  use PidroServerWeb, :live_view
  alias PidroServer.Games.RoomManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to lobby updates for live stats
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
      # Schedule periodic refresh for uptime and other metrics
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Analytics Dashboard")
     |> assign(:uptime_start, DateTime.utc_now())
     |> assign(:current_time, DateTime.utc_now())
     |> load_stats()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :current_time, DateTime.utc_now())}
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket) do
    # Reload stats whenever lobby updates
    {:noreply, load_stats(socket)}
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
            ← Back to Games
          </.link>
          <h1 class="text-4xl font-bold text-zinc-900">Development Analytics</h1>
          <p class="mt-2 text-lg text-zinc-600">Real-time server metrics and performance</p>
          <div class="mt-3 text-sm text-zinc-500 bg-blue-50 border border-blue-200 rounded-md p-3">
            This is a development analytics dashboard. More metrics coming in Phase 2.
          </div>
        </div>
        
    <!-- Server Status -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Server Status</h3>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-3">
              <div>
                <dt class="text-sm font-medium text-zinc-500">Status</dt>
                <dd class="mt-1">
                  <span class="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800">
                    Running
                  </span>
                </dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Uptime</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {format_uptime(@uptime_start, @current_time)}
                </dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Current Time (UTC)</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {Calendar.strftime(@current_time, "%Y-%m-%d %H:%M:%S")}
                </dd>
              </div>
            </dl>
          </div>
        </div>
        
    <!-- Game Statistics -->
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4 mb-8">
          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Total Rooms</dt>
              <dd class="mt-1 text-3xl font-semibold text-zinc-900">{@stats.total_rooms}</dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Active Games</dt>
              <dd class="mt-1 text-3xl font-semibold text-green-600">{@stats.active_games}</dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Waiting Rooms</dt>
              <dd class="mt-1 text-3xl font-semibold text-yellow-600">
                {@stats.waiting_rooms}
              </dd>
            </div>
          </div>

          <div class="bg-white overflow-hidden shadow rounded-lg">
            <div class="px-4 py-5 sm:p-6">
              <dt class="text-sm font-medium text-zinc-500 truncate">Finished Games</dt>
              <dd class="mt-1 text-3xl font-semibold text-blue-600">
                {@stats.finished_games}
              </dd>
            </div>
          </div>
        </div>
        
    <!-- Room Status Breakdown -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg mb-8">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">Room Status Breakdown</h3>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <div class="space-y-4">
              <%= for {status, count} <- @stats.by_status do %>
                <div>
                  <div class="flex items-center justify-between mb-1">
                    <span class="text-sm font-medium text-zinc-700 capitalize">{status}</span>
                    <span class="text-sm text-zinc-500">{count} rooms</span>
                  </div>
                  <div class="w-full bg-zinc-200 rounded-full h-2">
                    <div
                      class={"h-2 rounded-full #{status_bar_color(status)}"}
                      style={"width: #{calculate_percentage(count, @stats.total_rooms)}%"}
                    >
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- System Information -->
        <div class="bg-white shadow overflow-hidden sm:rounded-lg">
          <div class="px-4 py-5 sm:px-6">
            <h3 class="text-lg leading-6 font-medium text-zinc-900">System Information</h3>
          </div>
          <div class="border-t border-zinc-200 px-4 py-5 sm:p-6">
            <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
              <div>
                <dt class="text-sm font-medium text-zinc-500">Elixir Version</dt>
                <dd class="mt-1 text-sm text-zinc-900">{System.version()}</dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">OTP Version</dt>
                <dd class="mt-1 text-sm text-zinc-900">{:erlang.system_info(:otp_release)}</dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Total Processes</dt>
                <dd class="mt-1 text-sm text-zinc-900">{:erlang.system_info(:process_count)}</dd>
              </div>
              <div>
                <dt class="text-sm font-medium text-zinc-500">Memory Usage</dt>
                <dd class="mt-1 text-sm text-zinc-900">
                  {format_memory(:erlang.memory(:total))}
                </dd>
              </div>
            </dl>
          </div>
        </div>
        
    <!-- Auto-refresh indicator -->
        <div class="mt-4 text-center text-sm text-zinc-500">
          <span class="inline-flex items-center">
            <span class="h-2 w-2 bg-green-500 rounded-full mr-2 animate-pulse"></span>
            Live updates enabled (refreshing every second)
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Private functions

  defp load_stats(socket) do
    rooms = RoomManager.list_rooms(:all)

    by_status =
      rooms
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, rooms_list} -> {status, length(rooms_list)} end)
      |> Enum.into(%{})

    stats = %{
      total_rooms: length(rooms),
      active_games: Enum.count(rooms, &(&1.status == :playing)),
      waiting_rooms: Enum.count(rooms, &(&1.status == :waiting)),
      finished_games: Enum.count(rooms, &(&1.status == :finished)),
      by_status: by_status
    }

    assign(socket, :stats, stats)
  end

  defp format_uptime(start_time, current_time) do
    diff = DateTime.diff(current_time, start_time, :second)

    hours = div(diff, 3600)
    minutes = div(rem(diff, 3600), 60)
    seconds = rem(diff, 60)

    "#{hours}h #{minutes}m #{seconds}s"
  end

  defp calculate_percentage(count, total) when total > 0 do
    Float.round(count / total * 100, 1)
  end

  defp calculate_percentage(_count, _total), do: 0

  defp status_bar_color(status) do
    case status do
      :waiting -> "bg-yellow-500"
      :ready -> "bg-blue-500"
      :playing -> "bg-green-500"
      :finished -> "bg-gray-500"
      :closed -> "bg-red-500"
      _ -> "bg-gray-300"
    end
  end

  defp format_memory(bytes) do
    mb = bytes / 1_024 / 1_024
    "#{Float.round(mb, 2)} MB"
  end
end
