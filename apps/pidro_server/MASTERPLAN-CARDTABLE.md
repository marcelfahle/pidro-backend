# Phase 3: Card Table UI - Implementation Plan

**Insert After**: Phase 2 (Bot System, Event Log, Quick Actions)  
**Priority**: HIGH - Blocking effective testing  
**Effort**: Medium (3-4 days)  
**Goal**: Visual card table that enables intuitive gameplay testing

---

## Executive Summary

### Why This Is Blocking

The current Dev UI has all the plumbing (bots work, events log, actions execute) but no visual representation of the game. Developers must:

- Read raw JSON to see hands
- Pick actions from tuple lists like `{:play_card, {14, :hearts}}`
- Imagine the card table layout mentally

This phase adds the visual layer that transforms the debug panel into a playable interface.

### What We're Building

```
┌─────────────────────────────────────────────────────────────────┐
│                         NORTH                                   │
│                    [?][?][?][?][?][?]                           │
│                      (hidden/bot)                               │
├─────────────────┬───────────────────────────┬───────────────────┤
│      WEST       │       TRICK AREA          │       EAST        │
│   [?][?][?][?]  │                           │   [?][?][?][?]    │
│                 │    ┌────┐     ┌────┐      │                   │
│                 │    │ N  │     │ E  │      │                   │
│                 │    │ K♥ │     │ 9♥ │      │                   │
│                 │    └────┘     └────┘      │                   │
│                 │    ┌────┐     ┌────┐      │                   │
│                 │    │ W  │     │ S  │      │                   │
│                 │    │ -- │     │ A♥ │      │                   │
│                 │    └────┘     └────┘      │                   │
├─────────────────┴───────────────────────────┴───────────────────┤
│                         SOUTH (You)                             │
│           [J♥][10♥][5♥★][5♦★][4♥][2♥]                          │
│            ↑ click to play                                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## FR-15: Card Table UI (0% complete)

**Prerequisites**: FR-4 Position Switching, FR-9 Action Execution  
**Blocks**: Effective manual testing  
**Complexity**: Medium - New visual components, minimal backend changes

---

### Task Group A: Card Component

#### DEV-1501: Create base card component

- **Description**: Reusable Phoenix component for rendering a single playing card
- **Visual design**:
  ```
  ┌─────┐
  │ A   │  <- rank top-left
  │  ♥  │  <- suit center (colored)
  │   A │  <- rank bottom-right
  └─────┘
  ```
- **Props**:
  - `card` - `{rank, suit}` tuple or nil (for face-down)
  - `face_down` - boolean, show card back
  - `playable` - boolean, highlight as clickable
  - `trump` - boolean, show trump indicator (border/glow)
  - `points` - integer, show point badge if > 0
  - `size` - `:sm | :md | :lg` for different contexts
- **Styling**:
  - Red text for hearts/diamonds
  - Black text for clubs/spades
  - Yellow/gold border for trump cards
  - Blue highlight ring for playable cards
  - Point badge in corner: `[1]` or `[5]`
- **Files**:
  - `lib/pidro_server_web/components/card_components.ex`
- **Effort**: 2h

**Implementation**:

```elixir
defmodule PidroServerWeb.CardComponents do
  use Phoenix.Component

  @suits %{hearts: "♥", diamonds: "♦", clubs: "♣", spades: "♠"}
  @ranks %{14 => "A", 13 => "K", 12 => "Q", 11 => "J"}

  attr :card, :any, required: true  # {rank, suit} or nil
  attr :face_down, :boolean, default: false
  attr :playable, :boolean, default: false
  attr :trump, :boolean, default: false
  attr :points, :integer, default: 0
  attr :size, :atom, default: :md
  attr :on_click, :any, default: nil

  def card(assigns) do
    ~H"""
    <div
      class={card_classes(@face_down, @playable, @trump, @size)}
      phx-click={@on_click && "play_card"}
      phx-value-card={@card && encode_card(@card)}
    >
      <%= if @face_down do %>
        <div class="card-back bg-blue-800 rounded flex items-center justify-center">
          <span class="text-blue-200 text-2xl">🂠</span>
        </div>
      <% else %>
        <div class="relative h-full flex flex-col justify-between p-1">
          <div class={suit_color(@card)}><%= format_rank(@card) %></div>
          <div class={["text-center text-xl", suit_color(@card)]}><%= format_suit(@card) %></div>
          <div class={["text-right", suit_color(@card)]}><%= format_rank(@card) %></div>
          <%= if @points > 0 do %>
            <div class="absolute -top-1 -right-1 bg-yellow-400 text-black text-xs rounded-full w-4 h-4 flex items-center justify-center font-bold">
              <%= @points %>
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
    base = "rounded shadow border bg-white"
    size_class = case size do
      :sm -> "w-8 h-12 text-xs"
      :md -> "w-12 h-16 text-sm"
      :lg -> "w-16 h-24 text-base"
    end
    trump_class = if trump and not face_down, do: "ring-2 ring-yellow-400", else: "border-gray-300"
    playable_class = if playable, do: "cursor-pointer hover:ring-2 hover:ring-blue-500 hover:-translate-y-1 transition-transform", else: ""
    face_down_class = if face_down, do: "bg-blue-800", else: ""

    [base, size_class, trump_class, playable_class, face_down_class] |> Enum.join(" ")
  end

  defp suit_color({_rank, suit}) when suit in [:hearts, :diamonds], do: "text-red-600"
  defp suit_color(_), do: "text-gray-900"

  defp format_rank({rank, _suit}), do: Map.get(@ranks, rank, to_string(rank))
  defp format_suit({_rank, suit}), do: Map.get(@suits, suit, "?")

  defp encode_card({rank, suit}), do: "#{rank}:#{suit}"
end
```

**Acceptance Criteria**:

- [ ] Card displays rank and suit correctly
- [ ] Colors correct (red for hearts/diamonds)
- [ ] Trump cards have visible indicator
- [ ] Point badges show on A, J, 10, 5, 2
- [ ] Face-down cards show card back
- [ ] Playable cards have hover effect
- [ ] Click triggers phx-click event

---

#### DEV-1502: Create hand component

- **Description**: Row of cards representing a player's hand
- **Props**:
  - `cards` - list of `{rank, suit}` tuples
  - `position` - `:north | :south | :east | :west`
  - `is_current_turn` - boolean, highlight if active
  - `is_human` - boolean, show human indicator
  - `show_cards` - boolean, face-up or face-down
  - `legal_plays` - list of playable cards (for highlighting)
  - `trump_suit` - atom, to mark trump cards
  - `is_cold` - boolean, player has gone cold
- **Layout**:
  - Horizontal row with slight overlap (-margin)
  - Position label above/below
  - Turn indicator (arrow or highlight)
  - "COLD" badge if player eliminated
- **Files**:
  - `lib/pidro_server_web/components/card_components.ex` (add to same file)
- **Effort**: 1.5h

**Implementation**:

```elixir
attr :cards, :list, required: true
attr :position, :atom, required: true
attr :is_current_turn, :boolean, default: false
attr :is_human, :boolean, default: false
attr :show_cards, :boolean, default: true
attr :legal_plays, :list, default: []
attr :trump_suit, :atom, default: nil
attr :is_cold, :boolean, default: false
attr :orientation, :atom, default: :horizontal  # :horizontal or :vertical

def hand(assigns) do
  ~H"""
  <div class={hand_container_classes(@position, @is_current_turn)}>
    <div class="flex items-center gap-2 mb-1">
      <span class="font-medium text-sm"><%= position_label(@position) %></span>
      <%= if @is_human do %>
        <span class="text-blue-500 text-xs">👤 You</span>
      <% end %>
      <%= if @is_current_turn do %>
        <span class="text-green-500 text-xs animate-pulse">← Turn</span>
      <% end %>
      <%= if @is_cold do %>
        <span class="bg-blue-200 text-blue-800 text-xs px-1 rounded">COLD</span>
      <% end %>
    </div>

    <%= if @is_cold do %>
      <div class="text-gray-400 italic text-sm">No cards remaining</div>
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

