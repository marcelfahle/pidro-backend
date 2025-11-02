# Architecture Guide

This guide explains the architecture of the Pidro game engine and the rationale behind its design decisions.

## Design Principles

### 1. Pure Functional Core

The game engine core is **purely functional**:
- All functions are pure (no side effects)
- Game state is immutable
- State updates return new state structures
- Deterministic behavior (same input = same output)

**Benefits:**
- Easy to test (no mocking needed)
- Easy to reason about
- Perfect for event replay
- Thread-safe by default
- Time-travel debugging possible

### 2. Event Sourcing

Every state change produces events:
- Events are the source of truth
- Current state can be reconstructed from events
- Enables undo/redo
- Complete audit trail
- Network synchronization friendly

### 3. Property-Based Testing

Correctness proven through properties, not examples:
- 157 properties covering all game phases
- Generators create valid game states
- Properties test invariants, not procedures
- Catches edge cases example tests miss

### 4. Separation of Concerns

Clean separation between:
- **Core Types** - Data structures only
- **Game Logic** - Pure functions
- **State Machine** - Phase transitions
- **OTP Layer** - Process management
- **Utilities** - Helper tools

## Module Organization

### Layer 1: Core Types (`lib/pidro/core/`)

Foundation types and basic operations:

```
Pidro.Core.Types          - Type definitions (@type, @typedoc)
Pidro.Core.Card           - Card operations (is_trump?, point_value, compare)
Pidro.Core.Deck           - Deck operations (shuffle, deal)
Pidro.Core.Player         - Player state (hand, position, team)
Pidro.Core.Trick          - Trick resolution (winner, points)
Pidro.Core.GameState      - Game state struct (immutable)
Pidro.Core.Events         - Event definitions and application
Pidro.Core.Binary         - Binary encoding (optimization)
```

**Dependencies**: None (foundation layer)

### Layer 2: Game Engine (`lib/pidro/game/`)

Game logic and state machine:

```
Pidro.Game.Engine         - Main API (apply_action, legal_actions)
Pidro.Game.StateMachine   - Phase transitions (9 phases)
Pidro.Game.Dealing        - Dealer selection, dealing
Pidro.Game.Bidding        - Bid validation, tracking
Pidro.Game.Trump          - Trump declaration, categorization
Pidro.Game.Discard        - Automatic discard, second deal, dealer rob
Pidro.Game.Play           - Trick-taking, elimination, kill rule
Pidro.Game.Replay         - Undo/redo, event replay
Pidro.Game.Errors         - Error types
```

**Dependencies**: Core Types layer

**Key Patterns:**
- Engine dispatches to phase modules
- Phase modules return `{:ok, state} | {:error, reason}`
- All state updates go through `GameState.update/3`
- Events emitted via `Events.emit_event/2`

### Layer 3: Finnish Variant (`lib/pidro/finnish/`)

Finnish-specific rules:

```
Pidro.Finnish.Rules       - Finnish variant rules
Pidro.Finnish.Scorer      - Scoring logic (bid made/failed)
```

**Dependencies**: Game Engine, Core Types

**Variant Support:**
This design allows future variants (American, Norwegian) by creating `lib/pidro/american/` etc.

### Layer 4: OTP Layer (`lib/pidro/`)

Process management and supervision:

```
Pidro.Server              - GenServer wrapper (stateful API)
Pidro.Supervisor          - Supervision tree (DynamicSupervisor)
Pidro.MoveCache           - ETS cache (performance)
```

**Dependencies**: All lower layers

**Design:**
- Thin OTP wrapper around pure core
- Server delegates to `Engine` for all game logic
- Supervisor manages game lifecycle
- Cache is optional (can be disabled)

### Layer 5: Utilities

Cross-cutting tools:

```
Pidro.IEx                 - Interactive helpers (development)
Pidro.Notation            - PGN-like encoding (persistence)
Pidro.Perf                - Performance utilities (optimization)
```

**Dependencies**: Core + Engine layers

## Data Flow

### Apply Action Flow

