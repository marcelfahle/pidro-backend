# Auto Dealer Rob Bug Fix - Non-Dealer Players Not Receiving Cards

## Overview

Fix critical bug where non-dealer players never receive replacement cards during the second deal phase when `auto_dealer_rob: true`. The automatic phase handler in `lib/pidro/game/engine.ex:535-571` completely bypasses `Discard.second_deal/1`, which is the only function responsible for distributing cards to non-dealer players.

**Severity**: CRITICAL - Game is unplayable in auto mode (the default setting)

## Current State Analysis

### Root Cause (Primary Bug)

**File**: `lib/pidro/game/engine.ex:541-555`

When `auto_dealer_rob: true` (default) AND `deck_size > 0` (normal case):
- Code jumps directly to `dealer_rob_pack/2` without calling `second_deal/1` first
- Only the dealer's hand gets updated
- Non-dealer players retain their post-discard trump-only hands (0-9 cards)
- Game enters `:playing` phase with incorrect card distribution

### Suspected Secondary Bug

Evidence from `BUG_PROMPT.md` suggests `discard_non_trumps` may also not be running properly:
- Players still have non-trump cards in playing phase
- No `{:cards_discarded, ...}` events in event log
- Investigation needed to determine if this is a real bug or display issue

### Key Discoveries

**What `second_deal/1` does** (`lib/pidro/game/discard.ex:240-307`):
- Iterates non-dealer players clockwise from left of dealer
- Deals each player cards to reach exactly 6: `cards_needed = 6 - current_hand_size`
- Skips players who already have 6+ trump cards
- Determines if dealer needs to rob: `deck_size > 0 AND dealer_hand_size < 6`
- If dealer needs rob: stays in `:second_deal` phase, sets turn to dealer
- If dealer doesn't need rob: transitions to `:playing` phase

**What `dealer_rob_pack/2` does** (`lib/pidro/game/discard.ex:356-401`):
- ONLY updates dealer's hand with selected 6 cards
- Does NOT deal cards to non-dealer players
- Empties the deck
- Transitions to `:playing` phase

**Current broken flow**:
```
:declaring → declare_trump → :discarding
:discarding → discard_non_trumps → :second_deal
:second_deal → [BUG: skips second_deal] → dealer_rob_pack → :playing
```

**Expected correct flow**:
```
:declaring → declare_trump → :discarding
:discarding → discard_non_trumps → :second_deal
:second_deal → second_deal → dealer_rob_pack (if auto) → :playing
```

### Test Coverage Gap

**Existing tests verify**:
- `dealer_rob_pack/2` gives dealer exactly 6 cards (unit tests)
- `second_deal/1` deals cards to non-dealers (unit tests)
- State machine transition guard requires all players have 6 cards (property tests)

**Missing test**: Integration test that executes the COMPLETE automatic flow and verifies ALL 4 players end up with exactly 6 cards.

This gap allowed the bug to slip through despite 541 passing tests.

## Desired End State

After trump declaration and redeal with `auto_dealer_rob: true`:
- ✅ All 4 players have exactly 6 cards (unless kill rule applies)
- ✅ Phase is `:playing`
- ✅ Turn is set to player left of dealer
- ✅ Deck is empty
- ✅ Events recorded: `{:cards_discarded, ...}`, `{:second_deal_complete, ...}`, `{:dealer_robbed_pack, ...}`

### Verification Commands

```bash
# Run new failing tests first
mix test test/integration/auto_dealer_rob_integration_test.exs

# Should fail with: "Expected all players to have 6 cards, but got: ..."

# After fix, verify all tests pass
mix test

# Verify no regressions in existing dealer rob tests
mix test test/unit/game/discard_dealer_rob_test.exs
mix test test/properties/dealer_rob_properties_test.exs

# Verify property tests still pass
mix test test/properties/redeal_properties_test.exs
```

## What We're NOT Doing

- NOT changing the core `second_deal/1` logic (it works correctly)
- NOT changing `dealer_rob_pack/2` logic (it works correctly)
- NOT changing `discard_non_trumps/1` logic (investigating first)
- NOT modifying the game rules or specifications
- NOT changing the default config value of `auto_dealer_rob`
- NOT adding UI changes (this is pure backend fix)

## Implementation Approach

**Dave Thomas TDD Approach**:
1. Write failing integration tests FIRST that expose the bug
2. Write additional edge case tests (all failing)
3. Fix the bug with minimal code change
4. Watch all tests turn green
5. Investigate suspected secondary bug
6. Add property tests to prevent regression

**Key Principle**: The fix should be simple - `second_deal/1` already does the heavy lifting. We just need to call it in the right order.

---

## Phase 1: Write Failing Tests (Test-First)

### Overview

Write comprehensive integration tests that expose the bug BEFORE fixing it. These tests should fail with clear, specific error messages showing exactly what's wrong.

### Changes Required

#### 1. Create Integration Test File

**File**: `test/integration/auto_dealer_rob_integration_test.exs`
**Changes**: Create new test file with comprehensive integration tests

