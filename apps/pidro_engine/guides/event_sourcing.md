# Event Sourcing Guide

This guide explains how event sourcing works in the Pidro engine and how to use it effectively.

## What is Event Sourcing?

Event sourcing is a pattern where state changes are stored as a **sequence of events** rather than just the current state.

### Traditional State Management

```
Current State (in memory/database)
  ↓
Apply change → Overwrite state
  ↓
Previous state is lost forever
```

### Event Sourcing

```
Event Log: [event1, event2, event3, ...]
  ↓
Replay events → Reconstruct current state
  ↓
Can replay to any point in time
```

## Benefits

1. **Complete Audit Trail** - Every change is recorded
2. **Time Travel** - Reconstruct state at any point
3. **Undo/Redo** - Trivial to implement
4. **Replay** - Reproduce bugs, test different strategies
5. **Synchronization** - Easy to sync clients (just send events)
6. **Analytics** - Rich data for analysis

## Event Types

The engine defines 14 event types covering all game phases:

```elixir
@type event ::
  # Setup events
  {:dealer_selected, position(), card()} |
  {:cards_dealt, %{position() => [card()]}} |

  # Bidding events
  {:bid_made, position(), bid_amount()} |
  {:bid_passed, position()} |
  {:bidding_complete, position(), bid_amount()} |

  # Trump events
  {:trump_declared, position(), suit()} |

  # Discard/Redeal events
  {:cards_discarded, position(), non_neg_integer()} |
  {:second_deal_complete, %{position() => non_neg_integer()}} |
  {:dealer_robbed_pack, position(), non_neg_integer(), non_neg_integer()} |
  {:cards_killed, %{position() => [card()]}} |

  # Play events
  {:card_played, position(), card()} |
  {:trick_won, position(), points()} |
  {:player_went_cold, position()} |

  # Scoring events
  {:hand_scored, %{team() => points()}, %{team() => points()}} |
  {:game_won, team()}
```

## Event Structure

Each event is stored with metadata:

```elixir
%Pidro.Core.Events.Event{
  type: :bid_made,
  data: {:bid_made, :north, 10},
  hand_number: 1,
  timestamp: ~U[2025-11-02 10:30:45.123456Z],
  sequence: 5
}
```

## How Events Work

### 1. Event Emission

Every state change emits an event:

```elixir
def apply_bid(state, position, amount) do
  new_state =
    state
    |> GameState.update(:highest_bid, amount)
    |> GameState.update(:highest_bidder, position)
    |> Events.emit_event({:bid_made, position, amount})

  {:ok, new_state}
end
```

### 2. Event Storage

Events are appended to the state's event list:

```elixir
def emit_event(state, event_data) do
  event = %Event{
    type: elem(event_data, 0),
    data: event_data,
    hand_number: state.hand_number,
    timestamp: DateTime.utc_now(),
    sequence: length(state.events) + 1
  }

  GameState.update(state, :events, state.events ++ [event])
end
```

### 3. Event Application

Events can be replayed to reconstruct state:

```elixir
def apply_event(state, {:bid_made, position, amount}) do
  state
  |> GameState.update(:highest_bid, amount)
  |> GameState.update(:highest_bidder, position)
end

def apply_event(state, {:card_played, position, card}) do
  # Update trick, remove card from hand, etc.
end
```

## Using Event Sourcing

### Get Event History

```elixir
# All events in the game
state.events

# Recent events
state.events |> Enum.take(-10)

# Events from specific hand
state.events
|> Enum.filter(fn event -> event.hand_number == 2 end)

# Events of specific type
state.events
|> Enum.filter(fn event -> event.type == :bid_made end)
```

### Replay Events

Reconstruct state from events:

```elixir
alias Pidro.Game.Replay

# Replay all events
{:ok, reconstructed_state} = Replay.replay(events)

# Replay to specific point
{:ok, partial_state} = Replay.replay(Enum.take(events, 10))

# Verify replay matches current state
assert Replay.replay(state.events) == {:ok, state}
```

### Undo Last Action

```elixir
# Undo most recent event
{:ok, previous_state} = Replay.undo(state)

# Undo multiple times
{:ok, state2} = Replay.undo(state)
{:ok, state3} = Replay.undo(state2)
```

### Redo

```elixir
# After undo, redo with next event
{:ok, previous_state} = Replay.undo(state)
last_event = List.last(state.events)

{:ok, redone_state} = Replay.redo(previous_state, last_event)
```

