defmodule PidroServerWeb.GameMonitorLive do
  use PidroServerWeb, :live_view
  alias PidroServer.Games.{RoomManager, GameAdapter}

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

        {:ok,
         socket
         |> assign(:room, room)
         |> assign(:room_code, room_code)
         |> assign(:game_state, game_state)
         |> assign(:page_title, "Game Monitor - #{room_code}")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Room not found")
         |> redirect(to: ~p"/admin/lobby")}
    end
  end

  @impl true
  def handle_info({:state_update, new_state}, socket) do
    {:noreply, assign(socket, :game_state, new_state)}
  end

  @impl true
  def handle_info({:game_over, _winner, _scores}, socket) do
    # Reload the game state to get the final state
    game_state = get_game_state(socket.assigns.room_code)

    {:noreply,
     socket
     |> assign(:game_state, game_state)
     |> put_flash(:info, "Game Over!")}
  end

  @impl true
  def handle_info({:room_updated, room}, socket) do
    {:noreply, assign(socket, :room, room)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-7xl">
        <!-- Header -->
        <div class="mb-8">
          <.link
            navigate={~p"/admin/lobby"}
            class="text-sm text-indigo-600 hover:text-indigo-900 mb-2 inline-block"
          >
            ← Back to Lobby
          </.link>
          <h1 class="text-4xl font-bold text-zinc-900">
            Game Monitor - {@room_code}
          </h1>
          <p class="mt-2 text-lg text-zinc-600">Real-time game state viewer (read-only)</p>
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
              <h3 class="text-lg leading-6 font-medium text-zinc-900 inline">
                Full Game State (JSON)
              </h3>
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

  # Private functions

  defp get_game_state(room_code) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} -> state
      {:error, _} -> nil
    end
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

  defp format_suit(suit) do
    case suit do
      :hearts -> "♥️ Hearts"
      :diamonds -> "♦️ Diamonds"
      :clubs -> "♣️ Clubs"
      :spades -> "♠️ Spades"
      _ -> inspect(suit)
    end
  end
end
