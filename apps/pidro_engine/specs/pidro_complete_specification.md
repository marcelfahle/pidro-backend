# Pidro Game Engine Specification
## Finnish Variant - Complete Implementation Guide

> "Make it work, make it right, make it fast" - Kent Beck
> 
> This engine prioritizes correctness, clarity, and performance in that order.

---

## Table of Contents

1. [Architecture Philosophy](#architecture-philosophy)
2. [Core Design Patterns](#core-design-patterns)  
3. [Data Representations](#data-representations)
4. [Module Structure](#module-structure)
5. [Public API](#public-api)
6. [Finnish Variant Rules](#finnish-variant-rules)
7. [Property-Based Testing](#property-based-testing)
8. [Performance Optimizations](#performance-optimizations)
9. [Implementation Roadmap](#implementation-roadmap)

---

## Architecture Philosophy

Inspired by successful game engines (binbo, Lichess, chess engines), we adopt:

1. **Pure Functional Core**: All game logic is pure functions
2. **Immutable State**: Game state never mutates, only transforms
3. **Event Sourcing**: Every action is an event, enabling replay/undo
4. **Binary Representations**: For performance-critical operations
5. **Property-Based Testing**: Mathematical proof of correctness
6. **ETS Caching**: For move generation and validation
7. **Clear Separation**: Game logic ≠ delivery mechanism

---

## Core Design Patterns

### 1. Event Sourcing Pattern

```elixir
# Every game action becomes an event
@type event ::
  {:dealer_selected, position, card}
  | {:cards_dealt, %{position => [card]}}
  | {:bid_made, position, amount}
  | {:trump_declared, suit}
  | {:cards_discarded, position, [card]}
  | {:card_played, position, card}
  | {:trick_won, position, points}
  | {:hand_scored, team, points}

@type game_history :: [event]

# Game state can be rebuilt from events
def replay_game(events) do
  Enum.reduce(events, new_game(), &apply_event/2)
end
```

### 2. Binary Game State Representation

```elixir
# Inspired by chess bitboards - use binaries for fast operations
defmodule Pidro.Binary do
  # Each card = 6 bits (4 for rank, 2 for suit)
  # Hand = 36 bits (6 cards max)
  # Full game state ~200 bytes
  
  @type binary_state :: <<_::1600>>  # 200 bytes
  
  def encode_state(game_state) do
    <<
      encode_phase(game_state.phase)::8,
      encode_positions(game_state.players)::512,
      encode_scores(game_state.scores)::64,
      encode_trump(game_state.trump_suit)::2,
      # ...
    >>
  end
  
  def decode_state(binary) do
    # Fast deserialization
  end
end
```

### 3. Move Generation Cache (ETS)

```elixir
defmodule Pidro.MoveCache do
  @moduledoc """
  Caches legal moves for positions using ETS.
  Inspired by chess engine move generation.
  """
  
  def init do
    :ets.new(:pidro_moves, [:set, :public, :named_table])
  end
  
  def get_or_compute(game_state, position) do
    key = hash_relevant_state(game_state, position)
    
    case :ets.lookup(:pidro_moves, key) do
      [{^key, moves}] -> moves
      [] ->
        moves = compute_legal_moves(game_state, position)
        :ets.insert(:pidro_moves, {key, moves})
        moves
    end
  end
end
```

### 4. Notation System (Like FEN in Chess)

```elixir
# Pidro Game Notation (PGN) - encode entire game state as string
defmodule Pidro.Notation do
  @doc """
  Encodes game state as string notation.
  Example: "N9E9S9W9/7h/bE6/t5h/pN/sNS20EW15/h3"
  
  Parts:
  - Initial hands (N9E9S9W9 = each player has 9 cards)
  - Current bid (7h = 7 high by highest bidder)
  - Bidder (bE = bid by East)
  - Trump (t5h = trump is hearts, 5 tricks played)
  - Phase (pN = playing phase, North to move)
  - Scores (sNS20EW15 = North/South 20, East/West 15)
  - Hand number (h3 = hand 3)
  """
  def encode(game_state) do
    # Compact string representation
  end
  
  def decode(pgn_string) do
    # Parse back to game state
  end
end
```

---

## Data Representations

### Primary Representation (Functional)

```elixir
defmodule Pidro.Core.Types do
  @type suit :: :hearts | :diamonds | :clubs | :spades
  @type rank :: 2..14
  @type card :: {rank, suit}
  @type position :: :north | :east | :south | :west
  @type team :: :north_south | :east_west
  
  @type phase :: 
    :dealer_selection |
    :dealing |
    :bidding |
    :declaring |
    :discarding |
    :second_deal |
    :playing |
    :scoring |
    :complete
    
  @type game_state :: %GameState{
    # Core state
    phase: phase,
    hand_number: non_neg_integer,
    
    # Players
    players: %{position => player_state},
    current_dealer: position | nil,
    current_turn: position | nil,
    
    # Bidding
    bids: [bid],
    highest_bid: {position, 6..14} | nil,
    
    # Trump
    trump_suit: suit | nil,
    
    # Play
    tricks: [trick],
    current_trick: trick | nil,
    
    # Scoring
    scores: %{team => integer},
    cumulative_scores: %{team => integer},
    
    # History (for replay/undo)
    events: [event],
    
    # Performance cache
    cache: %{
      legal_moves: map,
      binary_state: binary
    }
  }
end
```

### Optimized Binary Representation

```elixir
defmodule Pidro.Core.Binary do
  @moduledoc """
  Binary encoding for performance-critical operations.
  Used for:
  - State hashing
  - Network transmission  
  - Move generation
  - State comparison
  """
  
  # Card: 6 bits (rank: 4 bits, suit: 2 bits)
  @card_bits 6
  
  # Encode 52-card deck as bitset (for dealt/undealt tracking)
  @deck_bitset_size 52
  
  def encode_card({rank, suit}) do
    <<(rank - 2)::4, suit_to_bits(suit)::2>>
  end
  
  def encode_hand(cards) when length(cards) <= 6 do
    padded = cards ++ List.duplicate(nil, 6 - length(cards))
    for card <- padded, into: <<>> do
      case card do
        nil -> <<0::@card_bits>>
        c -> encode_card(c)
      end
    end
  end
  
  defp suit_to_bits(:hearts), do: 0b00
  defp suit_to_bits(:diamonds), do: 0b01
  defp suit_to_bits(:clubs), do: 0b10
  defp suit_to_bits(:spades), do: 0b11
end
```

---

## Module Structure

```elixir
lib/
├── pidro.ex                    # Public API
├── pidro/
│   ├── core/                   # Pure game logic
│   │   ├── types.ex            # Type definitions
│   │   ├── card.ex             # Card operations
│   │   ├── deck.ex             # Deck management
│   │   ├── dealer.ex           # Dealer selection
│   │   ├── binary.ex           # Binary encoding
│   │   └── notation.ex         # PGN notation
│   ├── game/
│   │   ├── state.ex            # State management
│   │   ├── events.ex           # Event sourcing
│   │   ├── validator.ex        # Move validation
│   │   ├── generator.ex        # Move generation
│   │   └── cache.ex            # ETS caching
│   ├── finnish/
│   │   ├── rules.ex            # Finnish variant rules
│   │   ├── scorer.ex           # Scoring logic
│   │   └── engine.ex           # Main engine
│   └── analysis/
│       ├── replay.ex           # Game replay
│       ├── stats.ex            # Statistics
│       └── export.ex           # Export formats
```

---

## Public API

### Core Functions

```elixir
defmodule Pidro do
  @moduledoc """
  Public API for Pidro game engine.
  All functions are pure and return {:ok, result} or {:error, reason}.
  """
  
  # Game lifecycle
  @spec new_game(opts :: keyword) :: {:ok, GameState.t}
  @spec apply_action(GameState.t, action) :: {:ok, GameState.t} | {:error, reason}
  @spec legal_actions(GameState.t, position) :: [action]
  @spec game_over?(GameState.t) :: boolean
  @spec winner(GameState.t) :: team | nil
  
  # Notation and serialization
  @spec to_pgn(GameState.t) :: String.t
  @spec from_pgn(String.t) :: {:ok, GameState.t} | {:error, reason}
  @spec to_binary(GameState.t) :: binary
  @spec from_binary(binary) :: {:ok, GameState.t} | {:error, reason}
  
  # Analysis and replay
  @spec replay_from_events([event]) :: {:ok, GameState.t}
  @spec get_history(GameState.t) :: [event]
  @spec undo_last_action(GameState.t) :: {:ok, GameState.t} | {:error, :no_history}
  
  # Performance helpers
  @spec precompute_moves(GameState.t) :: GameState.t
  @spec clear_cache() :: :ok
end
```

### Action Types

```elixir
@type action ::
  # Dealer selection
  {:cut_deck, position}
  
  # Bidding
  {:bid, amount :: 6..14}
  | :pass
  
  # Trump
  {:declare_trump, suit}
  
  # Discard
  {:discard, [card]}
  
  # Play
  {:play_card, card}
  
  # Meta
  | :resign
  | :claim_remaining
```

---

## Finnish Variant Rules

### Key Rules Summary

1. **Players**: 4 in partnerships (N/S vs E/W)
2. **Cards**: 52-card deck, 14 cards per trump suit (includes off-pedro)
3. **Objective**: First to 62 points wins
4. **Finnish Specific**: Only trumps are played; non-trumps are camouflage
5. **Point Cards**: A(1), J(1), 10(1), 5(5), off-5(5), 2(1) = 14 total

### Detailed Flow

```elixir
defmodule Pidro.Finnish.Rules do
  @behaviour Pidro.Variant
  
  @impl true
  def initial_state do
    %GameState{
      phase: :dealer_selection,
      variant: :finnish,
      config: %{
        min_bid: 6,
        max_bid: 14,
        winning_score: 62,
        cards_in_hand: 6,
        initial_deal: 9,
        allow_negative: true
      }
    }
  end
  
  @impl true
  def is_legal_action?(state, position, action) do
    case {state.phase, action} do
      {:bidding, {:bid, amount}} ->
        amount > current_high_bid(state) and amount <= 14
        
      {:playing, {:play_card, card}} ->
        is_trump?(card, state.trump_suit) and 
        card in state.players[position].hand
        
      # ... other cases
    end
  end
  
  @impl true
  def apply_action(state, position, action) do
    # Returns new state with action applied
    # Updates event history
    # Triggers phase transitions
  end
  
  @impl true
  def score_trick(trick, trump_suit) do
    # Special: 2 always gives 1 point to player who played it
    # All other points go to trick winner
  end
end
```

---

## Property-Based Testing

### Test Infrastructure

```elixir
# mix.exs
defp deps do
  [
    # Production
    {:typed_struct, "~> 0.3"},
    {:accessible, "~> 0.3"},
    
    # Development/Test
    {:stream_data, "~> 1.0", only: [:test, :dev]},
    {:propcheck, "~> 1.4", only: [:test]},
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.30", only: :dev, runtime: false},
    {:benchee, "~> 1.0", only: :dev}
  ]
end
```

### Core Properties

```elixir
defmodule Pidro.Properties do
  use ExUnitProperties
  
  # 1. Game Invariants
  property "total points in play always equals 14" do
    check all state <- game_state_generator() do
      total_points = calculate_total_points(state)
      assert total_points <= 14
    end
  end
  
  property "trump suit has exactly 14 cards including off-pedro" do
    check all suit <- suit_generator() do
      trump_cards = get_trump_cards(suit)
      assert length(trump_cards) == 14
      assert get_off_pedro(suit) in trump_cards
    end
  end
  
  # 2. State Machine Properties
  property "all state transitions are valid" do
    check all state <- game_state_generator(),
              action <- action_generator(state) do
      case apply_action(state, action) do
        {:ok, new_state} ->
          assert valid_transition?(state.phase, new_state.phase)
        {:error, _} ->
          # Invalid action correctly rejected
          true
      end
    end
  end
  
  property "game terminates within reasonable moves" do
    check all initial <- initial_state_generator(),
              max_runs: 100 do
      final = play_random_game(initial, max_moves: 1000)
      assert final.phase == :complete
    end
  end
  
  # 3. Determinism Properties
  property "replay from events produces identical state" do
    check all game <- complete_game_generator() do
      events = game.events
      replayed = replay_from_events(events)
      
      # Compare without events field (avoid recursion)
      assert Map.delete(game, :events) == Map.delete(replayed, :events)
    end
  end
  
  property "PGN round-trip preserves game state" do
    check all state <- game_state_generator() do
      pgn = to_pgn(state)
      {:ok, decoded} = from_pgn(pgn)
      
      # Binary comparison for exact match
      assert to_binary(state) == to_binary(decoded)
    end
  end
  
  # 4. Performance Properties
  @tag :performance
  property "state updates complete within 1ms" do
    check all state <- game_state_generator(),
              action <- legal_action_generator(state) do
      {time, _result} = :timer.tc(fn ->
        apply_action(state, action)
      end)
      
      assert time < 1000  # microseconds
    end
  end
  
  # 5. Concurrency Properties
  property "concurrent reads don't corrupt state" do
    check all state <- game_state_generator() do
      # Spawn 100 concurrent readers
      tasks = for _ <- 1..100 do
        Task.async(fn ->
          legal_actions(state, :north)
          to_pgn(state)
          to_binary(state)
        end)
      end
      
      Task.await_many(tasks)
      
      # State unchanged
      assert to_binary(state) == to_binary(state)
    end
  end
end
```

### Generators

```elixir
defmodule Pidro.Generators do
  use ExUnitProperties
  
  def game_state_generator do
    gen all phase <- phase_generator(),
            players <- players_generator(),
            trump <- suit_generator() do
      %GameState{
        phase: phase,
        players: players,
        trump_suit: trump,
        # ...
      }
    end
  end
  
  def complete_game_generator do
    # Generates a full game from start to finish
    gen all seed <- integer() do
      :rand.seed(:exsss, {seed, seed, seed})
      play_random_game(new_game())
    end
  end
  
  def legal_action_generator(state) do
    # Only generates legal actions for current state
    actions = legal_actions(state, state.current_turn)
    one_of(Enum.map(actions, &constant/1))
  end
end
```

---

## Performance Optimizations

### 1. Binary State for Hashing

```elixir
defmodule Pidro.Performance do
  @doc "Fast state comparison using binary"
  def states_equal?(state1, state2) do
    to_binary(state1) == to_binary(state2)
  end
  
  @doc "Fast state hashing for caching"
  def hash_state(state) do
    :erlang.phash2(to_binary(state))
  end
end
```

### 2. Move Generation Optimization

```elixir
defmodule Pidro.MoveGenerator do
  use GenServer
  
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def init(_) do
    # Pre-generate common positions
    :ets.new(:move_cache, [:named_table, :public, :set])
    {:ok, %{}}
  end
  
  def generate_moves(state, position) do
    key = {state.phase, position, state.trump_suit, hash_hand(state.players[position].hand)}
    
    case :ets.lookup(:move_cache, key) do
      [{^key, moves}] -> 
        moves
      [] ->
        moves = compute_moves(state, position)
        :ets.insert(:move_cache, {key, moves})
        moves
    end
  end
end
```

### 3. Benchmarking

```elixir
defmodule Pidro.Benchmark do
  def run do
    Benchee.run(%{
      "apply_action" => fn -> apply_action(state, action) end,
      "legal_actions" => fn -> legal_actions(state, :north) end,
      "to_binary" => fn -> to_binary(state) end,
      "from_binary" => fn -> from_binary(binary) end,
      "score_hand" => fn -> score_hand(state) end
    })
  end
end
```

---

## Implementation Roadmap

### Phase 1: Core Types and Data Structures ✅
- [ ] Define all type specifications with Dialyzer
- [ ] Implement Card and Deck modules
- [ ] Create GameState struct with TypedStruct
- [ ] Add binary encoding/decoding
- [ ] Property tests for data structures

### Phase 2: Dealer Selection and Setup ✅
- [ ] Implement dealer cutting logic
- [ ] Dealer rotation between hands
- [ ] Initial deal (9 cards each)
- [ ] Property tests for fair dealing

### Phase 3: Bidding System ✅
- [ ] Bidding validation and rules
- [ ] Forced dealer bid (all pass)
- [ ] Highest bidder determination
- [ ] Property tests for bid sequences

### Phase 4: Trump and Discard ✅
- [ ] Trump declaration
- [ ] Card categorization (trump/off-trump)
- [ ] Discard validation
- [ ] Second deal with dealer special rules
- [ ] Property tests for card distribution

### Phase 5: Play Engine ✅
- [ ] Finnish rules (only trumps played)
- [ ] Trick-taking logic
- [ ] Player elimination when out of trumps
- [ ] Low (2) special scoring rule
- [ ] Property tests for play rules

### Phase 6: Scoring System ✅
- [ ] Point calculation per trick
- [ ] Team aggregation
- [ ] Negative scoring for failed bids
- [ ] Game end detection
- [ ] Property tests for scoring invariants

### Phase 7: Event Sourcing ✅
- [ ] Event history tracking
- [ ] Replay from events
- [ ] Undo functionality
- [ ] PGN notation system
- [ ] Property tests for replay consistency

### Phase 8: Performance Layer ✅
- [ ] ETS move caching
- [ ] Binary state optimization
- [ ] Benchmark suite
- [ ] Performance property tests

### Phase 9: Interactive Shell ✅
- [ ] IEx helpers
- [ ] Pretty printing
- [ ] Game visualization
- [ ] Step debugger

### Phase 10: Documentation ✅
- [ ] ExDoc setup
- [ ] API documentation
- [ ] Usage examples
- [ ] Performance guide

---

## Configuration

```elixir
# config/config.exs
import Config

config :pidro,
  variant: :finnish,
  cache_moves: true,
  cache_size: 10_000,
  enable_history: true,
  max_history: 1000

# config/test.exs
config :pidro,
  cache_moves: false,  # Disable for deterministic tests
  enable_history: true

config :stream_data,
  max_runs: System.get_env("CI") && 1000 || 100
```

---

## Success Metrics

1. **Correctness**: 100% property test pass rate
2. **Performance**: <1ms per action, <100ms per complete game
3. **Memory**: <10KB per game state
4. **Code Quality**: Dialyzer clean, Credo pass, 100% doc coverage
5. **Testability**: Can simulate 10,000 games without errors

---

## Appendix: Example Usage

```elixir
# Start a new game
iex> {:ok, game} = Pidro.new_game()

# Cut for dealer (first hand)
iex> {:ok, game} = game
  |> Pidro.apply_action(:north, {:cut_deck, :north})
  |> elem(1)
  |> Pidro.apply_action(:east, {:cut_deck, :east})
  # ... etc

# Make a bid
iex> {:ok, game} = Pidro.apply_action(game, :north, {:bid, 7})

# Get legal moves
iex> Pidro.legal_actions(game, :east)
[:pass, {:bid, 8}, {:bid, 9}, ...]

# Play a card
iex> {:ok, game} = Pidro.apply_action(game, :north, {:play_card, {14, :hearts}})

# Check game state
iex> Pidro.to_pgn(game)
"N6E6S6W6/7n/bN/th/pN/sNS0EW0/h1"

# Replay from history
iex> events = Pidro.get_history(game)
iex> {:ok, replayed} = Pidro.replay_from_events(events)

# Export for analysis
iex> File.write!("game.pgn", Pidro.to_pgn(game))
```

---

## References

- [binbo](https://github.com/DOBRO/binbo) - Elixir chess engine architecture
- [Lichess Architecture](https://www.davidreis.me/2024/what-happens-when-you-make-a-move-in-lichess) - Event sourcing, caching
- [Chess Engine Design](https://obrhubr.org/chess-engine) - Binary representations, move generation

---

*"Simple things should be simple, complex things should be possible."* - Alan Kay

This specification provides a complete blueprint for a Pidro engine that is correct, performant, and maintainable.