```elixir
defmodule Pidro.Integration.AutoDealerRobIntegrationTest do
  use ExUnit.Case, async: true
  alias Pidro.{GameState, Engine, Trump}
  alias Pidro.Core.Types

  describe "complete redeal flow with auto_dealer_rob: true" do
    setup do
      # Create game state with auto_dealer_rob enabled
      state =
        GameState.new()
        |> put_in([Access.key(:config), :auto_dealer_rob], true)
        |> put_in([Access.key(:phase)], :declaring)
        |> put_in([Access.key(:current_dealer)], :east)
        |> put_in([Access.key(:high_bidder)], :east)
        |> put_in([Access.key(:winning_bid)], 6)

      # Set up players with known hands
      # Each player has 9 cards with varying trump counts
      state = put_in(state.players, %{
        north: %Types.Player{
          hand: [
            %{rank: :ace, suit: :diamonds},     # 1 trump
            %{rank: 7, suit: :spades},
            %{rank: :ace, suit: :clubs},
            %{rank: 5, suit: :clubs},
            %{rank: 2, suit: :spades},
            %{rank: 10, suit: :spades},
            %{rank: 6, suit: :hearts},
            %{rank: :king, suit: :clubs},
            %{rank: 10, suit: :clubs}
          ]
        },
        east: %Types.Player{
          hand: [
            %{rank: 5, suit: :diamonds},        # 5 trump (including wrong-5)
            %{rank: 7, suit: :diamonds},
            %{rank: :ace, suit: :hearts},       # wrong-5
            %{rank: 7, suit: :hearts},
            %{rank: 2, suit: :clubs},
            %{rank: 6, suit: :clubs},
            %{rank: 5, suit: :hearts},
            %{rank: :jack, suit: :spades},
            %{rank: 9, suit: :clubs}
          ]
        },
        south: %Types.Player{
          hand: [
            %{rank: 10, suit: :diamonds},       # 2 trump
            %{rank: :queen, suit: :diamonds},
            %{rank: 3, suit: :spades},
            %{rank: 3, suit: :hearts},
            %{rank: 2, suit: :hearts},
            %{rank: 4, suit: :clubs},
            %{rank: 6, suit: :spades},
            %{rank: :queen, suit: :hearts},
            %{rank: 4, suit: :spades}
          ]
        },
        west: %Types.Player{
          hand: [
            %{rank: 6, suit: :diamonds},        # 4 trump (including 10 hearts wrong-5)
            %{rank: 8, suit: :diamonds},
            %{rank: 9, suit: :diamonds},
            %{rank: 10, suit: :hearts},         # This is NOT wrong-5 (5♥ is)
            %{rank: :king, suit: :spades},
            %{rank: :ace, suit: :spades},
            %{rank: :jack, suit: :clubs},
            %{rank: 7, suit: :clubs},
            %{rank: 8, suit: :hearts}
          ]
        }
      })

      # Set up remaining deck (16 cards)
      state = put_in(state.deck, [
        %{rank: :jack, suit: :diamonds},
        %{rank: 5, suit: :hearts},
        %{rank: 2, suit: :diamonds},
        %{rank: :jack, suit: :spades},
        %{rank: :king, suit: :hearts},
        %{rank: 3, suit: :clubs},
        %{rank: 4, suit: :hearts},
        %{rank: 8, suit: :spades},
        %{rank: 9, suit: :spades},
        %{rank: :queen, suit: :spades},
        %{rank: :king, suit: :spades},
        %{rank: 6, suit: :hearts},
        %{rank: 9, suit: :hearts},
        %{rank: 3, suit: :diamonds},
        %{rank: 4, suit: :diamonds},
        %{rank: 8, suit: :clubs}
      ])

      {:ok, state: state}
    end

    test "all players have exactly 6 cards after complete redeal flow", %{state: state} do
      # Execute trump declaration
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # CRITICAL ASSERTION: All players should have exactly 6 cards
      # This test WILL FAIL due to the bug
      Enum.each(state.players, fn {position, player} ->
        assert length(player.hand) == 6,
          """
          Expected #{position} to have 6 cards, but got #{length(player.hand)} cards.
          Hand: #{inspect(player.hand)}

          This indicates the second_deal phase was skipped for non-dealer players.
          """
      end)
    end

    test "phase transitions to :playing after complete redeal flow", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      assert state.phase == :playing,
        "Expected phase to be :playing but got #{state.phase}"
    end

    test "turn is set to player left of dealer after redeal", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # Dealer is east, so next player is south
      assert state.current_turn == :south,
        "Expected turn to be :south (left of dealer :east) but got #{state.current_turn}"
    end

    test "deck is empty after complete redeal flow", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      assert state.deck == [],
        "Expected deck to be empty but got #{length(state.deck)} cards"
    end

    test "events include cards_discarded, second_deal_complete, and dealer_robbed_pack", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # Extract event types
      event_types = Enum.map(state.events, fn
        {type, _} -> type
        {type, _, _} -> type
        {type, _, _, _} -> type
      end)

      # Should have discard events for players who discarded non-trump
      assert Enum.any?(event_types, &(&1 == :cards_discarded)),
        "Expected :cards_discarded events but got: #{inspect(event_types)}"

      # Should have second_deal_complete event
      assert Enum.member?(event_types, :second_deal_complete),
        "Expected :second_deal_complete event but got: #{inspect(event_types)}"

      # Should have dealer_robbed_pack event
      assert Enum.member?(event_types, :dealer_robbed_pack),
        "Expected :dealer_robbed_pack event but got: #{inspect(event_types)}"
    end

    test "non-dealer players receive correct number of cards to reach 6", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # North had 1 trump, should receive 5 cards
      # South had 2 trump, should receive 4 cards
      # West had 3 trump (not 4, since 10♥ is not wrong-5), should receive 3 cards

      # Verify via cards_requested map (if available)
      if Map.has_key?(state, :cards_requested) do
        assert state.cards_requested[:north] == 5,
          "North should have requested 5 cards but got #{state.cards_requested[:north]}"
        assert state.cards_requested[:south] == 4,
          "South should have requested 4 cards but got #{state.cards_requested[:south]}"
      end

      # Verify final hand sizes
      assert length(state.players[:north].hand) == 6
      assert length(state.players[:south].hand) == 6
      assert length(state.players[:west].hand) == 6
      assert length(state.players[:east].hand) == 6
    end

    test "dealer receives best 6 cards from hand + remaining deck", %{state: state} do
      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      dealer = state.players[:east]

      # Dealer should have exactly 6 cards
      assert length(dealer.hand) == 6

      # Verify dealer_pool_size was tracked
      assert Map.has_key?(state, :dealer_pool_size),
        "dealer_pool_size should be tracked"

      # Dealer had 5 trump + remaining deck after non-dealers were dealt
      # Pool size should be recorded in state
      assert state.dealer_pool_size > 6,
        "Dealer pool should have been > 6 cards"
    end
  end

  describe "edge case: player with 6+ trump cards (kill rule)" do
    test "player with 7 trump cards keeps all 7 and triggers kill rule", _context do
      # Create state where one player has 7 trump cards
      state =
        GameState.new()
        |> put_in([Access.key(:config), :auto_dealer_rob], true)
        |> put_in([Access.key(:phase)], :declaring)
        |> put_in([Access.key(:current_dealer)], :east)
        |> put_in([Access.key(:high_bidder)], :east)
        |> put_in([Access.key(:winning_bid)], 6)

      state = put_in(state.players, %{
        north: %Types.Player{
          hand: [
            # 7 trump cards (triggers kill rule)
            %{rank: :ace, suit: :diamonds},
            %{rank: :king, suit: :diamonds},
            %{rank: :queen, suit: :diamonds},
            %{rank: :jack, suit: :diamonds},
            %{rank: 10, suit: :diamonds},
            %{rank: 9, suit: :diamonds},
            %{rank: 8, suit: :diamonds},
            # 2 non-trump
            %{rank: :ace, suit: :clubs},
            %{rank: :king, suit: :clubs}
          ]
        },
        east: %Types.Player{
          hand: [
            %{rank: 5, suit: :diamonds},
            %{rank: 7, suit: :diamonds},
            %{rank: 2, suit: :diamonds},
            %{rank: :ace, suit: :spades},
            %{rank: :king, suit: :spades},
            %{rank: :queen, suit: :spades},
            %{rank: :jack, suit: :spades},
            %{rank: 10, suit: :spades},
            %{rank: 9, suit: :spades}
          ]
        },
        south: %Types.Player{
          hand: [
            %{rank: 6, suit: :diamonds},
            %{rank: 4, suit: :diamonds},
            %{rank: 3, suit: :diamonds},
            %{rank: :ace, suit: :hearts},
            %{rank: :king, suit: :hearts},
            %{rank: :queen, suit: :hearts},
            %{rank: :jack, suit: :hearts},
            %{rank: 10, suit: :hearts},
            %{rank: 9, suit: :hearts}
          ]
        },
        west: %Types.Player{
          hand: [
            %{rank: 5, suit: :hearts},  # wrong-5
            %{rank: 2, suit: :clubs},
            %{rank: 3, suit: :clubs},
            %{rank: 4, suit: :clubs},
            %{rank: 5, suit: :clubs},
            %{rank: 6, suit: :clubs},
            %{rank: 7, suit: :clubs},
            %{rank: 8, suit: :clubs},
            %{rank: 9, suit: :clubs}
          ]
        }
      })

      state = put_in(state.deck, [
        %{rank: 10, suit: :clubs},
        %{rank: :jack, suit: :clubs},
        %{rank: :queen, suit: :clubs},
        %{rank: :king, suit: :clubs},
        %{rank: :ace, suit: :clubs},
        %{rank: 2, suit: :spades},
        %{rank: 3, suit: :spades},
        %{rank: 4, suit: :spades},
        %{rank: 5, suit: :spades},
        %{rank: 6, suit: :spades},
        %{rank: 7, suit: :spades},
        %{rank: 8, suit: :spades},
        %{rank: 6, suit: :hearts},
        %{rank: 7, suit: :hearts},
        %{rank: 8, suit: :hearts},
        %{rank: 2, suit: :hearts}
      ])

      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # North should still have 7 trump cards (no cards dealt, > 6 cards)
      north = state.players[:north]
      assert length(north.hand) == 7,
        "North with 7 trump cards should keep all 7"

      # Other players should have 6 cards
      assert length(state.players[:east].hand) == 6
      assert length(state.players[:south].hand) == 6
      assert length(state.players[:west].hand) == 6

      # Cards requested should show 0 for north
      if Map.has_key?(state, :cards_requested) do
        assert state.cards_requested[:north] == 0,
          "North should have requested 0 cards (already has > 6)"
      end
    end
  end

  describe "edge case: deck empty after discard (rare)" do
    test "transitions directly to playing when no cards to deal or rob", _context do
      # Contrived scenario: all 36 cards dealt, all are trump
      # After discard, deck is empty and all players have exactly 6 cards
      state =
        GameState.new()
        |> put_in([Access.key(:config), :auto_dealer_rob], true)
        |> put_in([Access.key(:phase)], :declaring)
        |> put_in([Access.key(:current_dealer)], :east)
        |> put_in([Access.key(:high_bidder)], :east)
        |> put_in([Access.key(:winning_bid)], 6)

      # Give each player exactly 6 trump cards (contrived, but possible)
      # Deck will be empty after initial deal
      state = put_in(state.players, %{
        north: %Types.Player{
          hand: [
            %{rank: :ace, suit: :diamonds},
            %{rank: :king, suit: :diamonds},
            %{rank: :queen, suit: :diamonds},
            %{rank: :jack, suit: :diamonds},
            %{rank: 10, suit: :diamonds},
            %{rank: 9, suit: :diamonds},
            # 3 non-trump (will be discarded)
            %{rank: :ace, suit: :spades},
            %{rank: :king, suit: :spades},
            %{rank: :queen, suit: :spades}
          ]
        },
        east: %Types.Player{
          hand: [
            %{rank: 8, suit: :diamonds},
            %{rank: 7, suit: :diamonds},
            %{rank: 6, suit: :diamonds},
            %{rank: 5, suit: :diamonds},
            %{rank: 4, suit: :diamonds},
            %{rank: 3, suit: :diamonds},
            %{rank: :jack, suit: :spades},
            %{rank: 10, suit: :spades},
            %{rank: 9, suit: :spades}
          ]
        },
        south: %Types.Player{
          hand: [
            %{rank: 2, suit: :diamonds},
            %{rank: :ace, suit: :hearts},
            %{rank: :king, suit: :hearts},
            %{rank: :queen, suit: :hearts},
            %{rank: :jack, suit: :hearts},
            %{rank: 10, suit: :hearts},
            %{rank: 8, suit: :spades},
            %{rank: 7, suit: :spades},
            %{rank: 6, suit: :spades}
          ]
        },
        west: %Types.Player{
          hand: [
            %{rank: 5, suit: :hearts},  # wrong-5
            %{rank: 9, suit: :hearts},
            %{rank: 8, suit: :hearts},
            %{rank: 7, suit: :hearts},
            %{rank: 6, suit: :hearts},
            %{rank: 4, suit: :hearts},
            %{rank: 5, suit: :spades},
            %{rank: 4, suit: :spades},
            %{rank: 3, suit: :spades}
          ]
        }
      })

      # Empty deck (all 36 cards dealt)
      state = put_in(state.deck, [])

      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # All players should have exactly 6 cards (their trump cards, no dealing)
      assert length(state.players[:north].hand) == 6
      assert length(state.players[:east].hand) == 6
      assert length(state.players[:south].hand) == 6
      assert length(state.players[:west].hand) == 6

      # Should transition to :playing (no rob needed since deck empty)
      assert state.phase == :playing

      # Deck should still be empty
      assert state.deck == []
    end
  end

  describe "manual mode: auto_dealer_rob: false" do
    test "waits for dealer to manually rob the pack", _context do
      state =
        GameState.new()
        |> put_in([Access.key(:config), :auto_dealer_rob], false)  # Manual mode
        |> put_in([Access.key(:phase)], :declaring)
        |> put_in([Access.key(:current_dealer)], :east)
        |> put_in([Access.key(:high_bidder)], :east)
        |> put_in([Access.key(:winning_bid)], 6)

      state = put_in(state.players, %{
        north: %Types.Player{
          hand: [
            %{rank: :ace, suit: :diamonds},
            %{rank: 7, suit: :spades},
            %{rank: :ace, suit: :clubs},
            %{rank: 5, suit: :clubs},
            %{rank: 2, suit: :spades},
            %{rank: 10, suit: :spades},
            %{rank: 6, suit: :hearts},
            %{rank: :king, suit: :clubs},
            %{rank: 10, suit: :clubs}
          ]
        },
        east: %Types.Player{
          hand: [
            %{rank: 5, suit: :diamonds},
            %{rank: 7, suit: :diamonds},
            %{rank: :ace, suit: :hearts},
            %{rank: 7, suit: :hearts},
            %{rank: 2, suit: :clubs},
            %{rank: 6, suit: :clubs},
            %{rank: 5, suit: :hearts},
            %{rank: :jack, suit: :spades},
            %{rank: 9, suit: :clubs}
          ]
        },
        south: %Types.Player{
          hand: [
            %{rank: 10, suit: :diamonds},
            %{rank: :queen, suit: :diamonds},
            %{rank: 3, suit: :spades},
            %{rank: 3, suit: :hearts},
            %{rank: 2, suit: :hearts},
            %{rank: 4, suit: :clubs},
            %{rank: 6, suit: :spades},
            %{rank: :queen, suit: :hearts},
            %{rank: 4, suit: :spades}
          ]
        },
        west: %Types.Player{
          hand: [
            %{rank: 6, suit: :diamonds},
            %{rank: 8, suit: :diamonds},
            %{rank: 9, suit: :diamonds},
            %{rank: 10, suit: :hearts},
            %{rank: :king, suit: :spades},
            %{rank: :ace, suit: :spades},
            %{rank: :jack, suit: :clubs},
            %{rank: 7, suit: :clubs},
            %{rank: 8, suit: :hearts}
          ]
        }
      })

      state = put_in(state.deck, [
        %{rank: :jack, suit: :diamonds},
        %{rank: 5, suit: :hearts},
        %{rank: 2, suit: :diamonds},
        %{rank: :jack, suit: :spades},
        %{rank: :king, suit: :hearts},
        %{rank: 3, suit: :clubs},
        %{rank: 4, suit: :hearts},
        %{rank: 8, suit: :spades},
        %{rank: 9, suit: :spades},
        %{rank: :queen, suit: :spades},
        %{rank: :king, suit: :spades},
        %{rank: 6, suit: :hearts},
        %{rank: 9, suit: :hearts},
        %{rank: 3, suit: :diamonds},
        %{rank: 4, suit: :diamonds},
        %{rank: 8, suit: :clubs}
      ])

      {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

      # Non-dealer players should have 6 cards
      assert length(state.players[:north].hand) == 6
      assert length(state.players[:south].hand) == 6
      assert length(state.players[:west].hand) == 6

      # Should still be in :second_deal phase (waiting for dealer action)
      assert state.phase == :second_deal,
        "Should remain in :second_deal phase waiting for manual dealer rob"

      # Turn should be set to dealer
      assert state.current_turn == :east,
        "Turn should be set to dealer in manual mode"

      # Dealer should NOT have 6 cards yet (hasn't robbed)
      # Dealer should have their trump cards + deck available for robbing
      dealer = state.players[:east]
      assert length(dealer.hand) < 6,
        "Dealer should not have 6 cards yet (must manually rob)"
    end
  end
end
```

