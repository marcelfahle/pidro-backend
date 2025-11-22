# FR-10 Quick Actions - Feasibility Assessment

**Analysis Date:** 2025-11-02  
**Status:** Analysis Complete  
**Overall Feasibility:** HIGH (80% achievable with current architecture)

---

## Executive Summary

The engine's event sourcing architecture via `Pidro.Game.Replay` provides excellent foundation for quick actions. Most features are feasible with minimal changes, though some require wrapper logic in the server layer.

---

## Quick Action Feasibility Breakdown

### 1. "Undo Last Action" ✅ FULLY FEASIBLE

**Status:** Already implemented in engine  
**Effort:** LOW (server wrapper needed)  
**Engine Support:** Complete

**What Exists:**
- `Pidro.Game.Replay.undo/1` - Returns state before last event
- Pure functional implementation via event replay
- Events stored in `state.events` list
- Performance: O(n) where n = number of events (acceptable for dev UI)

**Implementation Path:**
```elixir
# In GameAdapter
def undo_last_action(room_code) do
  with {:ok, pid} <- GameRegistry.lookup(room_code) do
    current_state = Pidro.Server.get_state(pid)
    case Pidro.Game.Replay.undo(current_state) do
      {:ok, previous_state} -> 
        # Update server state and broadcast
        Pidro.Server.set_state(pid, previous_state)
        broadcast_state_update(room_code, pid)
        {:ok, previous_state}
      {:error, :no_history} -> 
        {:error, "Nothing to undo"}
    end
  end
end
```

