# Edge Case Analysis: Finnish Pidro Redeal Implementation Gaps

**Date**: 2025-11-02  
**Source**: specs/redeal.md vs. implementation in lib/pidro/game/

---

## Executive Summary

**Critical Finding**: The implementation in `lib/pidro/game/discard.ex` handles basic redeal mechanics but is **MISSING all kill rule logic** specified in specs/redeal.md. No validation exists for the 5 edge cases documented in the spec.

---

## Edge Case 1: Dealer Gets No Cards ❌ NOT IMPLEMENTED

### Spec Requirement (lines 51-58)
- If all 3 non-dealers request 6 cards each (18 total)
- Remaining deck: 16 cards (after initial 36 dealt)
- Available to dealer: 16 - 18 = -2 (IMPOSSIBLE)
- System must handle this gracefully or validate it cannot occur

### Current Implementation Status
**File**: `lib/pidro/game/discard.ex:239-303` (second_deal/1)

**What exists**:
```elixir
# Line 277: Checks if dealer needs to rob
dealer_needs_rob = length(remaining_deck) > 0 and dealer_hand_size < 6
```

**Gap**: No validation for negative deck scenario. Code assumes deck has enough cards.

**Missing**:
- Pre-flight check: deck size >= sum of cards requested
- Error handling when `length(remaining_deck) < 0` conceptually
- Property test: "dealer always sees >= 6 cards (or game is invalid)" (spec line 113)

**Risk**: Runtime error if deck exhausted before dealer robs

---

## Edge Case 2: Player Has 7 Point Cards ❌ NOT IMPLEMENTED

### Spec Requirement (lines 62-67)
- Player ends up with 7+ point cards (A, J, 10, Right-5, Wrong-5, 2, +1 more)
- Cannot kill any cards (all are point cards)
- **Must keep all 7+ cards** and play with >6 hand
- First play puts down 2 cards to get back to 6

### Current Implementation Status
**File**: `lib/pidro/game/discard.ex` - **NO KILL LOGIC EXISTS**

**What exists**: Nothing related to kill rules

**Missing**:
- Kill card selection phase after second_deal
- Validation: `point_value(card, trump_suit) == 0` for killable cards
- Allow >6 cards if all trump and cannot kill (spec line 112)
- First trick mechanic: play top killed card (spec lines 99, 221-235)

**Related Code**:
- `lib/pidro/core/card.ex:247-275` - `point_value/2` exists (foundation)
- No kill validation functions anywhere

**Risk**: Players could end up with >6 cards and system has no handling for it

---

## Edge Case 3: Dealer Has >6 Trump After Robbing ❌ NOT IMPLEMENTED

### Spec Requirement (lines 69-77)
- Dealer combines hand (2 trump) + remaining deck (8 trump, 2 non-trump) = 12 cards
- Dealer keeps best 6 trump
- If 7+ are point cards → keeps all trump, kills non-point
- Same kill rules apply to dealer

### Current Implementation Status
**File**: `lib/pidro/game/discard.ex:350-392` (dealer_rob_pack/2)

**What exists**:
```elixir
# Line 355: Validates exactly 6 cards selected
:ok <- validate_six_cards(selected_cards)
```

**Gap**: Hardcoded to exactly 6 cards. No kill rule support.

**Missing**:
- Allow dealer to select >6 if 7+ point cards
- Dealer kill validation (spec lines 260-274)
- Track dealer_pool_size for analysis (spec line 109)

**Risk**: Dealer forced to select exactly 6 even if they have 7+ point cards

---

## Edge Case 4: Player with Excess Trump Must Kill Only Non-Point ❌ NOT IMPLEMENTED

### Spec Requirement (spec lines 40-48, 110-111)
- If player has >6 trump after redeal, MUST kill excess
- Can ONLY kill non-point trump (K, Q, 9, 8, 7, 6, 4, 3)
- Cannot kill point cards (A, J, 10, 5-right, 5-wrong, 2)
- Top killed card played on first trick

### Current Implementation Status
**Completely missing** - no kill mechanic exists

**Missing Functions Needed**:
```elixir
# In lib/pidro/game/discard.ex or new lib/pidro/game/kill.ex

@spec validate_kill([card()], suit()) :: :ok | {:error, error()}
def validate_kill(cards_to_kill, trump_suit)

@spec get_killable_cards([card()], suit()) :: [card()]
def get_killable_cards(hand, trump_suit)

@spec kill_cards(game_state(), position(), [card()]) :: {:ok, game_state()} | {:error, error()}
def kill_cards(state, position, cards_to_kill)
```

**Property tests needed** (spec lines 216-235):
- "when player kills cards, top card is played on first trick"
- "killed cards count toward player's 6-card hand for first trick"

**Risk**: Cannot handle valid game scenario where players have 7+ trump

---

## Edge Case 5: Verify Each Edge Case Is Handled ❌ NOT IMPLEMENTED

### Spec Requirement
Property-based tests to validate edge cases hold true across all game states

### Current Implementation Status
**File**: `test/properties/state_machine_properties_test.exs:540-600`

**What exists**: Basic team and player validation properties