## Event Log Visualization

Use IEx helper to see event log:

```elixir
import Pidro.IEx

state = new_game()

# Play some moves
{:ok, state} = step(state, :west, {:bid, 10})
{:ok, state} = step(state, :north, :pass)

# Show event log
show_event_log(state)
```

Output:

```
╔═══════════════════════════════════════════════════════════╗
║                    EVENT LOG                              ║
╚═══════════════════════════════════════════════════════════╝

1. [DEALER] South selected as dealer (cut 10♣)
2. [DEAL] Initial deal complete (36 cards dealt)
3. [BID] West bid 10
4. [PASS] North passed
5. [BID] East bid 11
6. [PASS] South passed
7. [PASS] West passed
8. [BID COMPLETE] East won bidding with 11
9. [TRUMP] East declared Hearts ♥
10. [DISCARD] Cards discarded (North: 5, East: 3, South: 7, West: 6)
11. [REDEAL] Second deal complete (North: 1, South: 2, West: 3)
12. [ROB] East robbed pack (took 7, kept 6)

Total Events: 12
```

## PGN-Like Notation

Export and import games using notation:

```elixir
alias Pidro.Notation

# Export game to string
pgn = Notation.encode(state)
# => "[Event \"Pidro Game\"]\n[Variant \"Finnish\"]\n..."

# Import game from string
{:ok, imported_state} = Notation.decode(pgn)

# Roundtrip should preserve state
assert Notation.decode(Notation.encode(state)) == {:ok, state}
```

### PGN Format

```
[Event "Pidro Game"]
[Variant "Finnish"]
[Date "2025.11.02"]
[Round "1"]
[Dealer "South"]
[Result "*"]

1. South dealer (cut 10c)
2. Deal: N=9 E=9 S=9 W=9
3. West bid 10
4. North pass
5. East bid 11
6. South pass
...
```

## Use Cases

### 1. Game Replay

```elixir
# Save game to database
game_id = "game-123"
pgn = Notation.encode(state)
Database.save_game(game_id, pgn)

# Later: Load and replay
{:ok, pgn} = Database.load_game(game_id)
{:ok, state} = Notation.decode(pgn)

# Replay to specific point
events = state.events
{:ok, halfway_state} = Replay.replay(Enum.take(events, div(length(events), 2)))
```

### 2. Undo/Redo in UI

```elixir
# User clicks "Undo"
{:ok, previous_state} = Replay.undo(current_state)
render(previous_state)

# User clicks "Redo"
last_event = List.last(current_state.events)
{:ok, next_state} = Replay.redo(previous_state, last_event)
render(next_state)
```

### 3. Debugging

```elixir
# Bug report: "Game crashed at event 47"
bug_events = load_bug_report_events()

# Replay up to crash
{:ok, state_before_crash} = Replay.replay(Enum.take(bug_events, 46))
result = apply_event(state_before_crash, Enum.at(bug_events, 46))

# Inspect what went wrong
case result do
  {:error, reason} -> IO.puts("Error: #{reason}")
  {:ok, _state} -> IO.puts("No error found - may be race condition")
end
```

### 4. AI Training

```elixir
# Generate training data from expert games
expert_games = Database.load_expert_games()

training_data =
  Enum.flat_map(expert_games, fn game ->
    {:ok, state} = Notation.decode(game.pgn)

    # Extract (state, action) pairs
    Enum.map(state.events, fn event ->
      %{
        state_before: replay_to_event(state, event),
        action: event_to_action(event),
        outcome: game.result
      }
    end)
  end)
```

### 5. Analytics

```elixir
# Analyze bid success rate
games = Database.load_all_games()

bid_analysis =
  Enum.map(games, fn game ->
    {:ok, state} = Notation.decode(game.pgn)

    bid_event = Enum.find(state.events, &match?({:bidding_complete, _, _}, &1.data))
    {:bidding_complete, bidder, amount} = bid_event.data

    scoring_event = Enum.find(state.events, &match?({:hand_scored, _, _}, &1.data))
    {:hand_scored, points_taken, _cumulative} = scoring_event.data

    bidder_team = position_to_team(bidder)
    made_bid? = points_taken[bidder_team] >= amount

    %{bid_amount: amount, made: made_bid?}
  end)

# Calculate stats
Enum.group_by(bid_analysis, & &1.bid_amount)
|> Enum.map(fn {amount, bids} ->
  success_rate = Enum.count(bids, & &1.made) / length(bids)
  {amount, success_rate}
end)
# => [{6, 0.89}, {7, 0.84}, {8, 0.75}, ...]
```

