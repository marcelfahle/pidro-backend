# Pidro Game Engine Action Types & Formats

Complete reference for all action types supported by the Pidro.Server game engine (FR-9 Implementation Reference).

## Action Type Overview

The engine supports **4 main action types**:
1. **Pass** - Pass during bidding
2. **Bid** - Make a bid during bidding phase
3. **Declare Trump** - Declare trump suit after winning bid
4. **Play Card** - Play a card during play phase

## Action Format Summary

| Action Type | Format | Example | Phase |
|------------|--------|---------|-------|
| Pass | Atom | `:pass` | Bidding |
| Bid | Tuple | `{:bid, 8}` | Bidding |
| Declare Trump | Tuple | `{:declare_trump, :hearts}` | Declaring |
| Play Card | Tuple | `{:play_card, {14, :spades}}` | Playing |

---

## 1. Pass Action

**Format**: `:pass` (atom)

**Phase**: Bidding

**Description**: Player passes their turn during bidding phase

**Example**:
```elixir
GameAdapter.apply_action("A3F9", :east, :pass)
```

**WebSocket Event**:
```json
{
  "event": "bid",
  "payload": {
    "amount": "pass"
  }
}
```

**Legal Actions Return**:
```elixir
{:ok, [:pass, {:bid, 6}, {:bid, 7}, ..., {:bid, 14}]}
```

---

## 2. Bid Action

**Format**: `{:bid, amount}` (tuple)

**Phase**: Bidding

**Parameters**:
- `amount` (integer): Bid value from 6 to 14

**Validation**:
- Must be higher than current bid
- Must be between 6 and 14
- Must be player's turn
- Cannot bid after passing

**Example**:
```elixir
GameAdapter.apply_action("A3F9", :north, {:bid, 8})
GameAdapter.apply_action("A3F9", :south, {:bid, 10})
```

**WebSocket Event**:
```json
{
  "event": "bid",
  "payload": {
    "amount": 8
  }
}
```

**Legal Actions Return**:
```elixir
# When current bid is 7
{:ok, [:pass, {:bid, 8}, {:bid, 9}, {:bid, 10}, {:bid, 11}, {:bid, 12}, {:bid, 13}, {:bid, 14}]}

# When no bids yet
{:ok, [:pass, {:bid, 6}, {:bid, 7}, ..., {:bid, 14}]}
```

---

## 3. Declare Trump Action

**Format**: `{:declare_trump, suit}` (tuple)

**Phase**: Declaring

**Parameters**:
- `suit` (atom): One of `:hearts`, `:diamonds`, `:clubs`, `:spades`

**Validation**:
- Must be the bidding winner
- Must be in declaring phase
- Must be a valid suit atom

**Example**:
```elixir
GameAdapter.apply_action("A3F9", :south, {:declare_trump, :hearts})
GameAdapter.apply_action("A3F9", :north, {:declare_trump, :spades})
```

**WebSocket Event**:
```json
{
  "event": "declare_trump",
  "payload": {
    "suit": "hearts"
  }
}
```

**Legal Actions Return**:
```elixir
{:ok, [{:declare_trump, :hearts}, {:declare_trump, :diamonds}, {:declare_trump, :clubs}, {:declare_trump, :spades}]}
```

---

## 4. Play Card Action

**Format**: `{:play_card, {rank, suit}}` (nested tuple)

**Phase**: Playing

**Parameters**:
- `rank` (integer): Card rank (2-14, where 14=Ace, 13=King, etc.)
- `suit` (atom): One of `:hearts`, `:diamonds`, `:clubs`, `:spades`

**Card Format**: `{rank, suit}` where:
- 14 = Ace
- 13 = King
- 12 = Queen
- 11 = Jack
- 2-10 = Number cards

**Validation**:
- Card must be in player's hand
- Must follow suit if possible
- Must play trump if leading suit not in hand

