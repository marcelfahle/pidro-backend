# Pidro IEx Helpers

Interactive development helpers for the Pidro game engine. These utilities make it easy to explore game state, test actions, and play games directly from the IEx console.

## Quick Start

Start IEx with the project:

```bash
cd apps/pidro_engine
iex -S mix
```

Import the helpers:

```elixir
import Pidro.IEx
```

## Available Functions

### `new_game/0`

Creates a new game with dealer selection complete and ready for bidding.

```elixir
iex> state = new_game()
iex> state.phase
:bidding
iex> state.current_dealer
:south  # (varies randomly)
```

### `pretty_print/1`

Displays the game state in a beautiful, human-readable format with:
- Current phase and hand number
- Dealer and current turn
- Trump suit (when declared)
- Scores (hand and cumulative)
- Each player's hand with ASCII cards
- Trump indicators (★) and point values
- Current trick (during play)
- Bidding history

```elixir
iex> state = new_game()
iex> pretty_print(state)

╔═══════════════════════════════════════════════════════════╗
║              PIDRO - Finnish Variant                      ║
╚═══════════════════════════════════════════════════════════╝

Phase:       Bidding
Hand:        #1
Dealer:      South
Turn:        West

Scores:
  North/South: 0 this hand, 0 total
  East/West: 0 this hand, 0 total

Players:

  North (North/South)
    Hand: 5♠  Q♥★  K♥★  9♣  J♦  J♣  5♦★  K♠  3♣

  East (East/West)
    Hand: 7♣  4♣  Q♣  5♣  6♦  K♣  A♠  8♣  2♦

  ...
```

### `show_legal_actions/2`

Shows all legal actions for a given position in the current state.

```elixir
iex> state = new_game()
iex> show_legal_actions(state, :west)

Legal Actions for West:
  1. Bid 6
  2. Bid 7
  3. Bid 8
  4. Bid 9
  5. Bid 10
  6. Bid 11
  7. Bid 12
  8. Bid 13
  9. Bid 14
  10. Pass

[{:bid, 6}, {:bid, 7}, ..., :pass]
```

### `step/3`

Applies an action to the game state and displays the result. This is the main function for interactive play.

```elixir
iex> state = new_game()
iex> {:ok, state} = step(state, :west, {:bid, 10})

► West performs: Bid 10

✓ Action successful!

[Game state displayed...]

iex> {:ok, state} = step(state, :north, :pass)
iex> {:ok, state} = step(state, :east, :pass)
iex> {:ok, state} = step(state, :south, :pass)

# Now in declaring phase
iex> {:ok, state} = step(state, :west, {:declare_trump, :hearts})
```

### `demo_game/0`

Runs an automated demonstration game that plays through several phases:
1. Game creation and initial deal
2. Bidding round with automated bids
3. Trump declaration
4. Playing first few tricks

```elixir
iex> demo_game()

═══════════════════════════════════════════════════════════
         PIDRO DEMONSTRATION GAME
═══════════════════════════════════════════════════════════

Step 1: Game Created and Initial Deal Complete
[Game state displayed...]

[Press Enter to continue]

Step 2: Bidding Round
  West: Bid 8
  North: Pass
  East: Bid 10
  South: Pass
[Game state displayed...]

[Press Enter to continue]

Step 3: Trump Declaration
  East: Declare Hearts ♥
[Game state displayed...]

...
```

## Interactive Play Example

Here's a complete example of playing through a game interactively:

```elixir
# Start a new game
iex> import Pidro.IEx
iex> state = new_game()
iex> pretty_print(state)

# Bidding phase
iex> show_legal_actions(state, state.current_turn)
iex> {:ok, state} = step(state, :west, {:bid, 10})
iex> {:ok, state} = step(state, :north, :pass)
iex> {:ok, state} = step(state, :east, {:bid, 11})
iex> {:ok, state} = step(state, :south, :pass)

# Trump declaration
iex> {:ok, state} = step(state, :east, {:declare_trump, :hearts})

# Game automatically discards non-trumps and deals remaining cards

# Playing phase - play trump cards
iex> show_legal_actions(state, state.current_turn)
iex> {:ok, state} = step(state, state.current_turn, {:play_card, {14, :hearts}})
# Continue playing...
```

## Card Display Format

Cards are displayed with beautiful ASCII art:

- **Rank**: `A` (Ace), `K` (King), `Q` (Queen), `J` (Jack), `10`, `9`, etc.
- **Suit**: `♥` (Hearts), `♦` (Diamonds), `♣` (Clubs), `♠` (Spades)
- **Color**: Red for Hearts/Diamonds, White for Clubs/Spades
- **Trump Indicator**: `★` for trump cards
- **Point Values**: `[5]` for fives, `[1]` for ace/jack/ten/two

Example: `A♥[1]★` = Ace of Hearts (1 point, trump)

## Features

- **Color-coded output**: Different colors for teams, actions, and card suits
- **Trump indicators**: Clear visual markers for trump cards
- **Point values**: Shows point values on scoring cards
- **Error messages**: Clear, helpful error messages when actions fail
- **Legal actions**: Easy way to see what moves are valid
- **Game flow**: Step-by-step progression through game phases
- **Auto-transitions**: Automatic handling of dealer selection, dealing, discarding, and scoring

## Tips

1. **Check legal actions first**: Use `show_legal_actions/2` before making a move
2. **Use tab completion**: IEx supports tab completion for function names
3. **Save state**: Assign the result of `step/3` back to `state` to continue playing
4. **Demo for learning**: Run `demo_game()` to see how a complete game flows
5. **Pretty print often**: Call `pretty_print(state)` whenever you want to see the current state

## Finnish Pidro Rules Quick Reference

- **Initial Deal**: 9 cards per player
- **Bidding**: 6-14 points, or pass
- **Trump**: Winner declares trump suit
- **Discard**: All non-trump cards automatically discarded
- **Final Hand**: 6 cards per player (dealer robs remaining pack)
- **Play**: Only trump cards can be played
- **Going Cold**: Players eliminated when out of trumps
- **Scoring**: 14 points per hand; first team to 62 wins

## Troubleshooting

**No legal actions available?**
- Check the current phase with `state.phase`
- Verify it's the correct player's turn with `state.current_turn`
- Some phases (dealing, discarding, scoring) are automatic

**Action fails?**
- Use `show_legal_actions/2` to see valid moves
- Read the error message carefully - it explains why the action failed
- Verify you're using the correct action format for the phase

**Want to start over?**
```elixir
iex> state = new_game()
```

## Module Documentation

For complete API documentation, run:

```elixir
iex> h Pidro.IEx
iex> h Pidro.IEx.pretty_print
iex> h Pidro.IEx.step
```

Enjoy playing Pidro!