## Event Sourcing Patterns

### Command-Event Separation

**Commands** (actions) are requests that may fail:

```elixir
# Command: "Try to bid 10"
result = Engine.apply_action(state, :north, {:bid, 10})

case result do
  {:ok, new_state} ->
    # Command succeeded, event was emitted
    # Event: {:bid_made, :north, 10}

  {:error, :bid_too_low} ->
    # Command rejected, no event emitted
end
```

**Events** represent facts that have happened:

```elixir
# Event: "North bid 10" (already happened, cannot fail)
new_state = Events.apply_event(state, {:bid_made, :north, 10})
```

### Event Versioning

If event structure changes, handle multiple versions:

```elixir
def apply_event(state, {:second_deal_complete, dealt_map}) when is_map(dealt_map) do
  # Old version: map of cards
  # Migrate to new version
  apply_event(state, {:second_deal_complete_v2, count_cards(dealt_map)})
end

def apply_event(state, {:second_deal_complete_v2, counts}) do
  # New version: counts only
  GameState.update(state, :cards_requested, counts)
end
```

### Snapshotting

For long games, replay can be slow. Use snapshots:

```elixir
# Every 50 events, save snapshot
if rem(length(state.events), 50) == 0 do
  Database.save_snapshot(game_id, state)
end

# Replay from most recent snapshot
{:ok, snapshot_state, snapshot_event_count} = Database.load_snapshot(game_id)
remaining_events = Enum.drop(all_events, snapshot_event_count)
{:ok, final_state} = Replay.replay_from(snapshot_state, remaining_events)
```

## Information Hiding

Events must not leak hidden information:

❌ **Bad**: Event reveals dealer's cards

```elixir
{:dealer_robbed_pack, :south,
  [{14, :hearts}, {5, :hearts}, ...],  # dealer's pool (hidden!)
  [{14, :hearts}, {5, :hearts}, ...]}  # dealer's selection (hidden!)
```

✅ **Good**: Event shows only counts

```elixir
{:dealer_robbed_pack, :south, 7, 6}  # took 7, kept 6 (public info)
```

This ensures events can be sent to all clients without revealing hidden information.

## Testing Event Sourcing

Property tests ensure event sourcing works:

```elixir
property "replay from events produces identical state" do
  check all state <- complete_game_generator() do
    {:ok, replayed} = Replay.replay(state.events)

    # Replayed state should match original
    assert states_equal?(state, replayed)
  end
end

property "PGN roundtrip preserves state" do
  check all state <- game_state_generator() do
    pgn = Notation.encode(state)
    {:ok, decoded} = Notation.decode(pgn)

    assert states_equal?(state, decoded)
  end
end
```

## Best Practices

### DO ✅

- Emit events for **every** state change
- Make events **immutable** (structs, not maps)
- Use **descriptive** event names (`:bid_made` not `:update`)
- Keep events **small** (counts not full data when possible)
- **Version** events for future compatibility

### DON'T ❌

- Skip event emission (breaks replay)
- Include hidden information in events
- Modify events after emission
- Make event application non-deterministic
- Store computed values in events (recompute on replay)

## Performance Considerations

### Event Log Size

- Average game: ~100-200 events
- Full game to 62 points: ~300-500 events
- Event storage: ~100 bytes per event
- Total: ~50KB per game (very manageable)

### Replay Speed

- Replay 100 events: ~10ms
- Replay 500 events: ~50ms
- Fast enough for real-time undo/redo

### Optimizations

- **Snapshotting**: Save state every N events
- **Lazy replay**: Only replay events since last known state
- **Event batching**: Apply multiple events in one pass

## Next Steps

- Read [Architecture](architecture.md) for overall design
- See [Property Testing](property_testing.md) for correctness guarantees
- Explore `lib/pidro/core/events.ex` for event implementation
- Try `Pidro.Game.Replay` module in IEx

## Further Reading

- [Event Sourcing by Martin Fowler](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS Journey by Microsoft](https://docs.microsoft.com/en-us/previous-versions/msp-n-p/jj554200(v=pandp.10))
- [Event Sourcing in Elixir](https://10consulting.com/2017/01/04/event-sourcing-in-elixir/)