defp hand_container_classes(position, is_current_turn) do
  base = "p-2 rounded"
  turn = if is_current_turn, do: "bg-green-50 ring-2 ring-green-300", else: "bg-gray-50"
  [base, turn] |> Enum.join(" ")
end

defp cards_row_classes(:horizontal), do: "flex gap-1"
defp cards_row_classes(:vertical), do: "flex flex-col gap-1"

# Helper to sort cards: trump first, then by rank descending
defp sort_hand(cards, trump_suit) do
  Enum.sort_by(cards, fn {rank, suit} ->
    trump_priority = if is_trump?({rank, suit}, trump_suit), do: 0, else: 1
    {trump_priority, -rank}
  end)
end
```

**Acceptance Criteria**:

- [ ] Hand displays all cards in a row
- [ ] Cards sorted sensibly (trump first, high to low)
- [ ] Current turn has visible highlight
- [ ] Cold players show "COLD" badge
- [ ] Legal plays are clickable
- [ ] Human player indicated

---

#### DEV-1503: Create trick area component

- **Description**: Central area showing cards played to current trick
- **Props**:
  - `trick` - list of `%{position: atom, card: tuple}`
  - `leader` - position that led the trick
  - `winner` - position winning so far (highest card)
  - `trump_suit` - for highlighting trump plays
- **Layout**:
  - 2x2 grid representing table positions
  - Empty slot = waiting for play
  - Leader indicated with "Led" label
  - Current winner highlighted
- **Files**:
  - `lib/pidro_server_web/components/card_components.ex`
- **Effort**: 1.5h

**Implementation**:

```elixir
attr :trick, :list, default: []  # [%{position: :north, card: {14, :hearts}}, ...]
attr :leader, :atom, default: nil
attr :winner, :atom, default: nil
attr :trump_suit, :atom, default: nil
attr :trick_number, :integer, default: 0
attr :points_in_trick, :integer, default: 0

