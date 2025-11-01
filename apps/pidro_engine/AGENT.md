# Pidro Engine - Agent Guide

Quick reference for building, testing, and understanding the Finnish Pidro game engine.

---

## Project Setup

This is an Elixir umbrella app. The engine is located at:
```
apps/pidro_engine/
```

### Dependencies
```bash
mix deps.get
```

### Compilation
```bash
mix compile
```

---

## Running Tests

### All Tests
```bash
mix test
```

### Unit Tests Only
```bash
mix test test/unit/
```

### Property Tests Only
```bash
mix test test/properties/
```

### Specific Test File
```bash
mix test test/unit/card_test.exs
```

### Run Tests with Coverage
```bash
mix test --cover
```

---

## Code Quality Tools

### Type Checking (Dialyzer)
```bash
mix dialyzer
```

### Code Quality (Credo)
```bash
mix credo --strict
```

### Generate Documentation
```bash
mix docs
```

---

## Key Finnish Pidro Rules (The Gotchas)

### The Wrong 5 Rule
The most important rule that differs from other Pidro variants:
- When a suit is declared trump, BOTH the Right 5 and Wrong 5 are trump cards
- **Right 5**: The 5 of the trump suit (worth 5 points)
- **Wrong 5**: The 5 of the SAME COLOR suit (also worth 5 points)

Examples:
- If Hearts is trump → 5 of Diamonds is also trump (hearts and diamonds are both red)
- If Clubs is trump → 5 of Spades is also trump (clubs and spades are both black)

### Trump Ranking Order
From highest to lowest:
```
A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
```

Key point: Right 5 beats Wrong 5, but both rank BELOW the 6 of trump.

### Point Distribution
Total points per suit: **14 points**
- Ace: 1 point
- Jack: 1 point
- 10: 1 point
- Right 5: 5 points
- Wrong 5: 5 points
- 2: 1 point
- All others: 0 points

### The 2 of Trump Rule
When a player wins a trick containing the 2 of trump, they keep 1 point for themselves (not their team). This is the only card that scores individually.

---

## Project Structure

```
lib/pidro/
├── core/                    # Core data structures
│   ├── types.ex            # Type definitions
│   ├── card.ex             # Card operations (trump logic, ranking)
│   ├── deck.ex             # Deck operations (shuffle, deal)
│   ├── player.ex           # Player state
│   ├── trick.ex            # Trick-taking logic
│   └── gamestate.ex        # Game state container
├── game/                    # Game logic (Phase 2+)
│   ├── engine.ex           # Main game engine API
│   ├── state_machine.ex    # Phase transitions
│   ├── bidding.ex          # Bidding logic
│   ├── dealing.ex          # Card dealing
│   ├── trump.ex            # Trump declaration
│   ├── discard.ex          # Discard phase
│   ├── play.ex             # Trick-taking gameplay
│   └── scoring.ex          # Scoring logic
├── finnish/                 # Finnish variant specifics
│   ├── rules.ex            # Finnish rule validation
│   ├── scorer.ex           # Finnish scoring rules
│   └── engine.ex           # Finnish-specific engine wrapper
└── notation/                # Game notation (Phase 8)
    └── pgn.ex              # PGN-like notation system

test/
├── unit/                    # Unit tests for modules
├── properties/              # Property-based tests
└── support/
    └── generators.ex        # StreamData generators
```

---

## Development Workflow

### Current Status (as of Phase 1)
Phase 0 and Phase 1 are complete:
- Project scaffold with all dependencies
- Core types (Card, Deck, Player, Trick, GameState)
- Property-based tests for deck and card operations
- All wrong 5 logic implemented and tested

### Next Steps (Phase 2+)
- State machine and game engine API
- Bidding system
- Trump declaration and discard phase
- Trick-taking gameplay
- Scoring system

### Development Cycle
1. Read the phase requirements in `_masterplan.md`
2. Implement the module with `@spec` for all public functions
3. Write unit tests in `test/unit/`
4. Write property tests in `test/properties/`
5. Run `mix test` - all tests must pass
6. Run `mix dialyzer` - must be clean
7. Run `mix credo --strict` - must pass
8. Update `_masterplan.md` to mark phase complete

---

## Testing Philosophy

### Property-Based Testing
This project uses StreamData for property-based testing to prove correctness mathematically.

Key properties tested:
- Deck always contains exactly 52 cards
- Wrong 5 is always trump when same-color suit is trump
- Trump ranking is transitive and consistent
- Card comparison is transitive
- Point values always sum to 14 per suit

### Writing Generators
Custom generators are in `test/support/generators.ex`:
```elixir
# Example: Generate valid cards
card_generator =
  StreamData.tuple({
    StreamData.integer(2..14),  # rank
    StreamData.member_of([:hearts, :diamonds, :clubs, :spades])  # suit
  })
```

---

## Common Issues & Solutions

### Issue: Dialyzer Warnings
**Solution**: Ensure all public functions have `@spec` declarations. Check return types match specs.

### Issue: Wrong 5 Not Treated as Trump
**Solution**: Use `Pidro.Core.Card.is_trump?/2` which handles the same-color logic. Don't manually check suit equality.

### Issue: Property Tests Fail Intermittently
**Solution**: Check generators are producing valid data. Property tests run 100 times by default.

### Issue: Compilation Errors After Adding Module
**Solution**: Check that aliases and type imports are correct. Ensure parent modules exist.

---

## IEx Interactive Development

### Start IEx with Project Loaded
```bash
iex -S mix
```

### Common IEx Commands
```elixir
# Create a card
card = Pidro.Core.Card.new(14, :hearts)

# Check if card is trump
Pidro.Core.Card.is_trump?(card, :hearts)

# Create and shuffle a deck
deck = Pidro.Core.Deck.new() |> Pidro.Core.Deck.shuffle()

# Deal cards
{cards, remaining_deck} = Pidro.Core.Deck.deal_batch(deck, 9)

# Create a player
player = Pidro.Core.Player.new(:north, :north_south)

# Add cards to player's hand
player = Pidro.Core.Player.add_cards(player, cards)

# Reload modules after changes
r Pidro.Core.Card
```

---

## Performance Notes

The engine is designed with performance in mind for future optimizations:
- Binary encoding for game state (planned Phase 9)
- ETS caching for legal moves (planned Phase 9)
- Immutable data structures (efficient copying with structure sharing)
- Pure functions (enables parallelization)

Current focus: Correctness first, performance later.

---

## Architecture Principles

### Pure Functional Core
- All game logic is pure functions
- No side effects in core modules
- Deterministic behavior (same input = same output)

### Immutable State
- Game state never mutates
- All operations return new state
- Enables undo/replay (planned Phase 8)

### Event Sourcing
- Every action produces an event
- State can be rebuilt from event history
- Enables time travel debugging

### Separation of Concerns
- Core logic (lib/pidro/core/) - data structures only
- Game logic (lib/pidro/game/) - rules and gameplay
- Variant-specific (lib/pidro/finnish/) - Finnish rules
- Delivery (future) - GenServer wrapper for Phoenix

---

## Resources

- **Game Spec**: `specs/pidro_complete_specification.md` - Complete rules and API
- **Properties**: `specs/game_properties.md` - All testable properties
- **Master Plan**: `_masterplan.md` - Implementation roadmap and status
- **Original Rules**: Ask the oracle (user) for Finnish-specific rule clarifications

---

**Last Updated**: 2025-11-01
**Current Phase**: Phase 1 Complete, Phase 2 Next
**Status**: Core types implemented and tested