#### 2. Add Property Tests for Redeal Flow

**File**: `test/properties/redeal_properties_test.exs`
**Changes**: Add new property test to existing file

```elixir
# Add to existing file around line 176

property "auto dealer rob: all players end with exactly 6 cards" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    # Generate random hand sizes for each player (1-9 cards)
    north_trump_count <- integer(1..9),
    east_trump_count <- integer(1..9),
    south_trump_count <- integer(1..9),
    west_trump_count <- integer(1..9),
    max_runs: 100
  ) do
    # Create state with auto_dealer_rob enabled
    state =
      GameState.new()
      |> put_in([Access.key(:config), :auto_dealer_rob], true)
      |> put_in([Access.key(:phase)], :declaring)
      |> put_in([Access.key(:current_dealer)], :east)
      |> put_in([Access.key(:high_bidder)], :east)
      |> put_in([Access.key(:winning_bid)], 6)
      |> put_in([Access.key(:trump_suit)], trump_suit)

    # Generate hands with specific trump counts
    # (Use test helper to generate realistic hands)
    state = setup_players_with_trump_counts(state, %{
      north: north_trump_count,
      east: east_trump_count,
      south: south_trump_count,
      west: west_trump_count
    })

    # Execute trump declaration
    {:ok, final_state} = Engine.apply_action(state, :east, {:declare_trump, trump_suit})

    # PROPERTY: All players must have exactly 6 cards (or > 6 if kill rule applies)
    Enum.each(final_state.players, fn {position, player} ->
      hand_size = length(player.hand)

      assert hand_size >= 6,
        """
        Player #{position} has #{hand_size} cards, which is less than 6.
        This violates the game rules after redeal.
        Initial trump count: #{Map.get(%{north: north_trump_count, east: east_trump_count, south: south_trump_count, west: west_trump_count}, position)}
        """

      # If hand_size > 6, it should match the original trump count (kill rule)
      if hand_size > 6 do
        original_trump_count = Map.get(%{
          north: north_trump_count,
          east: east_trump_count,
          south: south_trump_count,
          west: west_trump_count
        }, position)

        assert hand_size == original_trump_count,
          "Player with > 6 cards should have their original trump count (kill rule)"
      end
    end)

    # PROPERTY: Phase must be :playing
    assert final_state.phase == :playing,
      "Phase should be :playing after complete redeal flow"

    # PROPERTY: Deck must be empty
    assert final_state.deck == [],
      "Deck should be empty after dealer robs the pack"

    # PROPERTY: Turn should be player left of dealer
    assert final_state.current_turn == Types.next_position(final_state.current_dealer),
      "Turn should be set to player left of dealer"
  end
end
```