def trick_area(assigns) do
  trick_map = Map.new(assigns.trick, fn %{position: p, card: c} -> {p, c} end)
  assigns = assign(assigns, :trick_map, trick_map)

  ~H"""
  <div class="bg-green-100 rounded-lg p-4 min-h-[200px]">
    <div class="text-center text-sm text-gray-600 mb-2">
      Trick #<%= @trick_number %>
      <%= if @points_in_trick > 0 do %>
        <span class="text-yellow-600 font-medium">(<%= @points_in_trick %> pts)</span>
      <% end %>
    </div>

    <!-- 2x2 Grid for trick cards -->
    <div class="grid grid-cols-3 grid-rows-3 gap-2 place-items-center max-w-[200px] mx-auto">
      <!-- Row 1: North -->
      <div class="col-start-2">
        <.trick_slot
          position={:north}
          card={@trick_map[:north]}
          is_leader={@leader == :north}
          is_winner={@winner == :north}
          trump_suit={@trump_suit}
        />
      </div>

      <!-- Row 2: West, Center, East -->
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
        <!-- Empty center or table decoration -->
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

      <!-- Row 3: South -->
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
      <div class="absolute -top-4 left-1/2 -translate-x-1/2 text-xs text-gray-500">Led</div>
    <% end %>

    <div class={[
      "w-14 h-20 rounded border-2 border-dashed flex items-center justify-center",
      @is_winner && "ring-2 ring-green-500",
      @card && "border-solid border-gray-300 bg-white" || "border-gray-300 bg-gray-50"
    ]}>
      <%= if @card do %>
        <.card
          card={@card}
          trump={is_trump?(@card, @trump_suit)}
          points={point_value(@card, @trump_suit)}
          size={:md}
        />
      <% else %>
        <span class="text-gray-400 text-xs"><%= String.first(to_string(@position)) |> String.upcase() %></span>
      <% end %>
    </div>

    <%= if @is_winner and @card do %>
      <div class="absolute -bottom-4 left-1/2 -translate-x-1/2 text-xs text-green-600 font-medium">Winner</div>
    <% end %>
  </div>
  """
