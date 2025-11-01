# Example IEx Session

This document shows a complete example of using the Pidro IEx helpers to play through a game interactively.

## Starting the Session

```elixir
$ cd apps/pidro_engine
$ iex -S mix

iex(1)> import Pidro.IEx
Pidro.IEx

iex(2)> state = new_game()
%Pidro.Core.Types.GameState{...}

iex(3)> pretty_print(state)

╔═══════════════════════════════════════════════════════════╗
║              PIDRO - Finnish Variant                      ║
╚═══════════════════════════════════════════════════════════╝

Phase:       Bidding
Hand:        #1
Dealer:      East
Turn:        South

Scores:
  North/South: 0 this hand, 0 total
  East/West: 0 this hand, 0 total

Players:

  North (North/South)
    Hand: 4♦  7♠  A♣  8♦  6♦  9♣  J♠  7♣  9♠

  East (East/West)
    Hand: 6♣  K♠  J♣  9♦  10♠  Q♣  A♦  K♣  10♦

  South (North/South)
    Hand: 10♣  6♠  K♦  5♥[5]★  10♥[1]★  K♥★  9♥★  4♥★  5♠

  West (East/West)
    Hand: 8♣  3♠  7♥★  J♥[1]★  J♦  4♠  Q♦  A♥[1]★  3♥★

:ok
```

## Bidding Phase

```elixir
iex(4)> show_legal_actions(state, :south)

Legal Actions for South:
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

[{:bid, 6}, {:bid, 7}, {:bid, 8}, {:bid, 9}, {:bid, 10}, {:bid, 11}, 
 {:bid, 12}, {:bid, 13}, {:bid, 14}, :pass]

iex(5)> {:ok, state} = step(state, :south, {:bid, 10})

► South performs: Bid 10

✓ Action successful!

[Updated game state displayed...]

iex(6)> {:ok, state} = step(state, :west, {:bid, 12})
iex(7)> {:ok, state} = step(state, :north, :pass)
iex(8)> {:ok, state} = step(state, :east, :pass)
iex(9)> {:ok, state} = step(state, :south, :pass)

# Now in declaring phase - West won the bidding
```

## Trump Declaration

```elixir
iex(10)> show_legal_actions(state, :west)

Legal Actions for West:
  1. Declare Hearts ♥
  2. Declare Diamonds ♦
  3. Declare Clubs ♣
  4. Declare Spades ♠

[{:declare_trump, :hearts}, {:declare_trump, :diamonds}, 
 {:declare_trump, :clubs}, {:declare_trump, :spades}]

iex(11)> {:ok, state} = step(state, :west, {:declare_trump, :hearts})

► West performs: Declare Hearts ♥

✓ Action successful!

[Game automatically discards non-trumps and deals remaining cards]
[Now in playing phase]
```

## Playing Phase

```elixir
iex(12)> pretty_print(state)

Phase:       Playing
Trump:       Hearts ♥

Players:

  North (North/South)
    Hand: [Empty or only trumps]

  East (East/West)
    Hand: [6 cards - trumps only]

  South (North/South)
    Hand: 5♥[5]★  10♥[1]★  K♥★  9♥★  4♥★  2♥[1]★

  West (East/West)
    Hand: 7♥★  J♥[1]★  A♥[1]★  3♥★  6♥★  8♥★

iex(13)> show_legal_actions(state, state.current_turn)

Legal Actions for South:
  1. Play 5♥[5]★
  2. Play 10♥[1]★
  3. Play K♥★
  4. Play 9♥★
  5. Play 4♥★
  6. Play 2♥[1]★

iex(14)> {:ok, state} = step(state, state.current_turn, {:play_card, {14, :hearts}})

► South performs: Play A♥[1]★

✓ Action successful!

[Continue playing until hand is complete]
```

## Quick Demo

For a quick demonstration without manual play:

```elixir
iex(1)> import Pidro.IEx
iex(2)> demo_game()

═══════════════════════════════════════════════════════════
         PIDRO DEMONSTRATION GAME
═══════════════════════════════════════════════════════════

[Automated game plays through several phases]
[Press Enter at each pause to continue]
```

## Tips for Interactive Play

1. **Save your state**: Always assign the result of `step/3` back to `state`:
   ```elixir
   {:ok, state} = step(state, :north, {:bid, 10})
   ```

2. **Check actions first**: Use `show_legal_actions/2` before attempting a move:
   ```elixir
   actions = show_legal_actions(state, :north)
   ```

3. **Explore game state**: The state struct has many useful fields:
   ```elixir
   state.phase           # Current phase
   state.current_turn    # Whose turn it is
   state.trump_suit      # Declared trump (if any)
   state.highest_bid     # Current highest bid
   state.players         # Map of all player states
   ```

4. **Pretty print frequently**: Keep track of the game state visually:
   ```elixir
   pretty_print(state)
   ```

5. **Tab completion**: IEx supports tab completion - type `Pidro.IEx.` then press Tab to see available functions.