**Missing Property Tests** (from spec):

1. **Line 127-155**: "player hands are at most 6 cards after re-deal, UNLESS they have excess trump"
   ```elixir
   # Current property is TOO STRICT (line 135 in spec)
   # Should allow hand_size > 6 if hand_size == trump_count
   ```

2. **Line 164-180**: "dealer combines remaining deck WITH own hand before selecting 6"
   ```elixir
   property "dealer sees their_hand ++ remaining_deck"
   assert dealer_after.selection_pool_size == available_to_dealer
   ```

3. **Line 186-209**: "dealer knows how many trump each player started with"
   ```elixir
   # Track cards_requested per player (public info)
   # Track dealer_pool_size (spec line 109)
   ```

4. **Line 241-254**: "dealer can have >6 cards if remaining deck has many trump"

**Missing Test File**: `test/properties/trump_discard_properties_test.exs`  
Referenced in masterplan but does not exist.

**Risk**: Edge cases silently broken without property test coverage

---

## Data Structure Gaps

### Spec Requirement (lines 80-102)
GameState must track:
```elixir
%{
  cards_requested: %{
    east: 3,   # Public: everyone deduces East had 3 trump
    south: 5,
    west: 0
  },
  dealer_pool: [cards],      # Hidden: dealer's hand + remaining deck
  dealer_pool_size: 8,       # For analysis
  killed_cards: %{
    west: [{:king, :hearts}] # West killed K♥, will play it first
  }
}
```

### Current Implementation
**File**: `lib/pidro/core/types.ex:1-100`

**What exists**: Basic GameState with players, deck, trump_suit, phase

**Missing fields**:
- `cards_requested :: %{position() => non_neg_integer()}`
- `dealer_pool_size :: non_neg_integer()`
- `killed_cards :: %{position() => [card()]}`

**Impact**: Cannot implement kill rules or track dealer advantage without these fields

---

## Validation Logic Gaps

### Error Handling Missing

**File**: `lib/pidro/game/errors.ex`

**Missing error types needed**:
```elixir
{:cannot_kill_point_card, card()}
{:must_kill_excess_trump, hand_size, max_allowed}
{:deck_exhausted, cards_needed, cards_available}
{:invalid_kill_selection, reason}
```

---

## Implementation Checklist Status

From spec lines 104-114:

- [x] Dealer combines hand + deck into single pool (line 361)
- [x] Dealer selects 6 from pool privately (line 355)
- [ ] Track cards_requested per player (public info) - **MISSING**
- [ ] Track dealer_pool_size (for analysis) - **MISSING**
- [ ] Kill validation: only allow non-point cards - **MISSING**
- [ ] Kill mechanic: top card auto-played on first trick - **MISSING**
- [ ] Allow >6 cards if all trump and can't kill point cards - **MISSING**
- [ ] Property test: dealer always sees >= 6 cards - **MISSING**
- [ ] Property test: killed cards are non-point or 7+ point cards - **MISSING**

**Score**: 2/9 implemented (22%)

---

## Recommended Implementation Order

### Phase 1: Data Structure (1-2 hours)
1. Add missing fields to GameState in `types.ex`
2. Add missing error types to `errors.ex`
3. Update state initialization

### Phase 2: Kill Validation Logic (2-3 hours)
1. Implement `get_killable_cards/2` helper
2. Implement `validate_kill/2` function
3. Implement `kill_cards/3` state transition
4. Add kill phase to state machine

### Phase 3: Edge Case Handling (2-3 hours)
1. Update `dealer_rob_pack/2` to allow >6 if needed
2. Add deck exhaustion validation
3. Track `cards_requested` during second_deal
4. Track `dealer_pool_size` during rob

### Phase 4: Property Tests (3-4 hours)
1. Create `trump_discard_properties_test.exs`
2. Implement all missing property tests from spec
3. Fix too-strict hand size property (spec line 135)

### Phase 5: First Trick Integration (1-2 hours)
1. Update `lib/pidro/game/play.ex` to handle killed cards
2. Auto-play top killed card on first trick
3. Test full flow end-to-end

**Total Estimated Effort**: 9-14 hours

---

## Critical Risks

1. **Production Data Loss**: If a player legitimately ends up with 7+ point cards, current code will error/crash
2. **Invalid Game States**: No validation prevents impossible scenarios (e.g., deck exhaustion)
3. **Rule Violations**: Players could keep >6 cards without proper kill mechanic
4. **No Test Coverage**: Edge cases silently broken without property tests

---

## Next Steps

1. **Immediate**: Add validation to prevent deck exhaustion in `second_deal/1`
2. **High Priority**: Implement kill rule data structures and validation
3. **Medium Priority**: Add property tests for edge cases
4. **Low Priority**: Track dealer advantage metrics (cards_requested, pool_size)

---

## References

- Spec: `specs/redeal.md` (lines 40-274)
- Implementation: `lib/pidro/game/discard.ex` (lines 1-473)
- Properties: `specs/game_properties.md` (lines 596-603)
- Types: `lib/pidro/core/types.ex`
- Card utils: `lib/pidro/core/card.ex` (point_value/2 exists)