### Success Criteria

#### Automated Verification:

- [ ] All new tests FAIL with clear error messages: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [ ] Main integration test fails with: "Expected north to have 6 cards, but got X cards"
- [ ] Edge case tests fail appropriately
- [ ] Property test fails showing the invariant violation

#### Manual Verification:

- [ ] Read test output and confirm it clearly shows the bug
- [ ] Verify test setup creates realistic game scenarios
- [ ] Confirm error messages are helpful for debugging

---

## Phase 2: Fix the Primary Bug

### Overview

Refactor `handle_automatic_phase(:second_deal)` to ALWAYS call `second_deal/1` first, then conditionally handle dealer rob based on auto mode setting.

### Changes Required

#### 1. Refactor Automatic Phase Handler

**File**: `lib/pidro/game/engine.ex:535-571`
**Changes**: Replace entire function with corrected logic

**OLD CODE** (BROKEN):
```elixir
defp handle_automatic_phase(%Types.GameState{phase: :second_deal} = state) do
  # Dealer ALWAYS robs when deck has cards (per specs/redeal.md)
  # Dealer combines hand + remaining deck, then selects best 6
  deck_size = length(state.deck)
  auto_rob = Map.get(state.config, :auto_dealer_rob, false)

  if deck_size > 0 do
    if auto_rob do
      # Auto-select best 6 cards for dealer
      dealer = state.current_dealer
      dealer_player = Map.get(state.players, dealer)
      pool = dealer_player.hand ++ state.deck
      selected_cards = DealerRob.select_best_cards(pool, state.trump_suit)

      case Discard.dealer_rob_pack(state, selected_cards) do
        {:ok, new_state} ->
          maybe_auto_transition(new_state)

        error ->
          error
      end
    else
      # Manual mode: Dealer must rob the pack, set turn to dealer and wait for action
      {:ok, GameState.update(state, :current_turn, state.current_dealer)}
    end
  else
    # No cards to rob, proceed automatically with second deal
    case Discard.second_deal(state) do
      {:ok, new_state} ->
        # After second deal, auto-transition to playing
        maybe_auto_transition(new_state)

      error ->
        error
    end
  end
end
```

