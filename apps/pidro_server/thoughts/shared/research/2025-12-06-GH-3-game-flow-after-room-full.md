---
date: 2025-12-06T15:06:17+0000
researcher: Assistant
git_commit: 0f96ff47bfea61b9ad81115b7d0f057853e3ba0c
branch: main
repository: marcelfahle/pidro-backend
topic: "Game Flow After All Four Players Join - What Happens Next?"
tags: [research, codebase, game-flow, game-channel, dealing, bidding, websocket-events, client-state]
status: complete
last_updated: 2025-12-06
last_updated_by: Assistant
github_issue: https://github.com/marcelfahle/pidro-backend/issues/3
related_research: thoughts/shared/research/2025-12-06-GH-3-player-seat-selection.md
---

# Research: Game Flow After All Four Players Join

**Date**: 2025-12-06T15:06:17+0000
**Researcher**: Assistant
**Git Commit**: 0f96ff47bfea61b9ad81115b7d0f057853e3ba0c
**Branch**: main
**Repository**: marcelfahle/pidro-backend
**Related**: [Player Seat Selection Research](./2025-12-06-GH-3-player-seat-selection.md)

## Research Question

What happens when all four players have joined a room? How does the game continue? What UI/data does the game client need to show the table with cards and start the dealing/bidding phases?

## Summary

When the 4th player joins a room, the backend automatically:

1. **Transitions room status** from `:waiting` → `:ready` → `:playing`
2. **Starts a game process** (`Pidro.Server` GenServer) via DynamicSupervisor
3. **Initializes game state** in `:dealer_selection` phase
4. **Auto-progresses** through dealer selection → dealing → bidding (first three phases are automatic)
5. **Broadcasts state updates** to all connected WebSocket clients via PubSub

The client receives the full game state on channel join containing:
- Current phase (`:dealer_selection`, `:dealing`, `:bidding`, etc.)
- All players with their hands (cards), positions, and teams
- Bidding state (bids array, highest bid, bidding team)
- Current turn indicator
- Scores (hand points and cumulative)

After receiving this state, the client should render the appropriate UI based on the `phase` field.

---

## Detailed Findings

### Component 1: Game Start Trigger (When 4th Player Joins)

**Location**: `lib/pidro_server/games/room_manager.ex:536-572`

When `join_room/2` is called for the 4th player:

```elixir
# Line 536-540
updated_player_ids = room.player_ids ++ [player_id]
player_count = length(updated_player_ids)

# Auto-transition when room is full
new_status = if player_count == @max_players, do: :ready, else: :waiting
```

**Status Transition**: `:waiting` → `:ready`

Then at lines 565-570:
```elixir
final_state =
  if new_status == :ready do
    start_game_for_room(updated_room, new_state)
  else
    new_state
  end
```

### Component 2: Game Process Creation

**Location**: `lib/pidro_server/games/room_manager.ex:1094-1116`

`start_game_for_room/2` orchestrates game process creation:

1. Calls `GameSupervisor.start_game(room.code)` at line 1098
2. On success, updates room status to `:playing` at line 1102
3. Broadcasts room update to PubSub topics

**Location**: `lib/pidro_server/games/game_supervisor.ex:72-100`

```elixir
def start_game(room_code) do
  game_opts = [name: GameRegistry.via(room_code)]

  child_spec = %{
    id: Pidro.Server,
    start: {Pidro.Server, :start_link, [game_opts]},
    restart: :temporary
  }

  DynamicSupervisor.start_child(__MODULE__, child_spec)
end
```

**Status Transition**: `:ready` → `:playing`

### Component 3: Initial Game State

**Location**: `apps/pidro_engine/lib/pidro/core/gamestate.ex:59-124`

`GameState.new/0` creates the initial state with:

```elixir
%GameState{
  phase: :dealer_selection,    # First phase
  hand_number: 1,
  variant: :finnish,
  players: %{
    north: %Player{position: :north, team: :north_south, hand: [], ...},
    east:  %Player{position: :east,  team: :east_west,   hand: [], ...},
    south: %Player{position: :south, team: :north_south, hand: [], ...},
    west:  %Player{position: :west,  team: :east_west,   hand: [], ...}
  },
  current_dealer: nil,
  current_turn: nil,
  deck: [],
  bids: [],
  highest_bid: nil,
  trump_suit: nil,
  cumulative_scores: %{north_south: 0, east_west: 0},
  config: %{
    min_bid: 6,
    max_bid: 14,
    winning_score: 62,
    initial_deal_count: 9,
    final_hand_size: 6
  }
}
```

### Component 4: Automatic Phase Transitions

**Location**: `apps/pidro_engine/lib/pidro/game/engine.ex:491-698`

The game engine automatically handles several phases without player action:

| Phase | Auto? | What Happens |
|-------|-------|--------------|
| `:dealer_selection` | Yes | Simulates deck cutting, selects dealer randomly |
| `:dealing` | Yes | Deals 9 cards to each player |
| `:bidding` | **No** | Players must bid/pass (first interactive phase) |
| `:declaring` | **No** | Bid winner declares trump suit |
| `:discarding` | Yes | Non-trump cards auto-discarded |
| `:second_deal` | Yes | Cards dealt to bring hands to 6 |
| `:playing` | **No** | Trick-taking (main gameplay) |
| `:scoring` | Yes | Calculate and apply scores |

**Key**: The first phase requiring user input is `:bidding`.

### Component 5: Game State Sent to Clients

**Location**: `lib/pidro_server_web/channels/game_channel.ex:145-154`

When a player joins the GameChannel, they receive:

```elixir
reply_data = %{
  state: state,           # Full GameState struct
  role: role,             # :player or :spectator
  reconnected: join_type == :reconnect,
  position: position      # :north, :east, :south, :west (players only)
}
```

**Full State Structure** (JSON format for client):

```json
{
  "state": {
    "phase": "bidding",
    "hand_number": 1,
    "variant": "finnish",
    "current_turn": "east",
    "current_dealer": "north",
    "players": {
      "north": {
        "position": "north",
        "team": "north_south",
        "hand": [
          {"rank": 14, "suit": "hearts"},
          {"rank": 10, "suit": "spades"},
          ...
        ],
        "eliminated?": false,
        "revealed_cards": [],
        "tricks_won": 0
      },
      "east": { ... },
      "south": { ... },
      "west": { ... }
    },
    "bids": [
      {"position": "north", "amount": 7}
    ],
    "highest_bid": {"position": "north", "amount": 7},
    "bidding_team": "north_south",
    "trump_suit": null,
    "tricks": [],
    "current_trick": null,
    "trick_number": 0,
    "hand_points": {"north_south": 0, "east_west": 0},
    "cumulative_scores": {"north_south": 0, "east_west": 0},
    "winner": null,
    "config": {
      "min_bid": 6,
      "max_bid": 14,
      "winning_score": 62,
      "initial_deal_count": 9,
      "final_hand_size": 6
    }
  },
  "role": "player",
  "position": "east",
  "reconnected": false
}
```

### Component 6: WebSocket Events for Game Flow

**Location**: `lib/pidro_server_web/channels/game_channel.ex`

#### Incoming Events (Client → Server)

| Event | Payload | Phase |
|-------|---------|-------|
| `"bid"` | `{"amount": 8}` or `{"amount": "pass"}` | `:bidding` |
| `"declare_trump"` | `{"suit": "hearts"}` | `:declaring` |
| `"play_card"` | `{"card": {"rank": 14, "suit": "spades"}}` | `:playing` |
| `"ready"` | `{}` | Any (signals player ready) |

#### Outgoing Events (Server → Client)