**Example**:
```elixir
# Play Ace of Spades
GameAdapter.apply_action("A3F9", :west, {:play_card, {14, :spades}})

# Play 5 of Hearts
GameAdapter.apply_action("A3F9", :north, {:play_card, {5, :hearts}})

# Play Jack of Diamonds
GameAdapter.apply_action("A3F9", :east, {:play_card, {11, :diamonds}})
```

**WebSocket Event**:
```json
{
  "event": "play_card",
  "payload": {
    "card": {
      "rank": 14,
      "suit": "spades"
    }
  }
}
```

**Legal Actions Return**:
```elixir
# Returns list of playable cards from hand
{:ok, [
  {:play_card, {14, :spades}},
  {:play_card, {13, :spades}},
  {:play_card, {5, :hearts}},
  ...
]}
```

---

## Action Application Flow

### 1. Client → WebSocket Channel
```javascript
channel.push("bid", { amount: 8 })
channel.push("declare_trump", { suit: "hearts" })
channel.push("play_card", { card: { rank: 14, suit: "spades" } })
```

### 2. Channel → GameAdapter
```elixir
# In game_channel.ex
def handle_in("bid", %{"amount" => amount}, socket) do
  apply_game_action(socket, {:bid, amount})
end

def handle_in("declare_trump", %{"suit" => suit}, socket) do
  suit_atom = String.to_atom(suit)
  apply_game_action(socket, {:declare_trump, suit_atom})
end

def handle_in("play_card", %{"card" => %{"rank" => rank, "suit" => suit}}, socket) do
  suit_atom = String.to_atom(suit)
  card = {rank, suit_atom}
  apply_game_action(socket, {:play_card, card})
end
```

### 3. GameAdapter → Pidro.Server
```elixir
# In game_adapter.ex
def apply_action(room_code, position, action) do
  with {:ok, pid} <- GameRegistry.lookup(room_code) do
    Pidro.Server.apply_action(pid, position, action)
  end
end
```

### 4. Pidro.Server → Engine → State Machine
```elixir
# In server.ex (GenServer wrapper)
def handle_call({:apply_action, position, action}, _from, state) do
  case Pidro.Game.Engine.apply_action(state, position, action) do
    {:ok, new_state} -> {:reply, {:ok, new_state}, new_state}
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end
```

---

## Legal Actions API

### Get Legal Actions for Position
```elixir
GameAdapter.get_legal_actions("A3F9", :north)
```

**Returns**:
```elixir
# During bidding phase (current bid: 7)
{:ok, [:pass, {:bid, 8}, {:bid, 9}, {:bid, 10}, {:bid, 11}, {:bid, 12}, {:bid, 13}, {:bid, 14}]}

# During declaring phase
{:ok, [{:declare_trump, :hearts}, {:declare_trump, :diamonds}, {:declare_trump, :clubs}, {:declare_trump, :spades}]}

# During playing phase (cards in hand)
{:ok, [
  {:play_card, {14, :spades}},
  {:play_card, {13, :spades}},
  {:play_card, {5, :hearts}},
  {:play_card, {2, :diamonds}}
]}
```

---

## Quick Actions Support

**Current Status**: ❌ **NOT IMPLEMENTED**

The engine does **not** currently support:
- Auto-bid (automatic bidding for AI/bots)
- Auto-play (automatic card playing)
- Quick actions (shortcuts for common actions)

**Recommendation for FR-9**:
- These would need to be implemented as client-side features
- Server validates all actions normally
- No special "quick action" action type needed

---

## Error Handling

### Error Format
```elixir
{:error, reason}
```

### Common Error Reasons
```elixir
{:error, "Not your turn"}
{:error, "Invalid bid: must be higher than 7"}
{:error, "Card not in hand"}
{:error, "Must follow suit"}
{:error, "Invalid action for current phase"}
{:error, :not_found}  # Game not found
```

### WebSocket Error Response
```json
{
  "status": "error",
  "response": {
    "reason": "Not your turn"
  }
}
```

---

## Phase-Specific Action Constraints