end
```

**Acceptance Criteria**:

- [ ] Shows 4 slots in compass layout
- [ ] Played cards appear in correct slot
- [ ] Empty slots show position indicator
- [ ] Leader marked with "Led" label
- [ ] Current winner highlighted
- [ ] Points in trick displayed

---

### Task Group B: Card Table Layout

#### DEV-1504: Create card table layout component

- **Description**: Full table layout combining all hands and trick area
- **Structure**:
  ```
  ┌─────────────────────────────────────────┐
  │              North Hand                 │
  ├─────────┬───────────────────┬───────────┤
  │  West   │    Trick Area     │   East    │
  │  Hand   │                   │   Hand    │
  ├─────────┴───────────────────┴───────────┤
  │              South Hand                 │
  └─────────────────────────────────────────┘
  ```
- **Props**:
  - `game_state` - full game state
  - `selected_position` - which position human is playing
  - `god_mode` - boolean, show all hands
  - `legal_actions` - for highlighting playable cards
- **Files**:
  - `lib/pidro_server_web/components/card_components.ex`
- **Effort**: 2h

**Implementation**:

```elixir
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
    <!-- North -->
    <div class="flex justify-center mb-4">
      <.hand
        cards={get_hand(@game_state, :north)}
        position={:north}
        is_current_turn={@game_state.current_turn == :north}
        is_human={@selected_position == :north}
        show_cards={@god_mode or @selected_position == :north}
        legal_plays={if @selected_position == :north, do: @legal_plays, else: []}
        trump_suit={@game_state.trump_suit}
        is_cold={player_is_cold?(@game_state, :north)}
      />
    </div>

    <!-- West - Trick - East -->
    <div class="flex justify-between items-center mb-4">
      <div class="flex-1">
        <.hand
          cards={get_hand(@game_state, :west)}
          position={:west}
          is_current_turn={@game_state.current_turn == :west}
          is_human={@selected_position == :west}
          show_cards={@god_mode or @selected_position == :west}
          legal_plays={if @selected_position == :west, do: @legal_plays, else: []}
          trump_suit={@game_state.trump_suit}
          is_cold={player_is_cold?(@game_state, :west)}
          orientation={:vertical}
        />
      </div>

      <div class="flex-1 mx-4">
        <.trick_area
          trick={@game_state.current_trick || []}
          leader={trick_leader(@game_state)}
          winner={trick_winner(@game_state)}
          trump_suit={@game_state.trump_suit}
          trick_number={(@game_state.tricks_played || 0) + 1}
          points_in_trick={calculate_trick_points(@game_state.current_trick, @game_state.trump_suit)}
        />
      </div>

      <div class="flex-1">
        <.hand
          cards={get_hand(@game_state, :east)}
          position={:east}
          is_current_turn={@game_state.current_turn == :east}
          is_human={@selected_position == :east}
          show_cards={@god_mode or @selected_position == :east}
          legal_plays={if @selected_position == :east, do: @legal_plays, else: []}
          trump_suit={@game_state.trump_suit}
          is_cold={player_is_cold?(@game_state, :east)}
          orientation={:vertical}
        />
      </div>
    </div>

    <!-- South -->
    <div class="flex justify-center">
      <.hand
        cards={get_hand(@game_state, :south)}
        position={:south}
        is_current_turn={@game_state.current_turn == :south}
        is_human={@selected_position == :south}
        show_cards={@god_mode or @selected_position == :south}
        legal_plays={if @selected_position == :south, do: @legal_plays, else: []}
        trump_suit={@game_state.trump_suit}
        is_cold={player_is_cold?(@game_state, :south)}
      />
    </div>

    <!-- Game info bar -->
    <div class="mt-4 bg-green-900 rounded p-2 text-white text-sm flex justify-between">
      <span>Trump: <%= format_trump(@game_state.trump_suit) %></span>
      <span>Hand #<%= @game_state.hand_number || 1 %></span>
      <span>N/S: <%= get_score(@game_state, :north_south) %> | E/W: <%= get_score(@game_state, :east_west) %></span>
    </div>
  </div>
  """
end

# Helper functions
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

defp player_is_cold?(state, position) do
  get_in(state, [:players, position, :cold]) || false
end

defp trick_leader(state) do
  case state.current_trick do
    [%{position: leader} | _] -> leader
    _ -> nil
  end
end

defp trick_winner(state) do
  # Calculate current winning position based on highest trump
  # This would use Pidro.Core.Trick logic
  nil  # Implement with engine call
end

defp calculate_trick_points(nil, _), do: 0
defp calculate_trick_points(trick, trump_suit) do
  trick
  |> Enum.map(fn %{card: card} -> point_value(card, trump_suit) end)
  |> Enum.sum()
end

defp format_trump(nil), do: "Not declared"
defp format_trump(suit), do: "#{Map.get(@suits, suit, "?")} #{suit}"

defp get_score(state, team) do
  get_in(state, [:cumulative_scores, team]) || 0
end
```

**Acceptance Criteria**:

- [ ] All 4 hands displayed in correct positions
- [ ] Trick area centered between hands
- [ ] Opponent hands hidden (unless god mode)
- [ ] Human's hand fully visible
- [ ] Trump and score info displayed
- [ ] Responsive to window size

---

#### DEV-1505: Integrate card table into GameDetailLive

- **Description**: Replace current state display with visual card table
- **Changes**:
  - Add card table above existing panels
  - Show card table only during `:playing` phase
  - Keep existing panels (event log, state inspector) below
  - Wire up card clicks to action execution
- **Files**:
  - `lib/pidro_server_web/live/dev/game_detail_live.ex`
- **Effort**: 2h

**Implementation approach**:

```elixir
# In game_detail_live.ex template

# Add card table section (show during playing phase)
<%= if @game_state && @game_state.phase == :playing do %>
  <div class="mb-6">
    <.card_table
      game_state={@game_state}
      selected_position={@selected_position}
      god_mode={@selected_position == :all}
      legal_actions={@legal_actions}
    />
  </div>
<% end %>

# Handle card click event
def handle_event("play_card", %{"card" => card_string}, socket) do
  [rank, suit] = String.split(card_string, ":")
  card = {String.to_integer(rank), String.to_existing_atom(suit)}
  action = {:play_card, card}

  # Use existing action execution logic
  execute_action(socket, action)
end
```

**Acceptance Criteria**:

- [ ] Card table appears during playing phase
- [ ] Clicking playable card executes action
- [ ] State updates after card play
- [ ] Existing panels still work
- [ ] Smooth transition between phases

---

#### DEV-1506: Add phase-specific displays

- **Description**: Visual displays for non-playing phases (bidding, declaring)
- **Components**:
  - **Bidding display**: Show bid buttons + current bid status
  - **Trump selection**: Show 4 suit buttons with card counts
  - **Scoring display**: Show hand results before next hand
- **Files**:
  - `lib/pidro_server_web/components/card_components.ex`
  - `lib/pidro_server_web/live/dev/game_detail_live.ex`
- **Effort**: 2h

**Implementation**:

```elixir
# Bidding phase display
attr :current_bid, :integer, default: nil
attr :bidder, :atom, default: nil
attr :legal_actions, :list, default: []
attr :bid_history, :list, default: []

def bidding_panel(assigns) do
  ~H"""
  <div class="bg-white rounded-lg p-4 shadow">
    <h3 class="font-bold mb-2">Bidding Phase</h3>

    <div class="mb-4">
      <%= if @current_bid do %>
        <p>Current bid: <span class="font-bold"><%= @current_bid %></span> by <%= @bidder %></p>
      <% else %>
        <p class="text-gray-500">No bids yet</p>
      <% end %>
    </div>

    <div class="flex flex-wrap gap-2">
      <%= for action <- @legal_actions do %>
        <%= case action do %>
          <% {:bid, amount} -> %>
            <button
              phx-click="execute_action"
              phx-value-action={"bid:#{amount}"}
              class="px-3 py-2 bg-blue-500 text-white rounded hover:bg-blue-600"
            >
              Bid <%= amount %>
            </button>
          <% :pass -> %>
            <button
              phx-click="execute_action"
              phx-value-action="pass"
              class="px-3 py-2 bg-gray-300 text-gray-700 rounded hover:bg-gray-400"
            >
              Pass
            </button>
          <% _ -> %>
        <% end %>
      <% end %>
    </div>

    <div class="mt-4 text-sm text-gray-600">
      <p class="font-medium">Bid History:</p>
      <%= for {position, bid} <- @bid_history do %>
        <p><%= position %>: <%= format_bid(bid) %></p>
      <% end %>
    </div>
  </div>
  """
end

# Trump selection display
attr :legal_actions, :list, default: []
attr :hand, :list, default: []

def trump_selection_panel(assigns) do
  suit_counts = count_suits(assigns.hand)
  assigns = assign(assigns, :suit_counts, suit_counts)

  ~H"""
  <div class="bg-white rounded-lg p-4 shadow">
    <h3 class="font-bold mb-2">Choose Trump Suit</h3>
    <p class="text-sm text-gray-600 mb-4">You won the bid! Select the trump suit.</p>

    <div class="grid grid-cols-2 gap-4">
      <%= for {:declare_trump, suit} <- @legal_actions do %>
        <button
          phx-click="execute_action"
          phx-value-action={"declare_trump:#{suit}"}
          class={["p-4 rounded-lg border-2 hover:border-blue-500", suit_button_color(suit)]}
        >
          <div class="text-3xl"><%= suit_symbol(suit) %></div>
          <div class="text-sm"><%= suit %></div>
          <div class="text-xs text-gray-500"><%= @suit_counts[suit] || 0 %> cards</div>
        </button>
      <% end %>
    </div>
  </div>
  """
end

defp suit_symbol(:hearts), do: "♥"
defp suit_symbol(:diamonds), do: "♦"
defp suit_symbol(:clubs), do: "♣"
defp suit_symbol(:spades), do: "♠"

defp suit_button_color(suit) when suit in [:hearts, :diamonds], do: "text-red-600"
defp suit_button_color(_), do: "text-gray-900"

defp count_suits(hand) do
  Enum.frequencies_by(hand, fn {_rank, suit} -> suit end)
end
```

**Acceptance Criteria**:

- [ ] Bidding phase shows bid buttons
- [ ] Trump selection shows suit buttons with card counts
- [ ] Scoring phase shows results
- [ ] Transitions smoothly between phases

---

### Task Group C: Helper Functions & Polish

#### DEV-1507: Add card utility functions

- **Description**: Helper functions for card rendering shared across components
- **Functions**:
  - `is_trump?/2` - check if card is trump (including wrong 5)
  - `point_value/2` - get point value considering trump
  - `compare_cards/3` - which card wins
  - `sort_hand/2` - sort cards for display
- **Files**:
  - `lib/pidro_server_web/components/card_helpers.ex`
- **Effort**: 1h

**Implementation**:

```elixir
defmodule PidroServerWeb.CardHelpers do
  @moduledoc """
  Helper functions for card display and logic in Dev UI.
  Wraps Pidro.Core.Card functions for template use.
  """

  alias Pidro.Core.Card

  @doc "Check if card is trump (including wrong 5)"
  def is_trump?({rank, suit}, trump_suit) when is_atom(trump_suit) do
    Card.is_trump?({rank, suit}, trump_suit)
  end
  def is_trump?(_, nil), do: false

  @doc "Get point value of card"
  def point_value({rank, suit}, trump_suit) do
    if is_trump?({rank, suit}, trump_suit) do
      case rank do
        14 -> 1  # Ace
        11 -> 1  # Jack
        10 -> 1  # Ten
        5 -> 5   # Either Pedro
        2 -> 1   # Two
        _ -> 0
      end
    else
      0
    end
  end

  @doc "Sort hand for display: trump first, then by rank descending"
  def sort_hand(cards, trump_suit) do
    Enum.sort_by(cards, fn card ->
      is_trump = is_trump?(card, trump_suit)
      {rank, _suit} = card

      # Trump cards first (priority 0), then non-trump (priority 1)
      # Within each group, sort by rank descending
      trump_priority = if is_trump, do: 0, else: 1
      {trump_priority, -rank}
    end)
  end

  @doc "Format card for display"
  def format_card({rank, suit}) do
    "#{format_rank(rank)}#{suit_symbol(suit)}"
  end

  defp format_rank(14), do: "A"
  defp format_rank(13), do: "K"
  defp format_rank(12), do: "Q"
  defp format_rank(11), do: "J"
  defp format_rank(n), do: to_string(n)

  defp suit_symbol(:hearts), do: "♥"
  defp suit_symbol(:diamonds), do: "♦"
  defp suit_symbol(:clubs), do: "♣"
  defp suit_symbol(:spades), do: "♠"
end
```

**Acceptance Criteria**:

- [ ] Functions work correctly with engine types
- [ ] Wrong 5 correctly identified as trump
- [ ] Point values match Finnish Pidro rules
- [ ] Hand sorting logical and consistent

---

#### DEV-1508: Add responsive styling and polish

- **Description**: Make card table look good and work at different sizes
- **Tasks**:
  - Responsive breakpoints for smaller screens
  - Card size adjustments based on viewport
  - Animation on card play
  - Hover states and transitions
- **Files**:
  - `assets/css/card_table.css` (or Tailwind classes)
  - `lib/pidro_server_web/components/card_components.ex`
- **Effort**: 1.5h

**Acceptance Criteria**:

- [ ] Card table usable at 1024px width
- [ ] Cards scale appropriately
- [ ] Animations feel responsive
- [ ] Visual polish (shadows, transitions)

---

## Phase 3 Validation

### Manual Test Flow

1. Navigate to `/dev/games`
2. Create game: "Card Table Test", 3 bots
3. Game appears in list
4. Click game to open detail
5. **Bidding**: See bid buttons, make a bid
6. Wait for bots to bid
7. **Trump**: See suit selection with card counts
8. Select a trump suit
9. **Playing**: See card table with all hands
10. See your cards face-up, opponents face-down
11. Click a legal (highlighted) card to play
12. Watch bots play their cards
13. See trick winner indicated
14. Play through entire hand
15. **Scoring**: See hand results
16. Verify game continues to next hand

### Quality Gates

- [ ] All DEV-15XX tasks complete
- [ ] Manual test flow works end-to-end
- [ ] Card table displays correctly
- [ ] Card clicks execute actions
- [ ] All phases have appropriate UI
- [ ] `mix format` clean
- [ ] `mix credo` clean
- [ ] No console errors

---

## Files Created (Phase 3)

```
lib/pidro_server_web/components/card_components.ex    # Card, hand, trick, table components
lib/pidro_server_web/components/card_helpers.ex       # Utility functions
assets/css/card_table.css                             # Optional custom styles
```

## Files Modified (Phase 3)

```
lib/pidro_server_web/live/dev/game_detail_live.ex     # Integrate card table
lib/pidro_server_web/components/core_components.ex    # Import card components (optional)
```

---

## Dependencies

- **DEV-1501** (card component) - No deps, start here
- **DEV-1502** (hand) - Depends on DEV-1501
- **DEV-1503** (trick area) - Depends on DEV-1501
- **DEV-1504** (card table) - Depends on DEV-1502, DEV-1503
- **DEV-1505** (integration) - Depends on DEV-1504
- **DEV-1506** (phase displays) - Depends on DEV-1505
- **DEV-1507** (helpers) - No deps, can be done in parallel
- **DEV-1508** (polish) - Depends on all above

**Suggested Order**: DEV-1507 → DEV-1501 → DEV-1502 → DEV-1503 → DEV-1504 → DEV-1505 → DEV-1506 → DEV-1508

---

## Effort Summary

| Task                        | Effort     | Priority |
| --------------------------- | ---------- | -------- |
| DEV-1501: Card component    | 2h         | P0       |
| DEV-1502: Hand component    | 1.5h       | P0       |
| DEV-1503: Trick area        | 1.5h       | P0       |
| DEV-1504: Card table layout | 2h         | P0       |
| DEV-1505: Integration       | 2h         | P0       |
| DEV-1506: Phase displays    | 2h         | P1       |
| DEV-1507: Helper functions  | 1h         | P0       |
| DEV-1508: Polish            | 1.5h       | P2       |
| **Total**                   | **~13.5h** |          |

**Estimated Duration**: 3-4 days with testing and iteration

---

## Next Steps After Phase 3

With the card table complete, the original Phase 3 items become Phase 4:

- FR-5: Multi-View Mode (split screen)
- FR-12: Bot Observation (reasoning display)
- FR-13: Hand Replay
- FR-14: Game Analytics

And original Phase 4 (Polish) becomes Phase 5.

---

**Document Status**: ✅ Ready for Implementation  
**Insert Into**: MASTERPLAN-DEVUI.md after Phase 2 section  
**Next Action**: Start with DEV-1507 (helpers) and DEV-1501 (card component)