```
User/Client
    ↓
Pidro.Server.apply_action(pid, position, action)
    ↓
GenServer.call → handle_call
    ↓
Pidro.Game.Engine.apply_action(state, position, action)
    ↓
[Validation] → legal_actions check
    ↓
[Phase Router] → dispatch to phase module
    ↓
Phase Module (Bidding/Trump/Play/etc.)
    ↓
[State Update] → GameState.update
    ↓
[Event Emission] → Events.emit_event
    ↓
[Auto Transition] → maybe_auto_transition
    ↓
{:ok, new_state} | {:error, reason}
    ↓
GenServer.reply
    ↓
User/Client
```

### Event Sourcing Flow

```
Initial State (new_game)
    ↓
Apply Action → Event Generated
    ↓
Events List: [event1, event2, event3, ...]
    ↓
At Any Time:
    ↓
Replay.replay(events) → Reconstruct State
    ↓
Replay.undo(state) → State - Last Event
    ↓
Notation.encode(state) → PGN String
    ↓
Notation.decode(pgn) → Reconstruct State
```

## Phase State Machine

The game progresses through 9 phases:

```
:dealer_selection
    ↓ (automatic cut and select)
:dealing
    ↓ (automatic deal 9 cards each)
:bidding
    ↓ (manual bids/passes → bid winner)
:declaring
    ↓ (manual trump declaration)
:discarding
    ↓ (automatic discard non-trump)
:second_deal
    ↓ (automatic deal to 6 OR dealer rob)
:playing
    ↓ (manual card plays → all tricks complete)
:scoring
    ↓ (automatic score tally)
:complete
```

**Automatic Phases:**
- `dealer_selection`, `dealing`, `discarding`, `second_deal`, `scoring`
- Engine handles these without user action
- Transition happens immediately after entering phase

**Manual Phases:**
- `bidding`, `declaring`, `playing`
- Require user actions via `apply_action/3`
- Transition happens when phase-specific condition met

**Transition Guards:**

Each transition has validation:

```elixir
def can_transition_from_bidding?(state) do
  # Bidding complete: dealer's turn AND at least one bid made
  state.current_turn == state.current_dealer and
    (state.highest_bid != nil or all_passed?(state))
end
```

## Key Design Patterns

### 1. Result Tuples

All fallible operations return `{:ok, result} | {:error, reason}`:

```elixir
case Engine.apply_action(state, :north, {:bid, 10}) do
  {:ok, new_state} -> # success
  {:error, :not_your_turn} -> # specific error
  {:error, reason} -> # other errors
end
```

### 2. Immutable Updates

State updates create new structs:

```elixir
# DON'T: Mutate state
state.phase = :bidding  # ❌ Not allowed in Elixir

# DO: Create new state
new_state = GameState.update(state, :phase, :bidding)  # ✅
```

### 3. Pipeline Style

Operations flow through pipelines:

```elixir
state
|> GameState.update(:highest_bid, amount)
|> GameState.update(:highest_bidder, position)
|> GameState.update(:current_turn, next_turn)
|> Events.emit_event({:bid_made, position, amount})
```

### 4. Pattern Matching

Dispatch based on phase + action:

```elixir
def apply_action(%GameState{phase: :bidding} = state, pos, {:bid, amount}) do
  Bidding.apply_bid(state, pos, amount)
end

def apply_action(%GameState{phase: :bidding} = state, pos, :pass) do
  Bidding.apply_pass(state, pos)
end

def apply_action(%GameState{phase: :declaring} = state, pos, {:declare_trump, suit}) do
  Trump.declare_trump(state, suit)
end
```

### 5. Event Emission

Every state change emits event:

```elixir
def apply_bid(state, position, amount) do
  state
  |> GameState.update(:highest_bid, amount)
  |> GameState.update(:highest_bidder, position)
  |> Events.emit_event({:bid_made, position, amount})  # Event!
end
```

## Performance Optimizations

### 1. Move Caching

Legal moves are expensive to compute, so we cache:

```elixir
Pidro.MoveCache.get_or_compute(state, position, fn ->
  # Expensive computation only if cache miss
  compute_legal_actions(state, position)
end)
```

**Cache Key**: Hash of (phase, current_turn, relevant_state_fields)

### 2. Binary Encoding

Cards encoded as 6-bit values:

```
Card: {rank, suit}
  rank: 2-14 (4 bits)
  suit: 0-3  (2 bits)
  total: 6 bits
```

52 cards → 39 bytes (vs ~400 bytes in Erlang terms)

### 3. Fast Hashing

State hashing for equality checks:

```elixir
hash1 = Pidro.Perf.hash_state(state1)
hash2 = Pidro.Perf.hash_state(state2)

if hash1 == hash2, do: # likely equal
```

Uses `:erlang.phash2/1` (very fast, < 10μs)

## Testing Strategy

### Unit Tests (`test/unit/`)

- One test file per module
- Test individual functions in isolation
- Example-based tests
- Edge cases (empty hands, dealer rob edge cases, etc.)

### Property Tests (`test/properties/`)

- Test invariants, not examples
- Use StreamData generators
- 50-100 runs per property
- Cover all game phases

**Example Property:**

```elixir
property "total points per hand always equals 14 (minus killed)" do
  check all state <- playing_phase_generator() do
    available_points = Finnish.Scorer.total_available_points(state)

    # Calculate killed points (excluding top killed card)
    killed_points = calculate_killed_points(state)

    assert available_points == 14 - killed_points
  end
end
```

### Integration Tests (`test/integration/`)

- Test full game flows
- Multiple phases in sequence
- Real scenarios (dealer rob, kill rule, etc.)

### Doctests

- Examples in `@doc` blocks
- Verified by `mix test`
- Living documentation

## Error Handling

Errors are explicit and descriptive:

```elixir
defmodule Pidro.Game.Errors do
  def error(:not_your_turn), do: {:error, :not_your_turn}
  def error(:invalid_bid), do: {:error, :invalid_bid}
  def error(:bid_too_low), do: {:error, :bid_too_low}
  # ... etc
end
```

**Error Categories:**
- **Turn errors**: `:not_your_turn`
- **Validation errors**: `:invalid_bid`, `:card_not_in_hand`
- **Phase errors**: `:invalid_phase`, `:wrong_action_for_phase`
- **Rule violations**: `:cannot_kill_point_cards`, `:must_play_trump`

## Extensibility

### Adding a New Variant

1. Create `lib/pidro/american/` directory
2. Implement variant-specific modules:
   - `American.Rules` (different trump rules)
   - `American.Scorer` (different scoring)
3. Add variant config: `config :pidro_engine, variant: :american`
4. Engine routes to variant modules based on config

### Adding a New Phase

1. Add phase atom to `Types.phase/0`
2. Add transition guards in `StateMachine`
3. Implement phase module in `lib/pidro/game/`
4. Add action handlers in `Engine`
5. Add property tests for new phase

### Adding New Events

1. Add event type to `Types.event/0`
2. Add event handler in `Events.apply_event/2`
3. Emit event in appropriate phase module
4. Update `Notation` encoder/decoder if needed

## Best Practices

### DO ✅

- Return `{:ok, state}` or `{:error, reason}` from all operations
- Emit events for all state changes
- Use pattern matching for dispatch
- Write properties before implementation
- Keep functions pure (no IO, no side effects)
- Update state via `GameState.update/3`

### DON'T ❌

- Mutate state in-place
- Skip event emission
- Put business logic in OTP layer (keep Server thin)
- Hardcode magic numbers (use config or constants)
- Forget to update tests when adding features

## Conclusion

The Pidro engine architecture prioritizes:

1. **Correctness** - Property-based testing ensures rules always hold
2. **Maintainability** - Pure functions, clear separation of concerns
3. **Performance** - Caching, binary encoding where needed
4. **Extensibility** - Easy to add variants, new features
5. **Developer Experience** - IEx helpers, excellent error messages

Next: Explore [Property Testing](property_testing.md) or [Event Sourcing](event_sourcing.md) guides.