**NEW CODE** (FIXED):
```elixir
defp handle_automatic_phase(%Types.GameState{phase: :second_deal} = state) do
  # STEP 1: Always run second_deal to distribute cards to non-dealers
  # This function deals cards to all non-dealer players to reach exactly 6 cards,
  # then determines if the dealer needs to rob the pack based on remaining deck.
  case Discard.second_deal(state) do
    {:ok, new_state} ->
      # STEP 2: Check if dealer needs to rob the pack
      # second_deal/1 returns phase: :second_deal if dealer needs to rob (deck has cards)
      # or phase: :playing if dealer doesn't need to rob (deck empty or dealer has 6 cards)

      if new_state.phase == :second_deal do
        # Dealer needs to rob - check if auto mode is enabled
        auto_rob = Map.get(state.config, :auto_dealer_rob, false)

        if auto_rob do
          # Auto mode: automatically select best 6 cards for dealer
          dealer = new_state.current_dealer
          dealer_player = Map.get(new_state.players, dealer)
          pool = dealer_player.hand ++ new_state.deck
          selected_cards = DealerRob.select_best_cards(pool, new_state.trump_suit)

          case Discard.dealer_rob_pack(new_state, selected_cards) do
            {:ok, final_state} ->
              maybe_auto_transition(final_state)

            error ->
              error
          end
        else
          # Manual mode: second_deal already set turn to dealer, just return state
          # Dealer will manually select cards via dealer_rob action
          {:ok, new_state}
        end
      else
        # second_deal already transitioned to :playing phase (no rob needed)
        # This happens when deck is empty or dealer already has 6 cards
        maybe_auto_transition(new_state)
      end

    error ->
      error
  end
end
```

**Key Changes**:
1. **Line 1**: Removed `deck_size` check - `second_deal/1` handles all cases
2. **Line 4**: ALWAYS call `second_deal/1` first (this is the critical fix)
3. **Line 9-10**: Check resulting phase to determine if dealer needs to rob
4. **Line 11**: Only check auto_rob config if dealer needs to rob
5. **Line 13-24**: Auto-select and call `dealer_rob_pack` if auto mode enabled
6. **Line 26-28**: Manual mode just returns state (turn already set to dealer)
7. **Line 30-32**: If phase is already :playing, just auto-transition

### Success Criteria

#### Automated Verification:

- [ ] All integration tests pass: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [ ] All existing unit tests still pass: `mix test test/unit/game/discard_dealer_rob_test.exs`
- [ ] Property tests pass: `mix test test/properties/redeal_properties_test.exs`
- [ ] Property tests pass: `mix test test/properties/dealer_rob_properties_test.exs`
- [ ] No regressions in full test suite: `mix test`

#### Manual Verification:

- [ ] Run IEx test scenario from BUG_PROMPT.md and verify all players have 6 cards
- [ ] Verify events log shows all expected events
- [ ] Test with different trump suits and hand distributions

---

## Phase 3: Investigate Secondary Bug (Discard Phase)

### Overview

Investigate why the BUG_PROMPT.md output showed players still having non-trump cards after the discard phase. Determine if this is a real bug or a display/timing issue in IEx helpers.

### Changes Required

#### 1. Add Debug Test for Discard Phase

**File**: `test/integration/auto_dealer_rob_integration_test.exs`
**Changes**: Add test to verify discard phase works correctly

