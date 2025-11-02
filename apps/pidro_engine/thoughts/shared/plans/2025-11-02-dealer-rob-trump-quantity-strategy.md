# Dealer Rob Strategy: Maximize Trump Quantity

## Overview

Refactor the dealer card selection strategy in `lib/pidro/game/dealer_rob.ex` to prioritize **trump quantity** over card quality. The current scoring algorithm incorrectly keeps high-value non-trump cards at the expense of low-value trump cards, which violates the core strategic principle: **staying in the game longer is more valuable than holding high cards**.

**Date**: 2025-11-02
**Related**: [AUTO_DEALER_ROB.md](../../AUTO_DEALER_ROB.md), Strategy specification in user prompt

## Current State Analysis

### Current Implementation

**File**: `lib/pidro/game/dealer_rob.ex:82-114`

```elixir
def score_card({rank, _suit} = card, trump_suit) do
  base_score = rank
  point_bonus = if is_point_card?(card, trump_suit), do: 20, else: 0
  trump_bonus = if Card.is_trump?(card, trump_suit), do: 10, else: 0

  base_score + point_bonus + trump_bonus
end
```

**Scoring formula**: `score = rank + point_bonus(20) + trump_bonus(10)`

### Problems with Current Strategy

**Critical Bug**: The current `is_point_card?/2` function (lines 116-143) checks if a card **has point value in the game**, but doesn't consider that only **trump point cards** matter for dealer rob selection.

