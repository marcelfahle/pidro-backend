defmodule PidroServerWeb.CardComponents do
  @moduledoc """
  Visual card table components for Pidro game development UI.

  This module provides Phoenix LiveView components for rendering:
  - Individual playing cards (.card)
  - Player hands (.hand)
  - Trick area (.trick_area)
  - Complete card table (.card_table)
  - Phase-specific displays (.bidding_panel, .trump_selection_panel)

  These components are designed for the development UI and provide
  visual representations of game state for testing and debugging.

  ## Usage

  In your LiveView template:

      <.card_table
        game_state={@game_state}
        selected_position={@selected_position}
        god_mode={@selected_position == :all}
        legal_actions={@legal_actions}
      />
  """

  use Phoenix.Component
  import PidroServerWeb.CardHelpers

  # =============================================================================
  # Card Component
  # =============================================================================

  @doc """
  Renders a single playing card.

  ## Attributes

  - `card` - Card tuple `{rank, suit}` or `nil` for face-down
  - `face_down` - Boolean, show card back instead of face
  - `playable` - Boolean, highlight as clickable
  - `trump` - Boolean, show trump indicator (star)
  - `points` - Integer, show point badge if > 0
  - `size` - Atom, :sm | :md | :lg
  - `on_click` - Boolean, enable click handler

  ## Examples

      <.card card={{14, :hearts}} playable={true} trump={true} points={1} />
      <.card card={nil} face_down={true} />
  """
  attr :card, :any, required: true
  attr :face_down, :boolean, default: false
  attr :playable, :boolean, default: false
  attr :trump, :boolean, default: false
  attr :points, :integer, default: 0
  attr :size, :atom, default: :md
  attr :on_click, :boolean, default: false

  def card(assigns) do
    ~H"""
    <div
      class={card_classes(@face_down, @playable, @trump, @size)}
      phx-click={@on_click && "play_card"}
      phx-value-card={@card && encode_card(@card)}
    >
      <%= if @face_down do %>
        <div class="card-back bg-blue-800 rounded flex items-center justify-center h-full">
          <span class="text-blue-200 text-2xl">🂠</span>
        </div>
      <% else %>
        <div class="relative h-full flex flex-col justify-between p-1">
          <div class={suit_color(@card)}>
            {format_rank(elem(@card, 0))}
          </div>
          <div class={["text-center text-xl", suit_color(@card)]}>
            {suit_symbol(elem(@card, 1))}
          </div>
          <div class={["text-right", suit_color(@card)]}>
            {format_rank(elem(@card, 0))}
          </div>
          <%= if @points > 0 do %>
            <div class="absolute -top-1 -right-1 bg-yellow-400 text-black text-xs rounded-full w-4 h-4 flex items-center justify-center font-bold">
              {@points}
            </div>
          <% end %>
          <%= if @trump do %>
            <div class="absolute -bottom-1 -left-1 text-yellow-400 text-xs">★</div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp card_classes(face_down, playable, trump, size) do
    base = "rounded shadow border"
    size_class = size_class(size)
    bg_class = if face_down, do: "bg-blue-800", else: "bg-white"

    trump_class =
      if trump and not face_down, do: "ring-2 ring-yellow-400", else: "border-gray-300"

    playable_class =
      if playable,
        do:
          "cursor-pointer hover:ring-2 hover:ring-blue-500 hover:-translate-y-1 transition-transform",
        else: ""

    [base, size_class, bg_class, trump_class, playable_class]
  end

  defp size_class(:sm), do: "w-8 h-12 text-xs"
  defp size_class(:md), do: "w-12 h-16 text-sm"
  defp size_class(:lg), do: "w-16 h-24 text-base"

  # =============================================================================
  # Hand Component
  # =============================================================================

  @doc """
  Renders a player's hand of cards.

  ## Attributes

  - `cards` - List of card tuples
  - `position` - Player position (:north | :south | :east | :west)
  - `is_current_turn` - Boolean, highlight if active player
  - `is_human` - Boolean, show human indicator
  - `show_cards` - Boolean, face-up or face-down
  - `legal_plays` - List of playable cards (for highlighting)
  - `trump_suit` - Atom, to mark trump cards
  - `is_cold` - Boolean, player has gone cold
  - `orientation` - Atom, :horizontal or :vertical layout

  ## Examples

      <.hand
        cards={[{14, :hearts}, {13, :hearts}]}
        position={:south}
        is_current_turn={true}
        is_human={true}
        show_cards={true}
        legal_plays={[{14, :hearts}]}
        trump_suit={:hearts}
      />
  """
  attr :cards, :list, required: true
  attr :position, :atom, required: true
  attr :is_current_turn, :boolean, default: false
  attr :is_human, :boolean, default: false
  attr :show_cards, :boolean, default: true
  attr :legal_plays, :list, default: []
  attr :trump_suit, :atom, default: nil
  attr :is_cold, :boolean, default: false
  attr :orientation, :atom, default: :horizontal

  def hand(assigns) do
    ~H"""
    <div class={hand_container_classes(@is_current_turn)}>
      <div class="flex items-center gap-2 mb-1">
        <span class="font-medium text-sm text-white">{position_label(@position)}</span>
        <%= if @is_human do %>
          <span class="text-blue-300 text-xs">👤 You</span>
        <% end %>
        <%= if @is_current_turn do %>
          <span class="text-green-300 text-xs animate-pulse">← Turn</span>
        <% end %>
        <%= if @is_cold do %>
          <span class="bg-blue-200 text-blue-800 text-xs px-1 rounded">COLD</span>
        <% end %>
      </div>

      <%= if @is_cold do %>
        <div class="text-gray-300 italic text-sm">No cards remaining</div>
      <% else %>
        <div class={cards_row_classes(@orientation)}>
          <%= for card <- sort_hand(@cards, @trump_suit) do %>
            <.card
              card={card}
              face_down={not @show_cards}
              playable={card in @legal_plays}
              trump={is_trump?(card, @trump_suit)}
              points={point_value(card, @trump_suit)}
              size={:md}
              on_click={card in @legal_plays}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp position_label(:north), do: "North"
  defp position_label(:south), do: "South"
  defp position_label(:east), do: "East"
  defp position_label(:west), do: "West"

  defp hand_container_classes(is_current_turn) do
    base = "p-2 rounded"
    turn = if is_current_turn, do: "bg-green-900 ring-2 ring-green-400", else: "bg-gray-800"
    [base, turn]
  end

  defp cards_row_classes(:horizontal), do: "flex gap-1 flex-wrap"
  defp cards_row_classes(:vertical), do: "flex flex-col gap-1"

  # =============================================================================
  # Trick Area Component
  # =============================================================================

  @doc """
  Renders the central trick area showing cards played to current trick.

  ## Attributes

  - `trick` - List of maps with :position and :card keys
  - `leader` - Position that led the trick
  - `winner` - Position winning so far
  - `trump_suit` - For highlighting trump plays
  - `trick_number` - Current trick number
  - `points_in_trick` - Total points in current trick

  ## Examples

      <.trick_area
        trick={[%{position: :north, card: {14, :hearts}}]}
        leader={:north}
        winner={:north}
        trump_suit={:hearts}
        trick_number={1}
        points_in_trick={1}
      />
  """
  attr :trick, :list, default: []
  attr :leader, :atom, default: nil
  attr :winner, :atom, default: nil
  attr :trump_suit, :atom, default: nil
  attr :trick_number, :integer, default: 0
  attr :points_in_trick, :integer, default: 0

  def trick_area(assigns) do
    trick_map = Map.new(assigns.trick, fn %{position: p, card: c} -> {p, c} end)
    assigns = assign(assigns, :trick_map, trick_map)

    ~H"""
    <div class="bg-green-700 rounded-lg p-4 min-h-[200px]">
      <div class="text-center text-sm text-gray-200 mb-2">
        Trick #{@trick_number}
        <%= if @points_in_trick > 0 do %>
          <span class="text-yellow-300 font-medium">({@points_in_trick} pts)</span>
        <% end %>
      </div>
      <%!-- 2x2 Grid for trick cards --%>
      <div class="grid grid-cols-3 grid-rows-3 gap-2 place-items-center max-w-[200px] mx-auto">
        <%!-- Row 1: North --%>
        <div class="col-start-2">
          <.trick_slot
            position={:north}
            card={@trick_map[:north]}
            is_leader={@leader == :north}
            is_winner={@winner == :north}
            trump_suit={@trump_suit}
          />
        </div>
        <%!-- Row 2: West, Center, East --%>
        <div class="col-start-1 row-start-2">
          <.trick_slot
            position={:west}
            card={@trick_map[:west]}
            is_leader={@leader == :west}
            is_winner={@winner == :west}
            trump_suit={@trump_suit}
          />
        </div>
        <div class="col-start-2 row-start-2">
          <%!-- Empty center or table decoration --%>
        </div>
        <div class="col-start-3 row-start-2">
          <.trick_slot
            position={:east}
            card={@trick_map[:east]}
            is_leader={@leader == :east}
            is_winner={@winner == :east}
            trump_suit={@trump_suit}
          />
        </div>
        <%!-- Row 3: South --%>
        <div class="col-start-2 row-start-3">
          <.trick_slot
            position={:south}
            card={@trick_map[:south]}
            is_leader={@leader == :south}
            is_winner={@winner == :south}
            trump_suit={@trump_suit}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :position, :atom, required: true
  attr :card, :any, default: nil
  attr :is_leader, :boolean, default: false
  attr :is_winner, :boolean, default: false
  attr :trump_suit, :atom, default: nil

  defp trick_slot(assigns) do
    ~H"""
    <div class="relative">
      <%= if @is_leader do %>
        <div class="absolute -top-4 left-1/2 -translate-x-1/2 text-xs text-gray-300">Led</div>
      <% end %>

      <div class={[
        "w-14 h-20 rounded border-2 flex items-center justify-center",
        @is_winner && "ring-2 ring-green-400",
        (@card && "border-solid border-gray-400 bg-white") ||
          "border-dashed border-gray-400 bg-gray-700"
      ]}>
        <%= if @card do %>
          <.card
            card={@card}
            trump={is_trump?(@card, @trump_suit)}
            points={point_value(@card, @trump_suit)}
            size={:md}
          />
        <% else %>
          <span class="text-gray-400 text-xs">
            {String.first(to_string(@position)) |> String.upcase()}
          </span>
        <% end %>
      </div>

      <%= if @is_winner and @card do %>
        <div class="absolute -bottom-4 left-1/2 -translate-x-1/2 text-xs text-green-300 font-medium">
          Winner
        </div>
      <% end %>
    </div>
    """
  end

  # =============================================================================
  # Card Table Component
  # =============================================================================

  @doc """
  Renders the complete card table with all hands and trick area.

  ## Attributes

  - `game_state` - Full game state map
  - `selected_position` - Which position human is playing
  - `god_mode` - Boolean, show all hands
  - `legal_actions` - List of legal actions for highlighting

  ## Examples

      <.card_table
        game_state={@game_state}
        selected_position={:south}
        god_mode={false}
        legal_actions={@legal_actions}
      />
  """
  attr :game_state, :map, required: true
  attr :selected_position, :atom, default: :south
  attr :god_mode, :boolean, default: false
  attr :legal_actions, :list, default: []

  def card_table(assigns) do
    # Extract playable cards from legal actions
    legal_plays = extract_legal_plays(assigns.legal_actions)
    assigns = assign(assigns, :legal_plays, legal_plays)

    ~H"""
    <div class="bg-green-800 rounded-xl p-4 shadow-lg">
      <%!-- North --%>
      <div class="flex justify-center mb-4">
        <.hand
          cards={get_hand(@game_state, :north)}
          position={:north}
          is_current_turn={get_current_turn(@game_state) == :north}
          is_human={@selected_position == :north}
          show_cards={@god_mode or @selected_position == :north}
          legal_plays={if @selected_position == :north, do: @legal_plays, else: []}
          trump_suit={get_trump_suit(@game_state)}
          is_cold={player_is_cold?(@game_state, :north)}
        />
      </div>
      <%!-- West - Trick - East --%>
      <div class="flex justify-between items-start mb-4 gap-4">
        <div class="flex-1">
          <.hand
            cards={get_hand(@game_state, :west)}
            position={:west}
            is_current_turn={get_current_turn(@game_state) == :west}
            is_human={@selected_position == :west}
            show_cards={@god_mode or @selected_position == :west}
            legal_plays={if @selected_position == :west, do: @legal_plays, else: []}
            trump_suit={get_trump_suit(@game_state)}
            is_cold={player_is_cold?(@game_state, :west)}
            orientation={:vertical}
          />
        </div>

        <div class="flex-1">
          <.trick_area
            trick={get_current_trick(@game_state)}
            leader={trick_leader(@game_state)}
            winner={trick_winner(@game_state)}
            trump_suit={get_trump_suit(@game_state)}
            trick_number={get_trick_number(@game_state)}
            points_in_trick={
              calculate_trick_points(get_current_trick(@game_state), get_trump_suit(@game_state))
            }
          />
        </div>

        <div class="flex-1">
          <.hand
            cards={get_hand(@game_state, :east)}
            position={:east}
            is_current_turn={get_current_turn(@game_state) == :east}
            is_human={@selected_position == :east}
            show_cards={@god_mode or @selected_position == :east}
            legal_plays={if @selected_position == :east, do: @legal_plays, else: []}
            trump_suit={get_trump_suit(@game_state)}
            is_cold={player_is_cold?(@game_state, :east)}
            orientation={:vertical}
          />
        </div>
      </div>
      <%!-- South --%>
      <div class="flex justify-center">
        <.hand
          cards={get_hand(@game_state, :south)}
          position={:south}
          is_current_turn={get_current_turn(@game_state) == :south}
          is_human={@selected_position == :south}
          show_cards={@god_mode or @selected_position == :south}
          legal_plays={if @selected_position == :south, do: @legal_plays, else: []}
          trump_suit={get_trump_suit(@game_state)}
          is_cold={player_is_cold?(@game_state, :south)}
        />
      </div>
      <%!-- Game info bar --%>
      <div class="mt-4 bg-green-900 rounded p-2 text-white text-sm flex justify-between">
        <span>Trump: {format_trump(get_trump_suit(@game_state))}</span>
        <span>Hand #{get_hand_number(@game_state)}</span>
        <span>
          N/S: {get_score(@game_state, :north_south)} | E/W: {get_score(@game_state, :east_west)}
        </span>
      </div>
    </div>
    """
  end

  # =============================================================================
  # Bidding Panel Component
  # =============================================================================

  @doc """
  Renders bidding phase UI with bid buttons.

  ## Attributes

  - `current_bid` - Current high bid amount
  - `bidder` - Position that made the high bid
  - `legal_actions` - List of legal bidding actions
  - `bid_history` - List of previous bids

  ## Examples

      <.bidding_panel
        current_bid={8}
        bidder={:north}
        legal_actions={[{:bid, 9}, {:bid, 10}, :pass]}
        bid_history={[{:north, 8}, {:east, :pass}]}
      />
  """
  attr :current_bid, :integer, default: nil
  attr :bidder, :atom, default: nil
  attr :legal_actions, :list, default: []
  attr :bid_history, :list, default: []

  def bidding_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg p-4 shadow">
      <h3 class="font-bold mb-2 text-lg">Bidding Phase</h3>

      <div class="mb-4">
        <%= if @current_bid do %>
          <p>
            Current bid: <span class="font-bold text-xl">{@current_bid}</span> by {@bidder}
          </p>
        <% else %>
          <p class="text-gray-500">No bids yet</p>
        <% end %>
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        <%= for action <- @legal_actions do %>
          <%= case action do %>
            <% {:bid, amount} -> %>
              <button
                phx-click="execute_action"
                phx-value-action={"bid:#{amount}"}
                class="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600 font-medium"
              >
                Bid {amount}
              </button>
            <% :pass -> %>
              <button
                phx-click="execute_action"
                phx-value-action="pass"
                class="px-4 py-2 bg-gray-300 text-gray-700 rounded hover:bg-gray-400"
              >
                Pass
              </button>
            <% _ -> %>
          <% end %>
        <% end %>
      </div>

      <div class="text-sm text-gray-600">
        <p class="font-medium">Bid History:</p>
        <%= for {position, bid} <- @bid_history do %>
          <p>{position}: {format_bid(bid)}</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_bid(:pass), do: "Pass"
  defp format_bid(amount) when is_integer(amount), do: "Bid #{amount}"
  defp format_bid(_), do: "Unknown"

  # =============================================================================
  # Trump Selection Panel Component
  # =============================================================================

  @doc """
  Renders trump selection UI with suit buttons.

  ## Attributes

  - `legal_actions` - List of legal declare_trump actions
  - `hand` - Player's hand to show suit counts

  ## Examples

      <.trump_selection_panel
        legal_actions={[{:declare_trump, :hearts}, {:declare_trump, :spades}]}
        hand={[{14, :hearts}, {13, :hearts}, {5, :spades}]}
      />
  """
  attr :legal_actions, :list, default: []
  attr :hand, :list, default: []

  def trump_selection_panel(assigns) do
    suit_counts = count_suits(assigns.hand)
    assigns = assign(assigns, :suit_counts, suit_counts)

    ~H"""
    <div class="bg-white rounded-lg p-4 shadow">
      <h3 class="font-bold mb-2 text-lg">Choose Trump Suit</h3>
      <p class="text-sm text-gray-600 mb-4">You won the bid! Select the trump suit.</p>

      <div class="grid grid-cols-2 gap-4">
        <%= for {:declare_trump, suit} <- @legal_actions do %>
          <button
            phx-click="execute_action"
            phx-value-action={"declare_trump:#{suit}"}
            class={[
              "p-4 rounded-lg border-2 hover:border-blue-500 transition-colors",
              suit_button_color(suit)
            ]}
          >
            <div class="text-4xl">{suit_symbol(suit)}</div>
            <div class="text-sm font-medium">{suit}</div>
            <div class="text-xs text-gray-500">{Map.get(@suit_counts, suit, 0)} cards</div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp suit_button_color(suit) when suit in [:hearts, :diamonds],
    do: "text-red-600 border-red-300"

  defp suit_button_color(_), do: "text-gray-900 border-gray-300"

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp extract_legal_plays(actions) do
    actions
    |> Enum.filter(fn
      {:play_card, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:play_card, card} -> card end)
  end

  defp get_hand(state, position) do
    get_in(state, [:players, position, :hand]) || []
  end

  defp get_current_turn(state) do
    Map.get(state, :current_turn)
  end

  defp get_trump_suit(state) do
    Map.get(state, :trump_suit)
  end

  defp player_is_cold?(state, position) do
    get_in(state, [:players, position, :cold]) || false
  end

  defp get_current_trick(state) do
    case Map.get(state, :current_trick) do
      nil -> []
      trick when is_list(trick) -> trick
      _ -> []
    end
  end

  defp trick_leader(state) do
    case get_current_trick(state) do
      [%{position: leader} | _] -> leader
      _ -> nil
    end
  end

  defp trick_winner(_state) do
    # TODO: Calculate current winning position based on highest trump
    # This would use Pidro.Core.Trick logic
    nil
  end

  defp get_trick_number(state) do
    (Map.get(state, :tricks_played, 0) || 0) + 1
  end

  defp calculate_trick_points(trick, trump_suit) do
    trick
    |> Enum.map(fn
      %{card: card} -> point_value(card, trump_suit)
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp get_hand_number(state) do
    Map.get(state, :hand_number, 1) || 1
  end

  defp get_score(state, team) do
    get_in(state, [:cumulative_scores, team]) || 0
  end
end