```elixir
describe "discard phase investigation" do
  test "all players discard non-trump cards during discard phase", %{state: state} do
    # Execute trump declaration (should trigger automatic discard)
    {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

    # Verify ALL players have ONLY trump cards
    # (Before second_deal, after discard_non_trumps)
    # This test will help us determine if discard phase is working

    # Extract all cards from all players
    all_player_cards =
      Enum.flat_map(state.players, fn {_position, player} ->
        player.hand
      end)

    # Check if any non-trump cards remain
    trump_suit = state.trump_suit
    wrong_5_suit = Trump.wrong_5_suit(trump_suit)

    non_trump_cards =
      Enum.filter(all_player_cards, fn card ->
        # Card is non-trump if:
        # - Not in trump suit
        # - Not the wrong-5 (5 of same-color suit)
        card.suit != trump_suit and not (card.rank == 5 and card.suit == wrong_5_suit)
      end)

    assert non_trump_cards == [],
      """
      Found non-trump cards after discard phase: #{inspect(non_trump_cards)}

      This indicates discard_non_trumps may not be running properly.
      Trump suit: #{trump_suit}
      Wrong-5 suit: #{wrong_5_suit}
      """
  end

  test "cards_discarded events are emitted for all players who discarded", %{state: state} do
    {:ok, state} = Engine.apply_action(state, :east, {:declare_trump, :diamonds})

    # Extract discard events
    discard_events =
      Enum.filter(state.events, fn
        {:cards_discarded, _position, _cards} -> true
        _ -> false
      end)

    # Should have discard events for players who had non-trump cards
    # North had 8 non-trump, East had 4 non-trump, South had 7 non-trump, West had 5 non-trump
    # So we should have 4 discard events (one per player)
    assert length(discard_events) > 0,
      "Expected cards_discarded events but got none"

    # Verify each event has the right structure
    Enum.each(discard_events, fn {:cards_discarded, position, cards} ->
      assert is_atom(position), "Position should be an atom"
      assert is_list(cards), "Cards should be a list"
      assert length(cards) > 0, "Should have discarded at least 1 card"
    end)
  end
end
```

#### 2. Review IEx Helper Display Logic

**File**: `lib/pidro/iex.ex`
**Changes**: Read and analyze the `view/1` and `pretty_print/1` functions

```bash
# Manual review task - no code changes yet
# Check if view/1 or pretty_print/1 shows stale data
# Look for any caching or timing issues
# Verify events are displayed correctly
```

#### 3. Add Debugging to Discard Function (Temporary)

**File**: `lib/pidro/game/discard.ex`
**Changes**: Add temporary IO.inspect calls to verify function is called

```elixir
def discard_non_trumps(%Types.GameState{} = state) do
  # TEMPORARY DEBUG - Remove after investigation
  IO.puts("DEBUG: discard_non_trumps called")
  IO.inspect(state.phase, label: "DEBUG: Current phase")
  IO.inspect(state.trump_suit, label: "DEBUG: Trump suit")

  with :ok <- validate_discarding_phase(state),
       :ok <- validate_trump_declared(state) do
    # ... rest of function

    # TEMPORARY DEBUG - Remove after investigation
    IO.inspect(length(all_discarded_cards), label: "DEBUG: Total cards discarded")
    IO.inspect(events, label: "DEBUG: Discard events")

    # ... rest of function
  end
end
```

### Success Criteria

#### Automated Verification:

- [ ] New discard investigation tests pass: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [ ] All players have only trump cards after discard phase
- [ ] Discard events are properly recorded

#### Manual Verification:

- [ ] Run IEx scenario and check console for DEBUG output
- [ ] Verify `discard_non_trumps` is actually being called
- [ ] Check if timing/display issue in IEx or real bug
- [ ] Review event log to confirm discard events are present

---

## Phase 4: Fix Secondary Bug (If Found)

### Overview

If Phase 3 investigation reveals a real bug in the discard phase (not just a display issue), fix it here.

**NOTE**: This phase may be skipped if investigation shows no real bug.

### Changes Required

#### Conditional: Fix Discard Bug (If Real)

**File**: TBD - depends on investigation
**Changes**: TBD - depends on root cause

Possible scenarios:
1. **Discard not being called**: Fix `handle_automatic_phase(:discarding)` logic
2. **Discard not updating state**: Fix state update in `discard_non_trumps/1`
3. **Wrong-5 logic error**: Fix trump categorization in `Trump.categorize_hand/2`
4. **Display bug only**: Update IEx helpers, no core logic changes needed

### Success Criteria

#### Automated Verification:

- [ ] All tests pass: `mix test`
- [ ] Integration tests verify discard works: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [ ] No non-trump cards remain after discard phase

#### Manual Verification:

- [ ] Run IEx scenario and verify players have only trump after discard
- [ ] Check event log shows discard events
- [ ] Verify cards are actually removed from hands

---

## Phase 5: Add Property Tests for Regression Prevention

### Overview

Add comprehensive property tests to prevent this class of bug from recurring. These tests should verify the invariants that MUST hold after the complete redeal flow.

### Changes Required

#### 1. Add Redeal Invariants Property Tests

**File**: `test/properties/redeal_properties_test.exs`
**Changes**: Add property tests at end of file