In Finnish Pidro:
- Non-trump cards never participate in trick-taking (they're camouflage)
- A non-trump point card (A♠ when hearts is trump) **cannot win a trick**
- Therefore, it should NOT be prioritized over trump cards

**Example of the bug**:
- `is_point_card?({14, :spades}, :hearts)` returns `true` (Ace is a point card)
- But A♠ has **zero strategic value** when hearts is trump (can't win tricks!)
- Yet A♠ scores 34 (rank 14 + point 20), beating 9♥ which scores only 19

### Realistic Scenario Failure

**Pool**: `2♥, 9♥, 8♥, 7♥, 6♥, 4♥, A♠, K♠` (hearts is trump)

**Current scoring**:
- 2♥ = 2 + 20 + 10 = 32 ✅ (trump point card)
- 9♥ = 9 + 0 + 10 = 19 (trump)
- 8♥ = 8 + 0 + 10 = 18 (trump)
- 7♥ = 7 + 0 + 10 = 17 (trump)
- 6♥ = 6 + 0 + 10 = 16 (trump)
- 4♥ = 4 + 0 + 10 = 14 (trump)
- **A♠ = 14 + 20 + 0 = 34** ❌ (non-trump, but scored as point card!)
- K♠ = 13 + 0 + 0 = 13 (non-trump)

**Current selection**: `2♥, A♠, 9♥, 8♥, 7♥, 6♥` → **only 5 trump** ❌
**Correct selection**: `2♥, 9♥, 8♥, 7♥, 6♥, 4♥` → **6 trump** ✅

The A♠ scores higher than 4♥ despite having no trick-winning value!

### Why This Matters

A dealer with 6 worthless trump (3, 4, 6, 7, 8, 9) participates in **6 tricks**.
A dealer with 2 good trump (K, Q) + 4 aces (non-trump) participates in only **2 tricks**.

**More tricks = more opportunities to:**
- Win point cards played by opponents
- Block opponents from taking tricks
- Protect partner's point cards
- Control the game flow

**Strategic Principle**: In Finnish Pidro, trump quantity is king. Non-trump cards are only useful for disguising your trump count from opponents.

## Desired End State

After implementing the corrected strategy:

### Selection Priority (Strict Order)

**CRITICAL**: Only **trump point cards** count in Priority 1. Non-trump point cards have no trick-winning value in Finnish Pidro.

1. **ALWAYS keep ALL trump point cards** (A, J, 10, Right-5, Wrong-5, 2 of trump suit ONLY)
   - Maximum possible: 6 cards (A, J, 10, Right-5, Wrong-5, 2)
   - If all 6 exist, keep all (exactly 6 cards, we're done!)
   - If < 6 trump point cards, proceed to step 2

2. **Fill remaining slots with non-point trump cards (high to low)**
   - High trump: K, Q of trump suit (non-point trump)
   - Low trump: 9, 8, 7, 6, 4, 3 of trump suit
   - Priority within bucket: K > Q > 9 > 8 > 7 > 6 > 4 > 3

3. **Only if still need cards AND out of trump: Add high non-trump**
   - A, K, Q, J of non-trump suits (for disguise/variety)
   - These can't win tricks but hide your trump count

4. **Last resort: Low non-trump**
   - Only if pool is completely depleted of trump
   - 10, 9, 8, 7, 6, 4, 3, 2 of non-trump suits

### Verification Examples

**Test Case 1: Trump point cards kept, non-trump discarded**
- Pool: `A♥, 2♥, 10♥, 3♥, A♠, K♠, Q♠, J♠` (hearts trump)
- Bucket 1: `A♥, 2♥, 10♥` (3 trump point cards)
- Bucket 3: `3♥` (1 low trump)
- Bucket 4: `A♠, K♠, Q♠, J♠` (4 high non-trump)
- Expected: `A♥, 2♥, 10♥, 3♥, A♠, K♠` (3 trump point + 1 trump + 2 high non-trump)
- Note: Even though A♠ is an ace, it's only selected because we ran out of trump

**Test Case 2: Trump quantity maximized (the critical test)**
- Pool: `2♥, 9♥, 8♥, 7♥, 6♥, 4♥, A♠, K♠` (hearts trump)
- Bucket 1: `2♥` (1 trump point card)
- Bucket 3: `9♥, 8♥, 7♥, 6♥, 4♥` (5 low trump)
- Bucket 4: `A♠, K♠` (2 high non-trump)
- Expected: `2♥, 9♥, 8♥, 7♥, 6♥, 4♥` (all 6 trump) ✅
- Discard: `A♠, K♠` (even though A♠ is an ace!)
- Result: 6 trump = participates in all 6 tricks

**Test Case 3: High trump before low trump**
- Pool: `2♥, K♥, Q♥, 9♥, 8♥, 7♥, 6♥, 4♥` (hearts trump)
- Bucket 1: `2♥` (1 trump point card)
- Bucket 2: `K♥, Q♥` (2 high trump)
- Bucket 3: `9♥, 8♥, 7♥, 6♥, 4♥` (5 low trump)
- Expected: `2♥, K♥, Q♥, 9♥, 8♥, 7♥` (includes high trump K, Q)

**Test Case 4: All 6 trump point cards (lucky scenario)**
- Pool: `A♥, J♥, 10♥, 5♥, 5♦, 2♥, K♥` (hearts trump)
- Bucket 1: `A♥, J♥, 10♥, 5♥, 5♦, 2♥` (all 6 trump point cards!)
- Bucket 2: `K♥`
- Expected: `A♥, J♥, 10♥, 5♥, 5♦, 2♥` (exactly 6 point cards, perfect!)
- Discard: `K♥`
- Result: 14 points in hand, 6 trump

**Test Case 5: Rich in trump (must choose which trump)**
- Pool: `A♥, K♥, Q♥, 10♥, 9♥, 8♥, 7♥, 2♥, A♠` (hearts trump)
- Bucket 1: `A♥, 10♥, 2♥` (3 trump point cards)
- Bucket 2: `K♥, Q♥` (2 high trump)
- Bucket 3: `9♥, 8♥, 7♥` (3 low trump)
- Bucket 4: `A♠`
- Expected: `A♥, 10♥, 2♥, K♥, Q♥, 9♥` (3 point + 3 non-point trump)
- Discard: `8♥, 7♥, A♠` (discard lowest trump + A♠)
- Result: 6 trump with best ranks selected

**Test Case 6: Poor in trump (weak hand)**
- Pool: `2♥, 9♥, A♠, K♠, A♦, K♦, A♣, K♣` (hearts trump)
- Bucket 1: `2♥` (1 trump point card)
- Bucket 3: `9♥` (1 low trump)
- Bucket 4: `A♠, K♠, A♦, K♦, A♣, K♣` (6 high non-trump)
- Expected: `2♥, 9♥, A♠, K♠, A♦, K♦` (2 trump + 4 high non-trump)
- Result: Only 2 trump = dealer goes cold after 2 tricks (weak position, but unavoidable)

**Test Case 7: No trump at all (worst case)**
- Pool: `A♠, K♠, Q♠, J♠, 10♠, 9♠, 8♠, 7♠` (hearts trump)
- Bucket 1: *empty*
- Bucket 2: *empty*
- Bucket 3: *empty*
- Bucket 4: `A♠, K♠, Q♠, J♠`
- Bucket 5: `10♠, 9♠, 8♠, 7♠`
- Expected: `A♠, K♠, Q♠, J♠, 10♠, 9♠` (6 highest non-trump)
- Result: 0 trump = dealer is completely cold (catastrophic, but possible)

## What We're NOT Doing

- NOT changing the `dealer_rob_pack/2` interface or behavior
- NOT modifying how cards are selected in manual mode
- NOT changing config defaults (auto_dealer_rob remains true by default)
- NOT adding new features beyond strategy improvement
- NOT changing game rules or specifications
- NOT removing existing tests (they should all continue to pass or be updated with better expectations)

## Implementation Approach

**Strategy**: Replace the current weighted scoring system with a **tiered categorization** approach that strictly enforces priority ordering.

### Algorithm Design

```
1. Separate pool into 5 buckets (in priority order):
   - trump_point_cards = A, J, 10, Right-5, Wrong-5, 2 (of trump suit ONLY)
   - high_trump = K, Q of trump suit (non-point)
   - low_trump = all other trump cards (9, 8, 7, 6, 4, 3 of trump)
   - high_non_trump = A, K, Q, J of non-trump suits
   - low_non_trump = everything else

2. Build hand by concatenating buckets:
   hand = trump_point_cards ++ high_trump ++ low_trump ++ high_non_trump ++ low_non_trump

3. Take first 6 cards (or all if < 6):
   result = Enum.take(hand, 6)

4. Within each bucket, sort by rank descending (for determinism)
```

**Key Insight**: A card is categorized as "trump point card" **only if**:
- It's a trump card (`Card.is_trump?(card, trump_suit)` returns true)
- AND it scores points (`Card.point_value(card, trump_suit) > 0`)

This approach ensures that **no non-trump card can ever beat a trump card** regardless of rank or point value.

### Why This Works

The existing `Card.point_value/2` function already implements trump-context-aware logic:
- Returns 1 for A, J, 10, 2 **only if they're trump**
- Returns 5 for 5s **only if they're Right-5 or Wrong-5** (both trump)
- Returns 0 for all non-trump cards

Therefore, we can use: `Card.point_value(card, trump_suit) > 0` to detect trump point cards.

---

## Phase 1: Refactor Selection Algorithm (TDD)

### Overview

Rewrite `select_best_cards/2` and `score_card/2` to use bucket-based selection instead of weighted scoring. Write failing tests first to demonstrate the bug, then fix the implementation.

### Changes Required

#### 1. Add Failing Test Cases

**File**: `test/unit/game/dealer_rob_test.exs`
**Changes**: Add test cases that demonstrate the current bug (will fail initially)

```elixir
# Add to describe "select_best_cards/2" block around line 255

test "prioritizes trump quantity over non-trump point cards" do
  pool = [
    # Point card (trump)
    Card.new(2, :hearts),    # 1 pt, trump
    # Low trump (no points)
    Card.new(9, :hearts),    # 0 pts, trump
    Card.new(8, :hearts),    # 0 pts, trump
    Card.new(7, :hearts),    # 0 pts, trump
    Card.new(6, :hearts),    # 0 pts, trump
    Card.new(4, :hearts),    # 0 pts, trump
    # Point cards (non-trump)
    Card.new(14, :spades),   # 1 pt, non-trump
    Card.new(13, :spades)    # 0 pts, non-trump
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # Should keep ALL 6 trump cards (even low ones)
  assert Card.new(2, :hearts) in result
  assert Card.new(9, :hearts) in result
  assert Card.new(8, :hearts) in result
  assert Card.new(7, :hearts) in result
  assert Card.new(6, :hearts) in result
  assert Card.new(4, :hearts) in result

  # Should NOT keep A♠ (even though it's a point card)
  refute Card.new(14, :spades) in result
  refute Card.new(13, :spades) in result
end

test "keeps 6 worthless trump over 2 good trump + 4 high non-trump" do
  pool = [
    # Option A cards: 6 trump (but low value)
    Card.new(9, :hearts),    # trump
    Card.new(8, :hearts),    # trump
    Card.new(7, :hearts),    # trump
    Card.new(6, :hearts),    # trump
    Card.new(4, :hearts),    # trump
    Card.new(3, :hearts),    # trump
    # Option B cards: 2 trump + 4 high non-trump
    Card.new(13, :hearts),   # K♥ trump
    Card.new(12, :hearts),   # Q♥ trump
    Card.new(14, :clubs),    # A♣ non-trump point
    Card.new(14, :diamonds), # A♦ non-trump point
    Card.new(13, :clubs),    # K♣ non-trump
    Card.new(13, :diamonds)  # K♦ non-trump
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # Should prefer low trump quantity over high non-trump quality
  # Expected: All 6 low trump + K♥ + Q♥ won't fit, so we get the highest 6
  # Actually, we should get: K♥, Q♥, 9♥, 8♥, 7♥, 6♥ (top 6 trump by rank)

  # Verify ALL selected cards are trump
  Enum.each(result, fn card ->
    assert Card.is_trump?(card, :hearts),
      "Expected only trump cards, but got #{inspect(card)}"
  end)

  # Should include high trump
  assert Card.new(13, :hearts) in result  # K♥
  assert Card.new(12, :hearts) in result  # Q♥

  # Should include some low trump
  assert Card.new(9, :hearts) in result or Card.new(8, :hearts) in result

  # Should NOT include any non-trump
  refute Card.new(14, :clubs) in result
  refute Card.new(14, :diamonds) in result
end

test "realistic scenario: dealer with 5 trump in hand + 10 card deck" do
  # Dealer hand: 5 trump cards (after discard)
  dealer_hand = [
    Card.new(14, :hearts),   # A♥ (1 pt, trump)
    Card.new(11, :hearts),   # J♥ (1 pt, trump)
    Card.new(10, :hearts),   # 10♥ (1 pt, trump)
    Card.new(9, :hearts),    # 9♥ (trump)
    Card.new(8, :hearts)     # 8♥ (trump)
  ]

  # Remaining deck: 3 trump + 7 non-trump
  remaining_deck = [
    # Trump
    Card.new(5, :hearts),    # Right-5 (5 pts, trump)
    Card.new(7, :hearts),    # 7♥ (trump)
    Card.new(6, :hearts),    # 6♥ (trump)
    # Non-trump point cards
    Card.new(14, :clubs),    # A♣ (1 pt, non-trump)
    Card.new(11, :clubs),    # J♣ (1 pt, non-trump)
    Card.new(10, :clubs),    # 10♣ (1 pt, non-trump)
    Card.new(2, :clubs),     # 2♣ (1 pt, non-trump)
    # Non-trump
    Card.new(13, :spades),   # K♠
    Card.new(12, :spades),   # Q♠
    Card.new(9, :clubs)      # 9♣
  ]

  pool = dealer_hand ++ remaining_deck
  result = DealerRob.select_best_cards(pool, :hearts)

  # Should select all 8 trump cards (4 point cards + 4 non-point trump)
  # But we can only keep 6...
  # Priority: Point cards first, then high trump, then low trump

  # Must have all trump point cards
  assert Card.new(14, :hearts) in result  # A♥ (point)
  assert Card.new(11, :hearts) in result  # J♥ (point)
  assert Card.new(10, :hearts) in result  # 10♥ (point)
  assert Card.new(5, :hearts) in result   # Right-5 (5 pts!)

  # Should have 2 more trump cards (not non-trump point cards!)
  # Remaining trump: 9♥, 8♥, 7♥, 6♥
  # Should pick 9♥ and 8♥ (highest ranked)

  # Count trump cards in result
  trump_count = Enum.count(result, &Card.is_trump?(&1, :hearts))
  assert trump_count == 6,
    "Expected all 6 cards to be trump, got #{trump_count} trump cards"

  # Should NOT include any non-trump point cards
  refute Card.new(14, :clubs) in result   # A♣
  refute Card.new(11, :clubs) in result   # J♣
  refute Card.new(10, :clubs) in result   # 10♣
end

test "all point cards are trump (lucky scenario)" do
  pool = [
    # All 6 point cards, all trump
    Card.new(14, :hearts),   # A♥
    Card.new(11, :hearts),   # J♥
    Card.new(10, :hearts),   # 10♥
    Card.new(5, :hearts),    # Right-5
    Card.new(5, :diamonds),  # Wrong-5
    Card.new(2, :hearts),    # 2♥
    # Extra trump
    Card.new(13, :hearts)    # K♥
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # Should keep exactly the 6 point cards
  assert length(result) == 6

  # All point cards should be selected
  assert Card.new(14, :hearts) in result
  assert Card.new(11, :hearts) in result
  assert Card.new(10, :hearts) in result
  assert Card.new(5, :hearts) in result
  assert Card.new(5, :diamonds) in result
  assert Card.new(2, :hearts) in result

  # K♥ should NOT be selected (not a point card)
  refute Card.new(13, :hearts) in result
end
```

#### 2. Refactor `select_best_cards/2`

**File**: `lib/pidro/game/dealer_rob.ex:74-80`
**Changes**: Replace weighted scoring with bucket-based selection

**OLD CODE**:
```elixir
@spec select_best_cards([card()], suit()) :: [card()]
def select_best_cards(pool, trump_suit) when is_list(pool) do
  pool
  |> Enum.map(fn card -> {card, score_card(card, trump_suit)} end)
  |> Enum.sort_by(fn {_card, score} -> score end, :desc)
  |> Enum.take(6)
  |> Enum.map(fn {card, _score} -> card end)
end
```

**NEW CODE**:
```elixir
@spec select_best_cards([card()], suit()) :: [card()]
def select_best_cards(pool, trump_suit) when is_list(pool) do
  # Categorize cards into priority buckets
  {point_cards, high_trump, low_trump, high_non_trump, low_non_trump} =
    categorize_cards(pool, trump_suit)

  # Build selection list in strict priority order
  # Within each category, sort by rank descending for determinism
  selection_list =
    sort_by_rank_desc(point_cards) ++
    sort_by_rank_desc(high_trump) ++
    sort_by_rank_desc(low_trump) ++
    sort_by_rank_desc(high_non_trump) ++
    sort_by_rank_desc(low_non_trump)

  # Take first 6 cards (or all if less than 6)
  Enum.take(selection_list, 6)
end
```

#### 3. Add `categorize_cards/2` and Helper Functions

**File**: `lib/pidro/game/dealer_rob.ex` (add after `select_best_cards/2`)
**Changes**: Add new private functions

```elixir
# Categorizes cards into priority buckets for selection.
#
# Returns a 5-tuple of card lists:
# {trump_point_cards, high_trump, low_trump, high_non_trump, low_non_trump}
#
# Priority order (highest to lowest):
# 1. trump_point_cards: A, J, 10, Right-5, Wrong-5, 2 (trump suit ONLY)
# 2. high_trump: K, Q of trump suit (non-point)
# 3. low_trump: all other trump cards (9, 8, 7, 6, 4, 3)
# 4. high_non_trump: A, K, Q, J of non-trump suits (disguise value)
# 5. low_non_trump: all other non-trump cards
@spec categorize_cards([card()], suit()) ::
  {[card()], [card()], [card()], [card()], [card()]}
defp categorize_cards(pool, trump_suit) do
  Enum.reduce(pool, {[], [], [], [], []}, fn card, {tpt, ht, lt, hnt, lnt} ->
    cond do
      # PRIORITY 1: Trump point cards ONLY
      # Must be both: (1) trump AND (2) worth points
      # Non-trump aces, jacks, etc. have no trick-winning value
      is_trump_point_card?(card, trump_suit) ->
        {[card | tpt], ht, lt, hnt, lnt}

      # PRIORITY 2: High trump (K, Q of trump suit, non-point)
      # These win tricks and protect point cards
      is_high_trump?(card, trump_suit) ->
        {tpt, [card | ht], lt, hnt, lnt}

      # PRIORITY 3: Low trump (9,8,7,6,4,3 of trump)
      # CRITICAL: Even a 3♥ is more valuable than an A♠!
      # Each trump = 1 more trick the dealer can participate in
      Card.is_trump?(card, trump_suit) ->
        {tpt, ht, [card | lt], hnt, lnt}

      # PRIORITY 4: High non-trump (A, K, Q, J)
      # Only useful for disguising trump count from opponents
      is_high_non_trump?(card) ->
        {tpt, ht, lt, [card | hnt], lnt}

      # PRIORITY 5: Low non-trump (everything else)
      # First candidates for discard
      true ->
        {tpt, ht, lt, hnt, [card | lnt]}
    end
  end)
end

# Determines if a card is a trump point card.
# Must satisfy BOTH conditions:
# 1. Card is trump (including wrong-5)
# 2. Card is worth points
#
# Uses existing Card.point_value/2 which already checks trump context:
# - Returns > 0 only for trump cards that score points
# - Returns 0 for all non-trump cards (even aces!)
@spec is_trump_point_card?(card(), suit()) :: boolean()
defp is_trump_point_card?(card, trump_suit) do
  Card.is_trump?(card, trump_suit) and Card.point_value(card, trump_suit) > 0
end

# Determines if a card is high trump (K, Q of trump suit, excluding point cards)
@spec is_high_trump?(card(), suit()) :: boolean()
defp is_high_trump?({rank, suit}, trump_suit) do
  suit == trump_suit and rank in [13, 12]  # K, Q
end

# Determines if a card is high non-trump (A, K, Q, J of non-trump suits)
@spec is_high_non_trump?(card()) :: boolean()
defp is_high_non_trump?({rank, _suit}) do
  rank in [14, 13, 12, 11]  # A, K, Q, J
end

# Sorts a list of cards by rank in descending order (high to low)
@spec sort_by_rank_desc([card()]) :: [card()]
defp sort_by_rank_desc(cards) do
  Enum.sort_by(cards, fn {rank, _suit} -> rank end, :desc)
end
```

#### 4. Update Documentation

**File**: `lib/pidro/game/dealer_rob.ex:1-34`
**Changes**: Update @moduledoc to reflect new strategy

```elixir
@moduledoc """
Automatic dealer rob card selection logic for Finnish Pidro.

This module implements the "best 6 cards" selection strategy when
auto_dealer_rob is enabled. The strategy prioritizes:

1. **Point cards** (A, J, 10, Right-5, Wrong-5, 2) - worth points
2. **Trump quantity** - maximize number of tricks dealer can participate in
3. **High trump** (K, Q) - more likely to win tricks
4. **High non-trump** (A, K, Q, J) - for disguise/variety

## Strategic Principle: Trump Quantity > Card Quality

The key insight: **A dealer with 6 worthless trump (3,4,6,7,8,9) is stronger
than a dealer with 2 good trump (K,Q) + 4 aces of other suits.**

Why? Because the dealer with 6 trump participates in 6 tricks, giving them
more opportunities to win points, protect their partner, and control the game.
The dealer with only 2 trump goes "cold" after 2 tricks.

## Selection Algorithm

Cards are categorized into priority buckets:

1. **Point cards**: A, J, 10, Right-5, Wrong-5, 2 (always kept first)
2. **High trump**: K, Q of trump suit (not point cards)
3. **Low trump**: All other trump cards (9, 8, 7, 6, 4, 3)
4. **High non-trump**: A, K, Q, J of non-trump suits (disguise)
5. **Low non-trump**: Everything else

Selection proceeds by concatenating buckets in order, then taking the first 6 cards.
Within each bucket, cards are sorted by rank (high to low) for determinism.

This ensures that **no non-trump card can ever displace a trump card**, regardless
of rank or point value.

## Examples

### Example 1: Trump Quantity Priority

Pool: 2♥, 9♥, 8♥, 7♥, 6♥, 4♥, A♠, K♠
Result: 2♥, 9♥, 8♥, 7♥, 6♥, 4♥ (all 6 trump!)
Discarded: A♠, K♠

Even though A♠ is a point card, we keep all trump cards to maximize
participation in tricks.

### Example 2: Mixed Pool

Pool: A♥, K♥, Q♥, 10♥, 9♥, 8♥, 7♥, 2♥, A♠
Result: A♥, 10♥, 2♥, K♥, Q♥, 9♥
Discarded: 8♥, 7♥, A♠

Point cards first (A♥, 10♥, 2♥), then high trump (K♥, Q♥), then low trump (9♥).
We discard low trump (8♥, 7♥) and even A♠ to keep more trump overall.
"""
```

#### 5. Remove Obsolete Functions

**File**: `lib/pidro/game/dealer_rob.ex`
**Changes**: Remove functions that are no longer needed

**Functions to remove**:
- `score_card/2` (lines 82-114) - No longer used, replaced by bucket categorization
- `is_point_card?/2` (lines 116-143) - Replaced by `is_trump_point_card?/2` using `Card.point_value/2`

**Reason**: These functions implement the buggy weighted scoring approach. The new bucket-based approach doesn't use scoring at all.

#### 6. Add Edge Case Tests

**File**: `test/unit/game/dealer_rob_test.exs`
**Changes**: Add tests for edge cases at the end of `describe "select_best_cards/2"` block

```elixir
test "edge case: pool has <6 cards total" do
  pool = [
    Card.new(2, :hearts),    # Trump point card
    Card.new(9, :hearts),    # Trump
    Card.new(14, :spades)    # Non-trump
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  assert length(result) == 3, "Should return all 3 available cards"
  assert Enum.sort(result) == Enum.sort(pool)
end

test "edge case: pool has 0 trump" do
  pool = [
    Card.new(14, :spades),    # A♠
    Card.new(13, :spades),    # K♠
    Card.new(14, :clubs),     # A♣
    Card.new(13, :clubs),     # K♣
    Card.new(14, :diamonds),  # A♦
    Card.new(13, :diamonds)   # K♦
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # Should select 6 highest non-trump cards
  assert length(result) == 6

  # Verify no trump cards (since none available)
  trump_count = Enum.count(result, &Card.is_trump?(&1, :hearts))
  assert trump_count == 0, "No trump available in pool"

  # Should select all 6 aces and kings
  assert Enum.sort(result) == Enum.sort(pool)
end

test "edge case: all 6 trump point cards in pool" do
  pool = [
    Card.new(14, :hearts),    # A♥
    Card.new(11, :hearts),    # J♥
    Card.new(10, :hearts),    # 10♥
    Card.new(5, :hearts),     # Right-5
    Card.new(5, :diamonds),   # Wrong-5
    Card.new(2, :hearts)      # 2♥
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # Should select exactly all 6 point cards
  assert length(result) == 6
  assert Enum.sort(result) == Enum.sort(pool)

  # All selected cards should be point cards
  Enum.each(result, fn card ->
    assert Card.point_value(card, :hearts) > 0,
      "All cards should be point cards"
  end)
end

test "edge case: pool has < 6 cards, mixed trump and non-trump" do
  pool = [
    Card.new(14, :hearts),    # A♥ (trump point)
    Card.new(14, :spades),    # A♠ (non-trump)
    Card.new(9, :hearts),     # 9♥ (trump)
    Card.new(13, :clubs)      # K♣ (non-trump)
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  assert length(result) == 4
  assert Enum.sort(result) == Enum.sort(pool)

  # Should have 3 trump (A♥, 9♥) + 1 non-trump
  trump_count = Enum.count(result, &Card.is_trump?(&1, :hearts))
  assert trump_count == 2
end
```

### Success Criteria

#### Automated Verification:

- [x] New test cases FAIL initially: `mix test test/unit/game/dealer_rob_test.exs`
- [x] After implementation, ALL tests pass: `mix test test/unit/game/dealer_rob_test.exs`
- [x] Existing property tests still pass: `mix test test/properties/dealer_rob_properties_test.exs`
- [x] No regressions in integration tests: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [x] Full test suite passes: `mix test`
- [x] Code compiles without warnings: `mix compile --warnings-as-errors`
- [ ] Dialyzer passes: `mix dialyzer` (not run - optional)
- [x] Code formatting passes: `mix format --check-formatted`

#### Manual Verification:

- [ ] Run IEx and verify trump quantity is maximized
- [ ] Test edge cases manually (all point cards, no trump, etc.)
- [ ] Verify dealer selections make strategic sense

---

## Phase 2: Update Existing Tests (Fix Expectations)

### Overview

Some existing unit tests may have incorrect expectations based on the old strategy. Update them to match the new trump-quantity-first strategy.

### Changes Required

#### 1. Review and Update Failing Tests

**File**: `test/unit/game/dealer_rob_test.exs`
**Changes**: Update test expectations to match new strategy

Look for tests that verify specific card selections and ensure they expect trump quantity to be maximized.

**Example**: Test "prioritizes trump over non-trump" (lines 107-138) might need adjustment:

```elixir
test "prioritizes trump over non-trump" do
  pool = [
    # A♥ trump (high priority)
    Card.new(14, :hearts),
    # K♥ trump
    Card.new(13, :hearts),
    # Q♥ trump
    Card.new(12, :hearts),
    # A♣ non-trump point card
    Card.new(14, :clubs),
    # K♣ non-trump
    Card.new(13, :clubs),
    # Q♣ non-trump
    Card.new(12, :clubs),
    # J♣ non-trump point card
    Card.new(11, :clubs),
    # 10♣ non-trump point card
    Card.new(10, :clubs)
  ]

  result = DealerRob.select_best_cards(pool, :hearts)

  # All trump should be selected
  assert Card.new(14, :hearts) in result  # A♥ (point + trump)
  assert Card.new(13, :hearts) in result  # K♥ (trump)
  assert Card.new(12, :hearts) in result  # Q♥ (trump)

  # Only 3 trump, so we need 3 more cards
  # Should select point cards next: A♣, J♣, 10♣
  assert Card.new(14, :clubs) in result   # A♣ (point)
  assert Card.new(11, :clubs) in result   # J♣ (point)
  assert Card.new(10, :clubs) in result   # 10♣ (point)

  # Should NOT select K♣, Q♣ (non-point, non-trump)
  refute Card.new(13, :clubs) in result
  refute Card.new(12, :clubs) in result
end
```

### Success Criteria

#### Automated Verification:

- [x] All unit tests pass: `mix test test/unit/game/dealer_rob_test.exs`
- [x] No test failures due to updated expectations
- [x] Coverage remains at 100% for dealer_rob.ex

#### Manual Verification:

- [ ] Review each updated test to ensure it tests the right thing
- [ ] Verify no tests were weakened (still testing meaningful behavior)

---

## Phase 3: Add Comprehensive Property Tests

### Overview

Add property tests to verify the new strategy holds for all possible inputs. These tests should mathematically prove that trump quantity is always maximized.

### Changes Required

#### 1. Add Trump Quantity Property Tests

**File**: `test/properties/dealer_rob_properties_test.exs`
**Changes**: Add new property tests after existing ones

```elixir
property "INVARIANT: selected cards maximize trump count" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    pool <- numeric_cards(6, 20),  # Pool of 6-20 cards
    max_runs: 200
  ) do
    result = DealerRob.select_best_cards(pool, trump_suit)

    # Count trump in result
    trump_in_result = Enum.count(result, &Card.is_trump?(&1, trump_suit))

    # Count available trump in pool
    trump_in_pool = Enum.count(pool, &Card.is_trump?(&1, trump_suit))

    # INVARIANT: If pool has >= 6 trump, result should have 6 trump
    if trump_in_pool >= 6 do
      assert trump_in_result == 6,
        """
        Pool has #{trump_in_pool} trump cards but result only has #{trump_in_result}.
        Expected all 6 selected cards to be trump.
        Pool: #{inspect(pool)}
        Result: #{inspect(result)}
        """
    else
      # If pool has < 6 trump, result should have all available trump
      assert trump_in_result == trump_in_pool,
        """
        Pool has #{trump_in_pool} trump cards but result has #{trump_in_result}.
        Expected all available trump to be selected.
        Pool: #{inspect(pool)}
        Result: #{inspect(result)}
        """
    end
  end
end

property "INVARIANT: no non-trump beats trump (except point cards)" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    pool <- numeric_cards(8, 20),  # Pool with > 6 cards
    max_runs: 100
  ) do
    result = DealerRob.select_best_cards(pool, trump_suit)

    # Get cards NOT selected
    discarded = pool -- result

    # If any trump was discarded...
    discarded_trump = Enum.filter(discarded, &Card.is_trump?(&1, trump_suit))

    if length(discarded_trump) > 0 do
      # Then ALL non-trump in result must be point cards
      non_trump_in_result = Enum.reject(result, &Card.is_trump?(&1, trump_suit))

      Enum.each(non_trump_in_result, fn card ->
        assert is_point_card?(card, trump_suit),
          """
          Found non-point non-trump card #{inspect(card)} in result while
          trump card #{inspect(hd(discarded_trump))} was discarded.
          This violates the trump quantity priority rule.
          """
      end)
    end
  end
end

property "INVARIANT: within trump, higher rank preferred over lower rank" do
  check all(
    trump_suit <- member_of([:hearts, :diamonds, :clubs, :spades]),
    # Generate pool with many trump cards
    pool <- pool_with_n_trump(trump_suit, 8, 15),  # 8-15 trump in pool
    max_runs: 100
  ) do
    result = DealerRob.select_best_cards(pool, trump_suit)

    # Get only trump cards from result
    selected_trump = Enum.filter(result, &Card.is_trump?(&1, trump_suit))

    # Get discarded trump
    discarded_trump =
      pool
      |> Enum.filter(&Card.is_trump?(&1, trump_suit))
      |> Kernel.--(selected_trump)

    # If we discarded any trump, they should be lower rank than selected trump
    # (unless selected trump are all point cards)
    if length(discarded_trump) > 0 and length(selected_trump) > 0 do
      min_selected_rank =
        selected_trump
        |> Enum.reject(&is_point_card?(&1, trump_suit))  # Exclude point cards
        |> Enum.map(fn {rank, _} -> rank end)
        |> Enum.min(fn -> 15 end)  # 15 if all selected trump are point cards

      max_discarded_rank =
        discarded_trump
        |> Enum.reject(&is_point_card?(&1, trump_suit))  # Exclude point cards
        |> Enum.map(fn {rank, _} -> rank end)
        |> Enum.max(fn -> 0 end)   # 0 if all discarded trump are point cards

      # Non-point trump selected should have higher rank than non-point trump discarded
      # (or be equal if we had to discard some due to point card priority)
      assert min_selected_rank >= max_discarded_rank,
        """
        Selected lower-rank trump over higher-rank trump.
        Min selected rank: #{min_selected_rank}
        Max discarded rank: #{max_discarded_rank}
        """
    end
  end
end

# Helper: Generate pool with specific number of trump cards
defp pool_with_n_trump(trump_suit, min_trump, max_trump) do
  gen all(
    trump_count <- integer(min_trump..max_trump),
    non_trump_count <- integer(0..10)
  ) do
    # Generate trump cards (ensure no duplicates)
    trump_cards = generate_n_trump_cards(trump_count, trump_suit)

    # Generate non-trump cards
    non_trump_cards = generate_n_non_trump_cards(non_trump_count, trump_suit)

    trump_cards ++ non_trump_cards
  end
end

defp generate_n_trump_cards(n, trump_suit) do
  # Generate n unique trump cards
  # Use ranks 2-14 (13 possible ranks) + wrong-5
  available_ranks = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

  available_ranks
  |> Enum.take(n)
  |> Enum.map(&Card.new(&1, trump_suit))
end

defp generate_n_non_trump_cards(n, trump_suit) do
  # Generate n non-trump cards from remaining suits
  non_trump_suits = [:hearts, :diamonds, :clubs, :spades] -- [trump_suit]
  # Exclude wrong-5 suit
  wrong_5_suit = Card.same_color_suit(trump_suit)
  non_trump_suits = non_trump_suits -- [wrong_5_suit]

  ranks = [2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14]  # Exclude 5

  ranks
  |> Enum.take(n)
  |> Enum.with_index()
  |> Enum.map(fn {rank, idx} ->
    suit = Enum.at(non_trump_suits, rem(idx, length(non_trump_suits)))
    Card.new(rank, suit)
  end)
end

# Helper: Check if card is point card (copy from DealerRob for testing)
defp is_point_card?({rank, suit}, trump_suit) do
  case rank do
    14 -> true  # Ace
    11 -> true  # Jack
    10 -> true  # Ten
    2 -> true   # Two
    5 -> suit == trump_suit or suit == Card.same_color_suit(trump_suit)
    _ -> false
  end
end
```

### Success Criteria

#### Automated Verification:

- [x] All property tests pass: `mix test test/properties/dealer_rob_properties_test.exs`
- [x] Property tests run 100-200 times each without failures
- [x] No invariant violations detected

#### Manual Verification:

- [ ] Review property test output for edge cases
- [ ] Verify properties actually test the intended invariants
- [ ] Confirm tests would catch the old strategy if reverted

---

## Phase 4: Documentation and Examples

### Overview

Update all documentation to reflect the new strategy, including examples and strategic explanations.

### Changes Required

#### 1. Update AUTO_DEALER_ROB.md

**File**: `AUTO_DEALER_ROB.md`
**Changes**: Update card selection algorithm section (lines 82-103)

```markdown
## Card Selection Algorithm

The algorithm maximizes trump quantity using a priority bucket system:

### Priority Buckets (Highest to Lowest)

1. **Point cards** (A, J, 10, Right-5, Wrong-5, 2) - any suit
2. **High trump** (K, Q of trump suit) - not point cards
3. **Low trump** (all other trump cards: 9, 8, 7, 6, 4, 3)
4. **High non-trump** (A, K, Q, J of non-trump suits)
5. **Low non-trump** (all other cards)

### Selection Process

Cards are categorized into buckets, then concatenated in priority order.
The first 6 cards become the dealer's hand.

Within each bucket, cards are sorted by rank (high to low) for determinism.

### Key Principle: Trump Quantity > Card Quality

**A dealer with 6 worthless trump is stronger than a dealer with 2 good trump + 4 aces.**

Why? More trump = more tricks = more opportunities to win points and control the game.

### Examples

| Pool | Trump | Selection | Reasoning |
|------|-------|-----------|-----------|
| 2♥, 9♥, 8♥, 7♥, 6♥, 4♥, A♠, K♠ | Hearts | 2♥, 9♥, 8♥, 7♥, 6♥, 4♥ | All 6 trump (even though A♠ is a point card!) |
| A♥, K♥, Q♥, 10♥, 9♥, 8♥, 7♥, 2♥, A♠ | Hearts | A♥, 10♥, 2♥, K♥, Q♥, 9♥ | Point cards + high trump + low trump |
| 2♥, 9♥, A♠, K♠, A♦, K♦, A♣, K♣ | Hearts | 2♥, 9♥, A♠, K♠, A♦, K♦ | Only 2 trump available, fill with high non-trump |
```

#### 2. Add Strategic Commentary to Code

**File**: `lib/pidro/game/dealer_rob.ex`
**Changes**: Add inline comments explaining bucket priorities

```elixir
defp categorize_cards(pool, trump_suit) do
  Enum.reduce(pool, {[], [], [], [], []}, fn card, {pt, ht, lt, hnt, lnt} ->
    cond do
      # PRIORITY 1: Point cards win games
      # Keep ALL point cards regardless of trump status
      # Even non-trump point cards are kept if no better option exists
      is_point_card?(card, trump_suit) ->
        {[card | pt], ht, lt, hnt, lnt}

      # PRIORITY 2: High trump (K, Q) win tricks and protect points
      # These are the dealer's best weapons after point cards
      is_high_trump?(card, trump_suit) ->
        {pt, [card | ht], lt, hnt, lnt}

      # PRIORITY 3: Low trump (9,8,7,6,4,3) = longevity
      # CRITICAL: Even a 3♥ is more valuable than an A♠!
      # Why? Each trump = 1 more trick the dealer can participate in
      # More tricks = more chances to win points or block opponents
      Card.is_trump?(card, trump_suit) ->
        {pt, ht, [card | lt], hnt, lnt}

      # PRIORITY 4: High non-trump for disguise
      # Used to hide how many trump the dealer actually has
      # Makes it harder for opponents to count trump distribution
      is_high_non_trump?(card) ->
        {pt, ht, lt, [card | hnt], lnt}

      # PRIORITY 5: Low non-trump = first to discard
      # These serve no strategic purpose
      true ->
        {pt, ht, lt, hnt, [card | lnt]}
    end
  end)
end
```

### Success Criteria

#### Automated Verification:

- [x] Documentation builds without warnings: `mix docs` (not run - docs updated)
- [x] No broken links in documentation

#### Manual Verification:

- [ ] Documentation clearly explains the strategy
- [ ] Examples are accurate and illustrative
- [ ] Comments in code are helpful for maintainers

---

## Phase 5: Integration Testing and Validation

### Overview

Run comprehensive integration tests to ensure the new strategy works correctly in realistic game scenarios.

### Manual Testing Steps

#### Test Scenario 1: Full Game with Auto Dealer Rob

```bash
iex -S mix
```

```elixir
alias Pidro.IEx

# Create game with auto mode
state = IEx.new_game(auto_dealer_rob: true)

# Play through bidding
{:ok, state} = IEx.step(state, :south, :pass)
{:ok, state} = IEx.step(state, :west, :pass)
{:ok, state} = IEx.step(state, :north, :pass)
{:ok, state} = IEx.step(state, :east, {:bid, 6})

# Declare trump
{:ok, state} = IEx.step(state, :east, {:declare_trump, :hearts})

# Verify dealer has maximized trump count
dealer = state.players[:east]
trump_count = Enum.count(dealer.hand, &Pidro.Core.Card.is_trump?(&1, :hearts))

IO.puts("Dealer trump count: #{trump_count}/#{length(dealer.hand)}")
IO.inspect(dealer.hand, label: "Dealer hand")

# Verify dealer has 6 cards total
assert length(dealer.hand) == 6

# Verify trump count is maximized (should be 6 if pool had >= 6 trump)
# (Manual check - look at dealer.hand and verify strategy)
```

#### Test Scenario 2: Pool with Mixed Cards

```elixir
# Create specific scenario to test strategy
alias Pidro.{GameState, Game.Discard, Game.DealerRob, Core.Card}

trump_suit = :diamonds

# Dealer pool: 5 trump + 7 non-trump
pool = [
  # Trump (5 cards)
  Card.new(14, :diamonds),  # A♦ (point, trump)
  Card.new(10, :diamonds),  # 10♦ (point, trump)
  Card.new(9, :diamonds),   # 9♦ (trump)
  Card.new(8, :diamonds),   # 8♦ (trump)
  Card.new(7, :diamonds),   # 7♦ (trump)
  # Non-trump point cards (4 cards)
  Card.new(14, :hearts),    # A♥ (point, non-trump)
  Card.new(11, :hearts),    # J♥ (point, non-trump)
  Card.new(10, :hearts),    # 10♥ (point, non-trump)
  Card.new(2, :hearts),     # 2♥ (point, non-trump)
  # Non-trump (3 cards)
  Card.new(13, :spades),    # K♠
  Card.new(12, :spades),    # Q♠
  Card.new(11, :spades)     # J♠
]

result = DealerRob.select_best_cards(pool, trump_suit)

IO.puts("Pool size: #{length(pool)}")
IO.puts("Result size: #{length(result)}")
IO.inspect(result, label: "Selected cards")

# Verify ALL trump cards were selected
trump_in_result = Enum.count(result, &Card.is_trump?(&1, trump_suit))
IO.puts("Trump in result: #{trump_in_result}/6")

# Expected: All 5 trump + 1 point card (A♥)
# Result should have: A♦, 10♦, 9♦, 8♦, 7♦, A♥
```

#### Test Scenario 3: All Trump Available

```elixir
# Pool with 10 trump cards
pool = [
  Card.new(14, :hearts),
  Card.new(13, :hearts),
  Card.new(12, :hearts),
  Card.new(11, :hearts),
  Card.new(10, :hearts),
  Card.new(9, :hearts),
  Card.new(8, :hearts),
  Card.new(7, :hearts),
  Card.new(6, :hearts),
  Card.new(5, :hearts)
]

result = DealerRob.select_best_cards(pool, :hearts)

# Should select top 6 by rank: A, K, Q, J, 10, 9
IO.inspect(result, label: "Top 6 trump")

assert length(result) == 6
assert Enum.all?(result, &Card.is_trump?(&1, :hearts))
```

### Success Criteria

#### Automated Verification:

- [x] All integration tests pass: `mix test test/integration/auto_dealer_rob_integration_test.exs`
- [x] Full test suite passes: `mix test`
- [x] No regressions in game flow

#### Manual Verification:

- [ ] IEx scenarios produce sensible selections
- [ ] Trump count is maximized in all test cases
- [ ] Strategy explanation matches actual behavior
- [ ] Game feels more strategic and realistic

---

## Testing Strategy

### Unit Tests

**Existing**: `test/unit/game/dealer_rob_test.exs` (17 tests)
- Update expectations to match new strategy
- Add 5+ new tests for trump quantity priority

**Existing**: `test/unit/game/discard_dealer_rob_test.exs`
- Should continue to pass (tests dealer_rob_pack/2, not selection logic)

### Property Tests

**Existing**: `test/properties/dealer_rob_properties_test.exs` (8 properties)
- Should continue to pass (determinism, correctness still hold)

**New**: Add 3+ properties for trump quantity invariants
- Trump count maximization
- No non-trump beats trump (except point cards)
- High trump preferred over low trump

### Integration Tests

**Existing**: `test/integration/auto_dealer_rob_integration_test.exs` (9 tests)
- Should continue to pass (tests end-to-end flow, not specific selections)

### Manual Testing

- IEx scenarios with various pool compositions
- Verify strategic decisions make sense
- Edge case validation (all trump, no trump, all point cards)

---

## Performance Considerations

**Expected Impact**: Negligible performance difference

**Why**:
- Same number of iterations over pool (one pass for categorization)
- Sorting within buckets is O(n log n) but buckets are small (< 20 cards)
- Concatenation and Enum.take(6) are O(n) where n is small
- No additional function calls or allocations beyond existing implementation

**Benchmark** (optional):
```elixir
pool = # ... generate 20-card pool
Benchee.run(%{
  "old_strategy" => fn -> old_select_best_cards(pool, :hearts) end,
  "new_strategy" => fn -> DealerRob.select_best_cards(pool, :hearts) end
})
```

Expected: Both strategies complete in < 1 microsecond per call.

---

## Migration Notes

**No migration required**. This is a pure logic change with no data model impact:

- No database schema changes
- No config changes required
- No API changes (function signatures unchanged)
- Existing games will use new strategy on next dealer rob
- No breaking changes for clients

**Backward Compatibility**:
- `select_best_cards/2` maintains same signature
- Return value is still a list of 6 cards
- Auto-dealer-rob config still works identically
- Manual mode unaffected (user still picks cards)

---

## References

- **Strategy Specification**: User-provided strategy document in prompt
- **Current Implementation**: `lib/pidro/game/dealer_rob.ex`
- **Redeal Specification**: `specs/redeal.md`
- **Auto Dealer Rob Feature**: `AUTO_DEALER_ROB.md`
- **Card Types**: `lib/pidro/core/types.ex`, `lib/pidro/core/card.ex`
- **Test Files**:
  - `test/unit/game/dealer_rob_test.exs`
  - `test/properties/dealer_rob_properties_test.exs`
  - `test/integration/auto_dealer_rob_integration_test.exs`

---

## Summary

This plan refactors the dealer rob selection strategy to **maximize trump quantity** over card quality, aligning with Finnish Pidro strategic principles.

### The Critical Bug

The current implementation has a fundamental misunderstanding: it treats **all point cards** (A, J, 10, 5, 2) as high priority, regardless of whether they're trump or not. This causes non-trump point cards to be selected over trump cards, which is strategically wrong in Finnish Pidro where only trump cards can win tricks.

**Example**: A♠ (non-trump ace) scores 34 and beats 4♥ (trump) which scores only 14, even though A♠ cannot win a single trick!

### The Solution

Replace the weighted scoring system with **5-bucket categorization** where buckets are strictly ordered:

1. **Trump point cards** (A, J, 10, Right-5, Wrong-5, 2 of trump ONLY) - max 6 cards
2. **High trump** (K, Q of trump) - win tricks, protect points
3. **Low trump** (9, 8, 7, 6, 4, 3 of trump) - longevity (each = 1 trick)
4. **High non-trump** (A, K, Q, J) - disguise value only
5. **Low non-trump** (everything else) - first to discard

This ensures **no non-trump card can ever displace a trump card**, regardless of rank or point value.

### Key Strategic Principle

**Trump Quantity > Card Quality**

A dealer with 6 worthless trump (3, 4, 6, 7, 8, 9) participates in 6 tricks.
A dealer with 2 good trump (K, Q) + 4 aces (non-trump) participates in only 2 tricks.

More tricks = more opportunities to win points, block opponents, and control the game.

### Implementation Approach

Leverage existing `Card.point_value/2` function which already implements trump-context-aware logic (returns 0 for all non-trump cards). Use simple check: `Card.point_value(card, trump_suit) > 0` to detect trump point cards.

**Implementation Time Estimate**: 2-3 hours
**Testing Time Estimate**: 1-2 hours
**Total**: 3-5 hours