| Event | Payload | When Sent |
|-------|---------|-----------|
| `"game_state"` | `{state: GameState}` | After any game action |
| `"game_over"` | `{winner: team, scores: map}` | Game completion |
| `"player_ready"` | `{position: atom}` | Player signals ready |
| `"player_reconnected"` | `{user_id, position}` | Player reconnects |
| `"player_disconnected"` | `{user_id, position, reason, grace_period}` | Player disconnects |
| `"presence_state"` | Presence map | On channel join |
| `"presence_diff"` | `{joins, leaves}` | Presence changes |

### Component 7: Bidding Phase Flow

**Location**: `apps/pidro_engine/lib/pidro/game/bidding.ex`

1. **Bidding starts** with player left of dealer (`current_turn`)
2. **Legal actions** calculated per player:
   - Bid amounts: minimum bid (6 or highest+1) through 14
   - Pass: allowed except dealer when all others passed
3. **Each player** either bids higher or passes
4. **Bidding completes** when all 4 players have acted
5. **Winner** (highest bidder) enters `:declaring` phase

**Client can request legal actions via**: `GameAdapter.get_legal_actions(room_code, position)`

Returns: `[{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]`

### Component 8: The Complete Flow Timeline

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. HTTP: 4th player joins                                               │
│    POST /api/v1/rooms/{code}/join                                       │
│    → Room status: :waiting → :ready                                     │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. RoomManager starts game process                                      │
│    → GameSupervisor.start_game(room_code)                               │
│    → Pidro.Server GenServer started                                     │
│    → Room status: :ready → :playing                                     │
│    → Initial phase: :dealer_selection                                   │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 3. All 4 players join WebSocket channel                                 │
│    GameChannel.join("game:{room_code}", %{}, socket)                    │
│    → Each receives: {state, role, position, reconnected}                │
│    → Presence tracked for all players                                   │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 4. AUTO: Dealer selection (no user action needed)                       │
│    → Random dealer selected via simulated deck cut                      │
│    → Phase: :dealer_selection → :dealing                                │
│    → Event: {:dealer_selected, position, card}                          │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 5. AUTO: Initial deal (no user action needed)                           │
│    → 9 cards dealt to each player (3 cards × 3 rounds)                  │
│    → Phase: :dealing → :bidding                                         │
│    → Event: {:cards_dealt, %{position => [cards]}}                      │
│    → current_turn set to player left of dealer                          │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 6. INTERACTIVE: Bidding phase                                           │
│    → Client shows bidding UI                                            │
│    → current_turn indicates whose turn                                  │
│    → Each player: bid(amount) or pass                                   │
│    → Broadcast "game_state" after each action                           │
│    → Phase: :bidding → :declaring (when complete)                       │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 7. INTERACTIVE: Trump declaration                                       │
│    → Bid winner declares trump suit                                     │
│    → Client: declare_trump(suit)                                        │
│    → Phase: :declaring → :discarding                                    │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 8. AUTO: Discarding & Second Deal                                       │
│    → Non-trump cards auto-discarded                                     │
│    → Cards dealt to bring hands to 6                                    │
│    → Dealer "robs the pack"                                             │
│    → Phase: :discarding → :second_deal → :playing                       │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 9. INTERACTIVE: Playing phase (trick-taking)                            │
│    → Players play cards in turn order                                   │
│    → Client: play_card(card)                                            │
│    → 6 tricks total                                                     │
│    → Phase: :playing → :scoring (when all tricks complete)              │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 10. AUTO: Scoring                                                       │
│    → Points tallied                                                     │
│    → Check if game over (team reached 62)                               │
│    → If not over: Phase → :dealing (next hand)                          │
│    → If over: Phase → :game_over, broadcast winner                      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## What the Client UI Needs to Show

### Phase: `:dealer_selection` / `:dealing` (Auto)
- **Loading/transition screen** - These phases are automatic and brief
- Show "Selecting dealer..." or "Dealing cards..."
- No user interaction needed