```elixir
# Add after existing property tests

property "INVARIANT: after complete redeal, all players have 6+ cards" do
  check all(
    # Generate random trump suit
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    # Generate random auto_rob setting
    auto_rob <- boolean(),
    # Generate random dealer position
    dealer <- member_of([:north, :east, :south, :west]),
    max_runs: 200
  ) do
    # Create realistic game state in declaring phase
    state = create_realistic_declaring_state(trump_suit, dealer, auto_rob)

    # Execute trump declaration (triggers full redeal flow)
    {:ok, final_state} = Engine.apply_action(state, dealer, {:declare_trump, trump_suit})

    # INVARIANT 1: All players have at least 6 cards
    Enum.each(final_state.players, fn {position, player} ->
      assert length(player.hand) >= 6,
        "Player #{position} has #{length(player.hand)} cards (expected >= 6)"
    end)

    # INVARIANT 2: If player has > 6 cards, it's due to kill rule (had > 6 trump)
    # (This is implicitly verified by second_deal logic - players with 6+ trump keep all)

    # INVARIANT 3: Phase is :playing
    assert final_state.phase == :playing,
      "Phase should be :playing but is #{final_state.phase}"

    # INVARIANT 4: Deck is empty (all cards distributed)
    assert final_state.deck == [],
      "Deck should be empty but has #{length(final_state.deck)} cards"

    # INVARIANT 5: Turn is set to player left of dealer
    expected_turn = Types.next_position(final_state.current_dealer)
    assert final_state.current_turn == expected_turn,
      "Turn should be #{expected_turn} but is #{final_state.current_turn}"

    # INVARIANT 6: Events include second_deal_complete and dealer_robbed_pack
    event_types = extract_event_types(final_state.events)
    assert :second_deal_complete in event_types,
      "Missing :second_deal_complete event"

    # Only expect dealer_robbed_pack if there were cards to rob
    # (If all players had exactly 6 trump and deck was empty, no rob occurs)
  end
end

property "INVARIANT: cards_requested map tracks correct counts" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    max_runs: 100
  ) do
    # Create state with known trump counts
    state = create_state_with_known_trump_counts(trump_suit, %{
      north: 2,  # Should request 4 cards
      east: 5,   # Dealer - gets rob, not dealt
      south: 1,  # Should request 5 cards
      west: 4    # Should request 2 cards
    })

    {:ok, final_state} = Engine.apply_action(state, :east, {:declare_trump, trump_suit})

    # Verify cards_requested map
    assert final_state.cards_requested[:north] == 4
    assert final_state.cards_requested[:south] == 5
    assert final_state.cards_requested[:west] == 2
    # Dealer (east) should not be in cards_requested (they rob instead)
    assert final_state.cards_requested[:east] == 0 or
           not Map.has_key?(final_state.cards_requested, :east)
  end
end

property "INVARIANT: auto vs manual mode both result in same final state (except dealer hand)" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    seed <- integer(1..10000),
    max_runs: 50
  ) do
    # Create identical states except for auto_rob config
    state_auto = create_seeded_state(trump_suit, :east, true, seed)
    state_manual = create_seeded_state(trump_suit, :east, false, seed)

    # Run auto mode to completion
    {:ok, final_auto} = Engine.apply_action(state_auto, :east, {:declare_trump, trump_suit})

    # Run manual mode through second_deal
    {:ok, after_second_deal} = Engine.apply_action(state_manual, :east, {:declare_trump, trump_suit})

    # Manual mode should stop in :second_deal phase waiting for dealer
    assert after_second_deal.phase == :second_deal

    # Non-dealer players should have same hands in both modes
    assert after_second_deal.players[:north].hand == final_auto.players[:north].hand
    assert after_second_deal.players[:south].hand == final_auto.players[:south].hand
    assert after_second_deal.players[:west].hand == final_auto.players[:west].hand

    # Dealer hands will differ (auto selects best, manual hasn't selected yet)
    # But dealer should have access to same pool
    dealer_pool_manual = after_second_deal.players[:east].hand ++ after_second_deal.deck
    dealer_hand_auto = final_auto.players[:east].hand

    # All cards in auto dealer's hand should be from the manual pool
    assert Enum.all?(dealer_hand_auto, fn card -> card in dealer_pool_manual end)
  end
end

# Helper functions for property tests

defp create_realistic_declaring_state(trump_suit, dealer, auto_rob) do
  # Create state with random but realistic hands
  # Each player has 9 cards with varying trump counts
  # Deck has remaining 16 cards
  # TODO: Implement realistic state generator
end

defp create_state_with_known_trump_counts(trump_suit, trump_counts) do
  # Create state where each player has specific number of trump cards
  # Used for deterministic testing of cards_requested
  # TODO: Implement
end

defp create_seeded_state(trump_suit, dealer, auto_rob, seed) do
  # Create state with seeded randomness for reproducibility
  # Used to compare auto vs manual modes with identical initial state
  # TODO: Implement
end

defp extract_event_types(events) do
  Enum.map(events, fn
    {type, _} -> type
    {type, _, _} -> type
    {type, _, _, _} -> type
  end)
end
```

### Success Criteria

#### Automated Verification:

- [ ] All property tests pass: `mix test test/properties/redeal_properties_test.exs`
- [ ] Property tests run 200+ times with varied inputs
- [ ] No invariant violations found

#### Manual Verification:

- [ ] Review property test output for edge cases
- [ ] Verify property tests catch the original bug if code is reverted
- [ ] Confirm tests are deterministic and repeatable

---

## Phase 6: Clean Up and Documentation

### Overview

Remove debug code, update comments, and document the fix for future maintainers.

### Changes Required

#### 1. Remove Debug Output

**File**: `lib/pidro/game/discard.ex`
**Changes**: Remove all temporary IO.inspect and IO.puts calls added in Phase 3

```elixir
def discard_non_trumps(%Types.GameState{} = state) do
  # Remove all DEBUG lines
  with :ok <- validate_discarding_phase(state),
       :ok <- validate_trump_declared(state) do
    # ... existing logic (no debug output)
  end
end
```

#### 2. Update Engine Comments

**File**: `lib/pidro/game/engine.ex`
**Changes**: Update comments to explain the fix

```elixir
defp handle_automatic_phase(%Types.GameState{phase: :second_deal} = state) do
  # CRITICAL: Must ALWAYS call second_deal/1 first to distribute cards to non-dealers
  #
  # Historical bug: Previously, when auto_dealer_rob: true, code jumped directly
  # to dealer_rob_pack/2, which only updates the dealer's hand. This left non-dealer
  # players with their post-discard trump-only hands (0-9 cards instead of 6).
  #
  # Fix: Always call second_deal/1 first. It handles:
  # 1. Dealing cards to non-dealers to reach 6 cards each
  # 2. Determining if dealer needs to rob (checks remaining deck)
  # 3. Staying in :second_deal phase if rob needed, or transitioning to :playing if not
  #
  # Then, based on the resulting phase and auto_rob config, either:
  # - Auto-select best cards for dealer (auto mode)
  # - Wait for dealer to manually select (manual mode)
  # - Transition to playing (if no rob needed)

  case Discard.second_deal(state) do
    # ... existing logic
  end
end
```

#### 3. Add Test Documentation

**File**: `test/integration/auto_dealer_rob_integration_test.exs`
**Changes**: Add module documentation

```elixir
defmodule Pidro.Integration.AutoDealerRobIntegrationTest do
  @moduledoc """
  Integration tests for the complete redeal flow with auto_dealer_rob mode.

  These tests verify the end-to-end flow from trump declaration through
  automatic discard, second deal, and dealer rob phases.

  ## Historical Context

  These tests were added to prevent regression of a critical bug where
  non-dealer players never received replacement cards during second deal
  when auto_dealer_rob: true. The bug occurred because the automatic phase
  handler bypassed second_deal/1 and jumped directly to dealer_rob_pack/2.

  ## What These Tests Verify

  1. All players end with exactly 6 cards (or > 6 if kill rule applies)
  2. Phase transitions to :playing after complete flow
  3. Turn is set correctly to player left of dealer
  4. Deck is empty after dealer robs
  5. All events are recorded properly
  6. Edge cases: kill rule, empty deck, manual mode

  ## References

  - Bug Report: `BUG_PROMPT-research.md`
  - Fix: `lib/pidro/game/engine.ex:535-571` refactored to always call second_deal first
  - Date: 2025-11-02
  """

  # ... existing tests
end
```