| Phase | Allowed Actions | Current Player |
|-------|----------------|----------------|
| `dealer_selection` | None (automatic) | N/A |
| `dealing` | None (automatic) | N/A |
| `bidding` | `:pass`, `{:bid, N}` | Rotates (dealer starts) |
| `declaring` | `{:declare_trump, suit}` | Bid winner only |
| `discarding` | None (automatic) | N/A |
| `second_deal` | None (automatic) | N/A |
| `playing` | `{:play_card, card}` | Rotates (bid winner leads) |
| `scoring` | None (automatic) | N/A |
| `hand_complete` | None (automatic) | N/A |
| `complete` | None (game over) | N/A |

---

## Spectator Restrictions (FR-9 Relevant)

From `game_channel.ex`, spectators are **blocked** from all actions:

```elixir
if socket.assigns[:role] == :spectator do
  {:reply, {:error, %{reason: "spectators cannot make bids"}}, socket}
end
```

**Spectators cannot**:
- ✗ Make bids
- ✗ Declare trump
- ✗ Play cards
- ✗ Signal ready

**Spectators can**:
- ✓ Receive state updates
- ✓ View game state
- ✓ See all actions happening

---

## FR-9 Implementation Notes

### Action Broadcasting
When any action is applied:
1. Action validated by engine
2. State updated
3. Broadcast sent via PubSub: `{:state_update, new_state}`
4. All subscribers (players + spectators) receive update

### State Update Message Format
```elixir
Phoenix.PubSub.broadcast(
  PidroServer.PubSub,
  "game:#{room_code}",
  {:state_update, new_state}
)
```

### Client-Side Action Display
For spectators viewing actions, the client must:
1. Listen for `state_update` broadcasts
2. Diff previous state vs new state to detect action
3. Display action in UI (e.g., "North bid 8", "East played A♠")

**Action Detection Logic** (client-side needed):
```javascript
// Compare state.bids array to detect new bid
// Compare state.current_trick to detect card played
// Compare state.trump to detect trump declaration
// Compare state.phase transitions
```

---

## Complete Action Examples

### Full Bidding Round
```elixir
# North (dealer) starts
GameAdapter.apply_action("A3F9", :north, {:bid, 7})
# East passes
GameAdapter.apply_action("A3F9", :east, :pass)
# South raises
GameAdapter.apply_action("A3F9", :south, {:bid, 9})
# West passes
GameAdapter.apply_action("A3F9", :west, :pass)
# North passes
GameAdapter.apply_action("A3F9", :north, :pass)
# East already passed
# South wins with 9
```

### Trump Declaration & Card Play
```elixir
# South won bid, declares trump
GameAdapter.apply_action("A3F9", :south, {:declare_trump, :hearts})

# After discarding/dealing, South leads
GameAdapter.apply_action("A3F9", :south, {:play_card, {14, :hearts}})  # Ace of Hearts
GameAdapter.apply_action("A3F9", :west, {:play_card, {5, :hearts}})     # 5 of Hearts
GameAdapter.apply_action("A3F9", :north, {:play_card, {13, :hearts}})   # King of Hearts
GameAdapter.apply_action("A3F9", :east, {:play_card, {2, :hearts}})     # 2 of Hearts
# South wins trick with Ace
```

---

## Summary for FR-9

**Action Types**: 4 total (`:pass`, `{:bid, N}`, `{:declare_trump, suit}`, `{:play_card, card}`)

**Action Shape**: 
- Simple atom: `:pass`
- Tuples: `{:bid, N}`, `{:declare_trump, suit}`, `{:play_card, {rank, suit}}`

**Pass Action**: ✓ Exists (`:pass`)

**Quick Actions**: ✗ Not implemented (would need to be client-side feature)

**Spectator Support**: All actions blocked for spectators; they receive state updates only

**Client-Side Requirements for FR-9**:
1. Parse state updates to detect which action was taken
2. Display action in UI with proper formatting
3. Handle all 4 action types
4. Show legal actions for current player
5. Indicate when automatic transitions occur (dealing, scoring, etc.)