### Phase: `:bidding`
- **Game table** with 4 positions (N/E/S/W)
- **Player's hand** (9 cards from `state.players[position].hand`)
- **Bid history** from `state.bids` array
- **Current highest bid** from `state.highest_bid`
- **Whose turn** indicator from `state.current_turn`
- **Bid controls** (if it's this player's turn):
  - Bid buttons (min bid to 14)
  - Pass button (unless dealer and all others passed)

### Phase: `:declaring`
- Same table view
- **Trump selection UI** (if this player won the bid)
- Four suit buttons: Hearts, Diamonds, Clubs, Spades

### Phase: `:playing`
- **Game table** with 4 positions
- **Player's hand** (6 cards)
- **Current trick** area in center showing played cards
- **Trump suit indicator**
- **Whose turn** indicator
- **Trick history** / points accumulated
- **Score display** (hand points and cumulative)
- Card selection for playing (highlight legal plays)

### Phase: `:game_over`
- **Final scores** display
- **Winner announcement** (North/South or East/West)
- **Play again** button

---

## Code References

### Game Start Flow
- `lib/pidro_server/games/room_manager.ex:536-572` - 4th player join triggers game start
- `lib/pidro_server/games/room_manager.ex:1094-1116` - `start_game_for_room/2`
- `lib/pidro_server/games/game_supervisor.ex:72-100` - `start_game/1`
- `apps/pidro_engine/lib/pidro/server.ex:270-283` - `Pidro.Server.init/1`
- `apps/pidro_engine/lib/pidro/core/gamestate.ex:59-124` - `GameState.new/0`

### Channel & State
- `lib/pidro_server_web/channels/game_channel.ex:75-169` - Channel join flow
- `lib/pidro_server_web/channels/game_channel.ex:145-154` - Join reply structure
- `lib/pidro_server_web/channels/game_channel.ex:253-256` - State broadcast
- `lib/pidro_server/games/game_adapter.ex:315-340` - `broadcast_state_update/2`

### Game Actions
- `lib/pidro_server_web/channels/game_channel.ex:185-239` - handle_in for game actions
- `lib/pidro_server/games/game_adapter.ex:70-92` - `apply_action/3`
- `apps/pidro_engine/lib/pidro/game/engine.ex:119-127` - Engine dispatch

### Phases
- `apps/pidro_engine/lib/pidro/game/dealing.ex:227-265` - Card dealing
- `apps/pidro_engine/lib/pidro/game/bidding.ex:206-240` - Bid handling
- `apps/pidro_engine/lib/pidro/game/trump.ex` - Trump declaration
- `apps/pidro_engine/lib/pidro/game/tricks.ex` - Trick-taking

---

## Key Patterns

1. **Automatic Phase Handling**: The engine auto-progresses through dealer selection, dealing, discarding, and second deal without requiring any client action.

2. **State-Driven UI**: The client should use `state.phase` to determine which UI to render. All necessary data is in the state object.

3. **Turn-Based with current_turn**: Check `state.current_turn == myPosition` to enable action buttons.

4. **Real-time Updates**: Subscribe to `"game_state"` events to update UI after any game action.

5. **Position-Agnostic State**: All players receive the full game state including other players' hands. The client should decide what to show/hide based on game rules.

---

## Related Research

- [Player Seat Selection Research](./2025-12-06-GH-3-player-seat-selection.md) - How players join rooms and get positions assigned

## Open Questions

1. **Card visibility**: Should the client hide other players' cards, or does the server send filtered state per player?
   - Current: Server sends full state; client should implement visibility rules

2. **Animation timing**: How long should auto-phases (dealing, discarding) display before transitioning?
   - Consider adding artificial delays or animation states client-side

3. **Reconnection during auto-phases**: If a player disconnects during dealing, what state do they rejoin to?
   - Current: They receive whatever phase the game is currently in