#### 4. Update Changelog/Commit Message

**Changes**: Document the fix in commit message

```
Fix critical bug: non-dealers not receiving cards in auto dealer rob mode

PROBLEM:
When auto_dealer_rob: true (default setting), non-dealer players never
received replacement cards during the second deal phase. Only the dealer
ended up with 6 cards, while other players retained their post-discard
trump-only hands (0-9 cards). This made the game unplayable.

ROOT CAUSE:
The automatic phase handler in lib/pidro/game/engine.ex:541-555 checked
if deck_size > 0 and auto_rob: true, then jumped directly to
dealer_rob_pack/2, completely bypassing second_deal/1. The second_deal
function is the ONLY place where non-dealer players receive cards.

FIX:
Refactored handle_automatic_phase(:second_deal) to ALWAYS call
second_deal/1 first, which:
1. Deals cards to all non-dealer players to reach 6 cards
2. Determines if dealer needs to rob based on remaining deck
3. Returns appropriate phase (:second_deal if rob needed, :playing if not)

Then, based on the resulting phase and config:
- Auto mode: automatically selects best 6 cards for dealer
- Manual mode: waits for dealer to manually select cards
- No rob needed: transitions to playing phase

TESTING:
- Added comprehensive integration tests covering all scenarios
- Added property tests to verify invariants hold for all inputs
- All 541 existing tests still pass (no regressions)

Files Changed:
- lib/pidro/game/engine.ex (primary fix)
- test/integration/auto_dealer_rob_integration_test.exs (new)
- test/properties/redeal_properties_test.exs (added properties)
```

### Success Criteria

#### Automated Verification:

- [ ] All tests pass: `mix test`
- [ ] No debug output in console
- [ ] Code compiles without warnings: `mix compile --warnings-as-errors`
- [ ] Dialyzer passes (if configured): `mix dialyzer`

#### Manual Verification:

- [ ] Comments are clear and helpful
- [ ] Documentation explains the historical context
- [ ] Commit message follows project conventions
- [ ] Code review would approve these changes

---

## Testing Strategy

### Unit Tests (Existing - Should Continue to Pass)

- `test/unit/game/discard_dealer_rob_test.exs` - Tests dealer_rob_pack/2 in isolation
- `test/unit/game/dealer_rob_test.exs` - Tests DealerRob.select_best_cards/2

### Integration Tests (New - Written in Phase 1)

- Complete redeal flow with auto_dealer_rob: true
- Edge case: player with 7+ trump (kill rule)
- Edge case: empty deck (no rob needed)
- Manual mode: auto_dealer_rob: false
- Discard phase verification

### Property Tests (New + Enhanced)

- All players end with 6+ cards (invariant)
- Cards requested tracking (invariant)
- Auto vs manual mode equivalence (except dealer hand)
- Redeal invariants hold for all random inputs

### Manual Testing Steps (IEx Verification)

1. Start IEx session:
   ```bash
   iex -S mix
   ```

2. Create game with auto mode (default):
   ```elixir
   alias Pidro.IEx
   state = IEx.new_game()
   state.config.auto_dealer_rob  # Should be true
   ```

3. Play through to trump declaration:
   ```elixir
   # Pass for all non-dealers
   {:ok, state} = IEx.step(state, :south, :pass)
   {:ok, state} = IEx.step(state, :west, :pass)
   {:ok, state} = IEx.step(state, :north, :pass)

   # Dealer bids
   {:ok, state} = IEx.step(state, :east, {:bid, 6})

   # Declare trump
   {:ok, state} = IEx.step(state, :east, {:declare_trump, :diamonds})
   ```

4. Verify all players have 6 cards:
   ```elixir
   IEx.view(state)

   # Check each player
   state.players[:north].hand |> length()  # Should be 6
   state.players[:east].hand |> length()   # Should be 6
   state.players[:south].hand |> length()  # Should be 6
   state.players[:west].hand |> length()   # Should be 6
   ```

5. Verify phase and turn:
   ```elixir
   state.phase         # Should be :playing
   state.current_turn  # Should be :south (left of dealer :east)
   state.deck          # Should be []
   ```

6. Check events:
   ```elixir
   state.events
   # Should include:
   # - {:cards_discarded, ...} events
   # - {:second_deal_complete, ...}
   # - {:dealer_robbed_pack, ...}
   ```

7. Test manual mode:
   ```elixir
   state = IEx.new_game(auto_dealer_rob: false)
   # ... repeat steps 3-4 ...

   # Should stop in :second_deal phase
   state.phase         # Should be :second_deal
   state.current_turn  # Should be dealer position

   # Non-dealers should have 6 cards
   state.players[:north].hand |> length()  # Should be 6
   # Dealer should have < 6 cards (hasn't robbed yet)
   state.players[:east].hand |> length()   # Should be < 6
   ```

## Performance Considerations

**No performance impact expected**. The fix changes the order of operations but does not add any new computational work:

- `second_deal/1` was already being called in the `deck_size == 0` branch
- We're just calling it earlier and in all cases
- Same number of iterations, same card operations
- Dealer rob logic unchanged

## Migration Notes

**No migration required**. This is a pure bug fix with no data model changes:

- No database schema changes
- No config changes required
- No API changes
- Existing games in progress will work correctly after fix

## References

- Original bug report: `BUG_PROMPT.md`
- Research document: `BUG_PROMPT-research.md`
- Specification: `specs/redeal.md`
- Auto dealer rob feature doc: `AUTO_DEALER_ROB.md`
- Related code:
  - `lib/pidro/game/engine.ex:535-571` (primary fix)
  - `lib/pidro/game/discard.ex:240-307` (second_deal/1)
  - `lib/pidro/game/discard.ex:356-401` (dealer_rob_pack/2)
  - `lib/pidro/game/dealer_rob.ex:74-80` (select_best_cards/2)
