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

1. **Complete Audit Trail** - Every action is recorded
2. **Undo/Redo** - Trivial to implement
3. **Synchronization** - Easy to sync clients (just send events)
4. **Analytics** - Rich data for analysis

## What replay restores, and what it does not

Read this before treating the event log as a saved game. **It is not one.**

The authoritative value is the `%GameState{}`. The event log is a projection of
it, and three things never enter that projection:

| Not in any event | Consequence |
|---|---|
| The **deck's order** (dealt and undealt alike) | A replayed state cannot say what the next card off the deck would be |
| The **four dealer-selection cuts** | `{:dealer_selected, position, card}` records the winner only |
| The **chance stream** (`state.chance`) | A replayed state cannot reproduce the original game's next shuffle |

So `Replay.replay/1` faithfully reconstructs everything the events *do* record —
hands as dealt, bids, trump, plays, tricks, scores — and it is itself
deterministic: the same events always fold to the same state. What it does not
produce is a state equal to the one the events came from, and it does not
produce a state that plays on like the original game. `replay/1` folds onto a
documented placeholder seed for exactly that reason, and deliberately takes no
seed argument: offering one would suggest replay can reproduce a specific
game's future, which it cannot.

```elixir
# This does NOT hold, and is not meant to:
Replay.replay(state.events) == {:ok, state}

# What does hold — replay is deterministic:
Replay.replay(state.events) == Replay.replay(state.events)
```

**To save and resume a game, serialize the state, not the log.** A
`%GameState{}` is plain data — no PIDs, refs, funs or timestamps — and it
carries its own chance stream, so it round-trips through
`:erlang.term_to_binary/1` and continues identically in another process:

```elixir
saved = :erlang.term_to_binary(state)
restored = :erlang.binary_to_term(saved)
# `restored` deals the next hand exactly as `state` would have
```

`test/properties/continuation_properties_test.exs` is the proof of that, and
`Pidro.Core.Binary` is *not* an alternative — it is a compact fingerprint of a
position that drops the bid and trick history, the event log and the chance
stream. Its moduledoc says so.

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
```

A replayed state is not equal to the state the events came from — the deck
order, the dealer cuts and the chance stream are in no event. See
[What replay restores, and what it does not](#what-replay-restores-and-what-it-does-not).

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
```

Notation is a **summary**, not a snapshot: it round-trips nine fields (phase,
dealer, turn, trump, highest bid, scores, hand number, trick count, redeal
state) and nothing else. Hands, the deck, the event log and the chance stream
are not represented, so a decoded state has a placeholder chance value for the
same reason `Replay.replay/1` does.

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

Store the event log if you want to walk a game; store the state if you want to
continue one. They answer different questions.

```elixir
# Save what you need for each purpose
game_id = "game-123"
Database.save_events(game_id, state.events)                  # to walk the game
Database.save_snapshot(game_id, :erlang.term_to_binary(state))  # to continue it

# Walk: reconstruct the position at any point in the log
{:ok, events} = Database.load_events(game_id)
{:ok, halfway_state} = Replay.replay(Enum.take(events, div(length(events), 2)))

# Continue: the snapshot carries its chance stream, so play goes on identically
{:ok, binary} = Database.load_snapshot(game_id)
resumed = :erlang.binary_to_term(binary)
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
    {:ok, events} = Database.load_events(game.id)
    {:ok, state} = Replay.replay(events)

    # Extract (state, action) pairs
    Enum.map(events, fn event ->
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

# A game's log spans every hand it played, and the event tuples carry no hand
# number, so the pairing has to come from the order: a `:bidding_complete`
# opens a hand, and that hand closes on the bidding team's `:hand_scored`.
# `Enum.find/2` would pair hand 1's bid with hand 1's score and discard the
# rest of the game.
bid_analysis =
  Enum.flat_map(games, fn game ->
    {:ok, events} = Database.load_events(game.id)

    {hands, _open_bid} =
      Enum.reduce(events, {[], nil}, fn
        {:bidding_complete, bidder, amount}, {hands, _open_bid} ->
          {hands, {position_to_team(bidder), amount}}

        # One `:hand_scored` event per team, carrying that team's score delta.
        # A failed bid scores the bidding team negatively. The repeated `team`
        # matches only the bidding team's event; the defending team's falls
        # through untouched.
        {:hand_scored, team, delta}, {hands, {team, amount}} ->
          {[%{bid_amount: amount, made: delta >= amount} | hands], nil}

        _event, acc ->
          acc
      end)

    Enum.reverse(hands)
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

Property tests ensure event sourcing works. Note what they assert: replay
matches *sequential application of the same events*, and PGN round-trips *the
fields it encodes* — neither claims equality with the state the events or the
notation came from. See `test/properties/event_sourcing_properties_test.exs`.

```elixir
property "replaying events produces identical state to sequential application" do
  check all events <- event_sequence() do
    # Both sides start from the same seeded state, so the comparison is about
    # the events and nothing else.
    folded =
      Enum.reduce(events, GameState.new(seed: 1), fn event, state ->
        Events.apply_event(state, event)
      end)

    replayed = Events.replay_events(GameState.new(seed: 1), events)

    # Field by field, not `==` on the struct: `replay_events/2` applies events
    # without appending them to `state.events`, so the event lists differ by
    # construction and a whole-struct assertion would always fail.
    assert folded.phase == replayed.phase
    assert folded.current_dealer == replayed.current_dealer
    assert folded.trump_suit == replayed.trump_suit
    assert folded.highest_bid == replayed.highest_bid
  end
end

property "PGN encode/decode round-trip preserves serialized fields" do
  check all state <- game_state_generator() do
    {:ok, decoded} = state |> Notation.encode() |> Notation.decode()

    assert decoded.phase == state.phase
    assert decoded.current_dealer == state.current_dealer
    assert decoded.cumulative_scores == state.cumulative_scores
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