**Challenges:**
- Need `Pidro.Server.set_state/2` function (doesn't exist yet)
- Should limit to dev mode only (not production games)
- Multi-undo stack requires state management

**Recommendation:** ✅ Implement - High value, low effort

---

### 2. "Deal Next Hand" ✅ FEASIBLE

**Status:** Achievable via action sequence  
**Effort:** MEDIUM (requires game phase logic)  
**Engine Support:** Partial (needs wrapper)

**What Exists:**
- State machine tracks phases (`state.phase`)
- Can detect when hand is complete (phase == `:scoring` or `:complete`)
- Engine supports sequential action application

**Implementation Path:**
```elixir
def deal_next_hand(room_code) do
  with {:ok, pid} <- GameRegistry.lookup(room_code),
       state = Pidro.Server.get_state(pid) do
    
    case state.phase do
      :complete ->
        # Start new game
        {:ok, _new_state} = Pidro.Server.apply_action(pid, :system, :new_game)
        
      phase when phase in [:scoring, :playing] ->
        # Skip to scoring, then auto-advance to next deal
        {:ok, _state} = complete_current_hand(pid)
        {:ok, _state} = Pidro.Server.apply_action(pid, :system, :next_hand)
        
      _ ->
        {:error, "Cannot deal next hand in #{phase} phase"}
    end
  end
end
```

**Challenges:**
- Engine doesn't have `:new_game` or `:next_hand` system actions
- Need to define when a "hand" is complete vs "game" complete
- Scoring phase auto-advances, might interfere

**Recommendation:** ⚠️ Requires engine enhancement - Add system actions

---

### 3. "Complete Current Hand" ⚠️ FEASIBLE WITH BOT SUPPORT

**Status:** Requires bot player logic  
**Effort:** HIGH (bot AI needed)  
**Engine Support:** Good (action application works)

**What Exists:**
- `Engine.legal_actions/2` returns valid actions per position
- `GameAdapter.apply_action/3` processes actions sequentially
- No rate limiting currently (can rapid-fire actions)

**Implementation Path:**
```elixir
def complete_current_hand(room_code) do
  with {:ok, pid} <- GameRegistry.lookup(room_code) do
    auto_play_until_complete(pid)
  end
end

defp auto_play_until_complete(pid) do
  state = Pidro.Server.get_state(pid)
  
  case state.phase do
    :complete -> {:ok, state}
    :game_over -> {:ok, state}
    
    _ ->
      # Get current player and legal actions
      position = state.current_player
      actions = Pidro.Server.legal_actions(pid, position)
      
      # Choose action intelligently (needs bot logic)
      action = choose_smart_action(state, position, actions)
      
      # Apply and recurse
      {:ok, _new_state} = Pidro.Server.apply_action(pid, position, action)
      
      # Brief delay to avoid overwhelming broadcasts
      Process.sleep(50)
      
      auto_play_until_complete(pid)
  end
end
```

**Challenges:**
- ❌ **No bot AI exists** - need `choose_smart_action/3` logic
- Risk of infinite loops if action choice is bad
- Need sensible bidding strategy, card play logic
- Heavy broadcast traffic (50+ actions per hand)

**Recommendation:** ⚠️ Defer to FR-11 (Bot Management) - Prerequisite needed

---

### 4. "Auto-bid" ⚠️ FEASIBLE WITH BOT SUPPORT

**Status:** Requires bot player logic  
**Effort:** MEDIUM (simpler than full hand completion)  
**Engine Support:** Good

**What Exists:**
- `Engine.legal_actions/2` works for bidding phase
- Can apply bid actions rapidly
- No conflicts with engine state machine

**Implementation Path:**
```elixir
def auto_bid_all_players(room_code) do
  with {:ok, pid} <- GameRegistry.lookup(room_code),
       state = Pidro.Server.get_state(pid),
       true <- state.phase == :bidding do
    
    auto_bid_round(pid)
  else
    false -> {:error, "Not in bidding phase"}
    error -> error
  end
end

defp auto_bid_round(pid) do
  state = Pidro.Server.get_state(pid)
  
  if state.phase != :bidding do
    {:ok, state}
  else
    position = state.current_player
    actions = Pidro.Server.legal_actions(pid, position)
    
    # Simple strategy: bid if dealer, else pass
    action = if position == state.dealer, do: {:bid, 8}, else: :pass
    
    {:ok, _} = Pidro.Server.apply_action(pid, position, action)
    Process.sleep(100)  # Delay for UI
    
    auto_bid_round(pid)
  end
end
```

**Challenges:**
- ❌ **No bidding strategy** - need smart bid calculation
- Should evaluate hand strength (card counting logic needed)
- Rapid-fire might confuse UI if no delays

**Recommendation:** ⚠️ Implement simple version, enhance with FR-11

---

### 5. "Fast Forward" (5x speed with bots) ⚠️ FEASIBLE WITH BOT SUPPORT

**Status:** Achievable as combination of features  
**Effort:** HIGH (depends on bot implementation)  
**Engine Support:** Good (no blocking)

**What Exists:**
- No rate limiting in GameAdapter
- Actions process synchronously (no queuing delay)
- Can control broadcast frequency

**Implementation Path:**
```elixir
def fast_forward_game(room_code, speed_multiplier \\ 5) do
  delay_ms = div(500, speed_multiplier)  # Normal ~500ms, fast ~100ms
  
  with {:ok, pid} <- GameRegistry.lookup(room_code) do
    fast_play_loop(pid, delay_ms)
  end
end

defp fast_play_loop(pid, delay_ms) do
  state = Pidro.Server.get_state(pid)
  
  if state.phase in [:complete, :game_over] do
    {:ok, state}
  else
    # Bot makes move
    position = state.current_player
    actions = Pidro.Server.legal_actions(pid, position)
    action = choose_bot_action(state, position, actions)
    
    {:ok, _} = Pidro.Server.apply_action(pid, position, action)
    Process.sleep(delay_ms)
    
    fast_play_loop(pid, delay_ms)
  end
end
```

**Challenges:**
- ❌ **Requires full bot AI** from FR-11
- Heavy broadcast traffic (throttling might help)
- UI might struggle to keep up at 5x speed
- Need emergency stop mechanism

**Recommendation:** ⚠️ Defer until FR-11 complete

---

## Engine Capabilities Analysis

### ✅ Strengths

1. **Event Sourcing:** Complete via `Pidro.Game.Replay`
   - Full event history in `state.events`
   - Undo/redo primitives exist
   - State reconstruction from events

2. **Sequential Actions:** No blocking issues
   - `apply_action/3` is synchronous
   - No rate limiting currently enforced
   - Can rapid-fire actions in sequence

3. **Immutable State:** Easy to snapshot
   - Every action returns new state
   - Can save state copies for multi-level undo
   - No shared mutable data

4. **Legal Actions Query:** Full support
   - `legal_actions/2` works for all phases
   - Returns all valid actions for position
   - Foundation for bot decision-making

### ⚠️ Limitations

1. **No Batch Operations:**
   - Must apply actions one at a time
   - Each action triggers full state transition
   - Each action broadcasts update (network overhead)

2. **No Bot AI:**
   - Cannot intelligently choose actions
   - Blocks features #3, #4, #5
   - Needs separate implementation (FR-11)

3. **No System Actions:**
   - No `:new_game`, `:next_hand`, `:skip_phase`
   - Cannot programmatically advance game state
   - Limits "Deal Next Hand" feature

4. **No State Mutation API:**
   - `Pidro.Server` lacks `set_state/2`
   - Cannot directly replace state (needed for undo)
   - Would need engine enhancement

---

## Rate Limiting & Throttling

### Current Status: ❌ NOT IMPLEMENTED

**From API Documentation:**
> "Currently no rate limiting is enforced, but clients should implement reasonable request throttling."

**Planned Limits (not enforced):**
- Authentication: 5 req/min per IP
- Room operations: 20 req/min per user
- Game actions: 60 req/min per user

### Implications for Quick Actions

**✅ Positive:**
- Can apply 50+ actions in rapid sequence (auto-complete hand)
- No artificial delays in dev mode
- Fast-forward is technically feasible

**⚠️ Concerns:**
- Broadcast storm risk (50+ PubSub messages/second)
- Phoenix Channel might buffer/drop messages
- UI might not render fast enough
- Production rate limits would break quick actions

**Recommendations:**
1. Add `:dev_mode` flag to bypass rate limits
2. Implement optional broadcast throttling (e.g., every 5 actions)
3. Add client-side debouncing for rapid updates
4. Consider "silent mode" that only broadcasts final state

---

## Undo/Redo Deep Dive

### Engine Support: ✅ EXCELLENT

**Replay module provides:**
```elixir
# Undo to previous state
{:ok, prev_state} = Replay.undo(current_state)

# Redo an event
{:ok, next_state} = Replay.redo(prev_state, undone_event)

# Full history query
events = Replay.events_since(state, timestamp)
count = Replay.history_length(state)
last = Replay.last_event(state)
```

### Multi-Level Undo Strategy

**Option 1: Server State Replacement**
```elixir
# Need to add to Pidro.Server
def set_state(pid, new_state) do
  GenServer.call(pid, {:set_state, new_state})
end
```

**Option 2: Undo Stack in Room**
```elixir
# In RoomManager
defmodule Room do
  defstruct [
    # ... existing fields
    :undo_stack,   # Stack of previous states
    :redo_stack    # Stack for redo
  ]
end
```

**Option 3: Event Replay (current approach)**
```elixir
# Most memory efficient, but slower
def undo_n_times(state, n) do
  events = Enum.drop(state.events, -n)
  Replay.replay(events)
end
```

**Recommendation:** Implement Option 1 (cleanest API)

---

## Missing Engine Features

### Required for Full Implementation

1. **`Pidro.Server.set_state/2`** (Priority: HIGH)
   - Needed for undo functionality
   - Simple to add (just GenServer call handler)
   - Security: restrict to dev mode

2. **System Actions** (Priority: MEDIUM)
   - `:next_hand` - Advance to next deal
   - `:new_game` - Reset to initial state
   - `:skip_to_phase` - Jump to specific phase (dev only)

3. **Bot AI Module** (Priority: HIGH - see FR-11)
   - `choose_bid/2` - Smart bidding
   - `choose_card/2` - Legal card play
   - `choose_trump/1` - Trump declaration
   - `choose_discard/2` - Discard selection

4. **Broadcast Throttling** (Priority: LOW)
   - Optional param to skip broadcasts
   - Batch state updates
   - Silent mode for bulk operations

---

## Recommendations by Priority

### 🟢 HIGH Priority - Implement Immediately

1. **Undo Last Action** ✅
   - Engine support complete
   - Just need `Pidro.Server.set_state/2`
   - Huge dev productivity win
   - **Effort:** 2-4 hours

### 🟡 MEDIUM Priority - Implement After Bot AI

2. **Auto-bid** ⚠️
   - Requires basic bot logic
   - Simple strategy acceptable for dev mode
   - **Effort:** 4-8 hours (after bot framework)

3. **Complete Current Hand** ⚠️
   - Depends on bot AI for all phases
   - High value for testing
   - **Effort:** 8-16 hours (after bot framework)

### 🔴 LOW Priority - Defer

4. **Deal Next Hand** ⚠️
   - Requires system actions in engine
   - Lower value (can manually reset)
   - **Effort:** 4-8 hours

5. **Fast Forward** ⚠️
   - Requires complete bot AI
   - Risk of broadcast storms
   - Can achieve similar with "complete hand" in loop
   - **Effort:** 8-16 hours

---

## Proposed Implementation Phases

### Phase 1: Undo Support (Week 1)
- [ ] Add `Pidro.Server.set_state/2`
- [ ] Add `GameAdapter.undo_last_action/1`
- [ ] Add undo button to dev UI
- [ ] Add keyboard shortcut (Ctrl+Z)
- [ ] Add visual feedback for undo

### Phase 2: Basic Bot Framework (Week 2) - **See FR-11**
- [ ] Create `Pidro.Dev.BotPlayer` module
- [ ] Implement random action selection
- [ ] Implement basic bidding heuristics
- [ ] Add legal card play (follow suit)

### Phase 3: Auto-bid (Week 2-3)
- [ ] Add `GameAdapter.auto_bid_round/1`
- [ ] Wire to dev UI button
- [ ] Add progress indicator
- [ ] Test rapid bidding

### Phase 4: Auto-complete Hand (Week 3-4)
- [ ] Add `GameAdapter.complete_current_hand/1`
- [ ] Add cancellation support
- [ ] Throttle broadcasts (every 5 actions)
- [ ] Add progress bar

### Phase 5: Advanced Features (Future)
- [ ] Fast-forward with speed control
- [ ] Multi-level undo (undo stack)
- [ ] Redo support
- [ ] Skip to phase

---

## Code Samples

### 1. Add set_state to Pidro.Server

```elixir
# In apps/pidro_engine/lib/pidro/server.ex

@doc """
Sets the game state directly. FOR DEVELOPMENT USE ONLY.

This bypasses normal game flow and is intended for undo/testing features.
Should not be exposed in production APIs.
"""
@spec set_state(pid(), Types.GameState.t()) :: :ok
def set_state(pid, %Types.GameState{} = new_state) do
  GenServer.call(pid, {:set_state, new_state})
end

# In handle_call
def handle_call({:set_state, new_state}, _from, _old_state) do
  {:reply, :ok, new_state}
end
```

### 2. Add undo to GameAdapter

```elixir
# In apps/pidro_server/lib/pidro_server/games/game_adapter.ex

@doc """
Undoes the last action in the game. Development feature only.

Returns the game state to before the last event was applied.
"""
@spec undo_last_action(String.t()) :: {:ok, term()} | {:error, term()}
def undo_last_action(room_code) do
  with {:ok, pid} <- GameRegistry.lookup(room_code) do
    current_state = Pidro.Server.get_state(pid)
    
    case Pidro.Game.Replay.undo(current_state) do
      {:ok, previous_state} ->
        :ok = Pidro.Server.set_state(pid, previous_state)
        broadcast_state_update(room_code, pid)
        {:ok, previous_state}
        
      {:error, :no_history} ->
        {:error, "Nothing to undo - no game history"}
    end
  end
end
```

### 3. WebSocket Handler for Undo

```elixir
# In apps/pidro_server_web/lib/pidro_server_web/channels/game_channel.ex

def handle_in("undo_action", _payload, socket) do
  room_code = socket.assigns.room_code
  
  # Only allow in dev mode
  if Application.get_env(:pidro_server, :dev_mode, false) do
    case GameAdapter.undo_last_action(room_code) do
      {:ok, _state} ->
        {:reply, {:ok, %{message: "Action undone"}}, socket}
        
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  else
    {:reply, {:error, %{reason: "Undo not available in production"}}, socket}
  end
end
```

---

## Risk Assessment

### Technical Risks

1. **Broadcast Storm** (Medium Risk)
   - Rapid actions = many broadcasts
   - Mitigation: Throttle, batch updates, silent mode

2. **Race Conditions** (Low Risk)
   - Sequential GenServer calls prevent
   - State transitions are synchronous

3. **Memory Pressure** (Low Risk)
   - Event history grows with game length
   - Mitigation: Clear history on new game

4. **UI Performance** (Medium Risk)
   - Too many rapid updates might freeze UI
   - Mitigation: Client-side debouncing, request animation frame

### UX Risks

1. **Confusing State Changes** (High Risk)
   - Fast-forward might disorient users
   - Mitigation: Clear visual feedback, pause button

2. **Accidental Undo** (Medium Risk)
   - Easy to trigger by mistake
   - Mitigation: Confirmation dialog, undo limit

---

## Conclusion

**Overall Feasibility: 80%** (4 of 5 features achievable)

| Feature | Feasibility | Effort | Blockers |
|---------|------------|--------|----------|
| Undo Last Action | ✅ 100% | LOW | None - just need `set_state/2` |
| Deal Next Hand | ⚠️ 60% | MEDIUM | Need system actions in engine |
| Complete Current Hand | ⚠️ 70% | HIGH | Requires bot AI (FR-11) |
| Auto-bid | ⚠️ 75% | MEDIUM | Requires basic bot AI (FR-11) |
| Fast Forward | ⚠️ 50% | HIGH | Requires bot AI + throttling |

**Critical Path:**
1. Implement undo (high ROI, low effort) ✅
2. Build bot AI framework (unlocks 3 features) - See FR-11
3. Implement auto-bid (quick win after bots)
4. Implement complete hand (full automation)
5. Defer fast-forward (diminishing returns)

**Next Steps:**
1. Add `Pidro.Server.set_state/2` to engine
2. Implement undo in GameAdapter
3. Wire undo to dev UI
4. Create FR-11 bot framework spec
5. Revisit auto-complete features after bots exist
