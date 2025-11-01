# Pidro Engine Implementation Masterplan

**Status**: Core Engine Complete - Full game playable in IEx
**Goal**: Complete Finnish Pidro game engine playable in IEx, wrappable in GenServer for Phoenix
**Strategy**: Pure functional core → event sourcing → performance → OTP wrapper
**Validation**: Property-based tests lock correctness at each phase

---

## PHASE 0: Project Scaffold ✅

**Priority**: CRITICAL | **Effort**: S | **Status**: ✅ COMPLETED

### Missing Dependencies

- [x] Add `stream_data ~> 1.0` for property-based testing
- [x] Add `dialyxir ~> 1.4` for type checking
- [x] Add `credo ~> 1.7` for code quality
- [x] Add `benchee ~> 1.0` for performance testing
- [x] Add `typed_struct ~> 0.3` for cleaner structs
- [x] Add `accessible ~> 0.3` for field access

### Directory Structure

- [x] Create `lib/pidro/core/` (types, card, deck, player, trick, team, gamestate)
- [x] Create `lib/pidro/game/` (engine, state_machine, bidding, dealing, trump, discard, play, scoring)
- [x] Create `lib/pidro/finnish/` (rules, scorer, engine)
- [x] Create `lib/pidro/notation/` (pgn encoding/decoding)
- [x] Create `lib/pidro/perf/` (binary, cache, hash)
- [x] Create `test/unit/` (unit tests)
- [x] Create `test/properties/` (property-based tests)
- [x] Create `test/support/generators.ex` (StreamData generators)

### Configuration

- [x] Add `config/config.exs` with variant: :finnish, cache_moves: true, enable_history: true
- [x] Add `config/test.exs` with cache_moves: false for deterministic tests

**Validation**: `mix deps.get && mix compile` succeeds

---

## PHASE 1: Core Types and Data Structures ✅

**Priority**: CRITICAL | **Effort**: S | **Status**: ✅ COMPLETED

### lib/pidro/core/types.ex

- [x] Define `@type suit :: :hearts | :diamonds | :clubs | :spades`
- [x] Define `@type rank :: 2..14` (2-10, J=11, Q=12, K=13, A=14)
- [x] Define `@type card :: {rank, suit}`
- [x] Define `@type position :: :north | :east | :south | :west`
- [x] Define `@type team :: :north_south | :east_west`
- [x] Define `@type phase` (9 phases: dealer_selection → complete)
- [x] Define `@type action` (all game actions)
- [x] Define `@type event` (all game events for event sourcing)
- [x] Define `@type game_state` with TypedStruct
- [x] All specs with `@spec` for Dialyzer

### lib/pidro/core/card.ex

- [x] `new(rank, suit) :: card` - create card
- [x] `is_trump?(card, trump_suit) :: boolean` - handles same-color 5 rule
- [x] `compare(card1, card2, trump_suit) :: :gt | :eq | :lt` - ranking with right/wrong 5
- [x] `point_value(card, trump_suit) :: 0..5` - A(1), J(1), 10(1), 5(5), wrong5(5), 2(1)
- [x] Helper: `same_color_suit(suit) :: suit` - hearts↔diamonds, clubs↔spades

### lib/pidro/core/deck.ex

- [x] `new() :: Deck.t` - create shuffled 52-card deck
- [x] `shuffle(deck) :: Deck.t` - shuffle deck
- [x] `deal_batch(deck, count) :: {[card], Deck.t}` - deal N cards
- [x] `draw(deck, count) :: {[card], Deck.t}` - draw N cards
- [x] `remaining(deck) :: non_neg_integer` - cards left

### lib/pidro/core/player.ex

- [x] Define Player struct: hand, position, team, eliminated?
- [x] `new(position, team) :: Player.t`
- [x] `add_cards(player, cards) :: Player.t`
- [x] `remove_card(player, card) :: Player.t`
- [x] `has_card?(player, card) :: boolean`
- [x] `trump_cards(player, trump_suit) :: [card]`

### lib/pidro/core/trick.ex

- [x] Define Trick struct: plays (list of {position, card}), leader
- [x] `new(leader) :: Trick.t`
- [x] `add_play(trick, position, card) :: Trick.t`
- [x] `winner(trick, trump_suit) :: position` - handles right/wrong 5 ranking
- [x] `points(trick, trump_suit) :: 0..14` - sum point values

### lib/pidro/core/gamestate.ex

- [x] Define GameState struct with all fields from spec
- [x] `new() :: GameState.t` - initial state in :dealer_selection phase
- [x] `update(state, key, value) :: GameState.t` - immutable update helper

### Unit Tests

- [x] `test/unit/card_test.exs` - all Card functions
- [x] `test/unit/deck_test.exs` - deck operations
- [x] `test/unit/player_test.exs` - player operations
- [x] `test/unit/trick_test.exs` - trick operations

### Property Tests (test/properties/card_properties_test.exs)

- [x] Property: "deck always contains exactly 52 cards"
- [x] Property: "each suit contains exactly 14 cards (including cross-color 5)"
- [x] Property: "5 of hearts is trump when hearts OR diamonds is trump"
- [x] Property: "5 of clubs is trump when clubs OR spades is trump"
- [x] Property: "trump ranking is always: A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2"
- [x] Property: "right pidro always beats wrong pidro"
- [x] Property: "card comparison is transitive"

**Validation**: `mix test && mix dialyzer` clean, all properties pass 100 runs

---

## PHASE 2: State Machine and Actions Skeleton ✅

**Priority**: CRITICAL | **Effort**: M | **Status**: ✅ COMPLETED

### lib/pidro/game/state_machine.ex

- [x] `valid_transition?(from_phase, to_phase) :: boolean`
- [x] `next_phase(current_phase, game_state) :: phase`
- [x] Guards for each phase transition

### lib/pidro/game/engine.ex (CORE API)

- [x] `apply_action(state, position, action) :: {:ok, GameState.t} | {:error, reason}`
- [x] `legal_actions(state, position) :: [action]`
- [x] Pattern match on `{phase, action}` pairs
- [x] Dispatch to phase-specific modules

### lib/pidro/game/errors.ex

- [x] Define error atoms: `:invalid_phase`, `:not_your_turn`, `:invalid_action`, etc.

### Property Tests (test/properties/state_machine_properties_test.exs)

- [x] Property: "game phases transition in correct order"
- [x] Property: "cannot bid after bidding phase complete"
- [x] Property: "cannot play card before playing phase"
- [x] Property: "game state is immutable - operations return new state"
- [x] Property: "exactly 4 players in every game"
- [x] Property: "players are in two teams of 2"
- [x] Property: "partners sit opposite each other"

**Validation**: State machine validates transitions, properties pass

---

## PHASE 3: Dealer Selection and Initial Deal ✅

**Priority**: CRITICAL | **Effort**: S→M | **Status**: ✅ COMPLETED

### lib/pidro/game/dealing.ex

- [x] `select_dealer(state) :: GameState.t` - implement cutting logic
- [x] `rotate_dealer(state) :: GameState.t` - rotate to next position
- [x] `deal_initial(state) :: GameState.t` - 9 cards each in 3-card batches
- [x] Set `current_turn` to left of dealer after deal

### Integration into Engine

- [x] Handle `:dealer_selection` phase actions in `apply_action/2`
- [x] Handle `:dealing` phase in `apply_action/2`
- [x] Update `legal_actions/2` for both phases

### Property Tests (test/properties/dealing_properties_test.exs)

- [x] Property: "initial deal gives exactly 9 cards to each player"
- [x] Property: "initial deal distributes cards in batches of 3"
- [x] Property: "after initial deal, 16 cards remain in deck"

**Validation**: Can deal a hand in IEx, properties pass

---

## PHASE 4: Bidding System ✅

**Priority**: CRITICAL | **Effort**: M | **Status**: ✅ COMPLETED

### lib/pidro/game/bidding.ex

- [x] `validate_bid(state, position, amount) :: :ok | {:error, reason}`
- [x] `apply_bid(state, position, amount) :: GameState.t`
- [x] `apply_pass(state, position) :: GameState.t`
- [x] `all_passed?(state) :: boolean` - check if dealer must bid 6
- [x] `bidding_complete?(state) :: boolean` - dealer's turn done
- [x] Handle bid tie at 14 (last 14 wins)

### Integration into Engine

- [x] Handle `:bidding` phase in `apply_action/2`
- [x] Update `legal_actions/2` to return valid bids or :pass

### Property Tests (test/properties/bidding_properties_test.exs)

- [x] Property: "bid must be between 6 and 14 inclusive"
- [x] Property: "bid must be higher than current bid (except pass)"
- [x] Property: "if all players pass, dealer must bid 6"
- [x] Property: "exactly one round of bidding occurs"
- [x] Property: "dealer is always last to bid"
- [x] Property: "bidding 14 can be topped by another bid of 14"

**Validation**: Bidding works end-to-end in IEx, properties pass

---

## PHASE 5: Trump Declaration and Discard/Re-deal ✅

**Priority**: CRITICAL | **Effort**: M | **Status**: ✅ COMPLETED

### lib/pidro/game/trump.ex

- [x] `declare_trump(state, suit) :: GameState.t`
- [x] `categorize_hand(hand, trump_suit) :: {trump_cards, non_trump_cards}`
- [x] Handle wrong 5 as trump card

### lib/pidro/game/discard.ex

- [x] `discard_non_trumps(state) :: GameState.t` - auto-discard for all players
- [x] `validate_discard(cards, trump_suit) :: :ok | {:error, :point_card}`
- [x] `second_deal(state) :: GameState.t` - deal to 6 cards each
- [x] `dealer_rob_pack(state) :: GameState.t` - dealer gets remaining, selects 6
- [x] Handle edge: players with >6 trump already

### Integration into Engine

- [x] Handle `:declaring` phase in `apply_action/2`
- [x] Handle `:discarding` phase
- [x] Handle `:second_deal` phase

### Property Tests (test/properties/trump_discard_properties_test.exs)

- [x] Property: "after trump selection, all non-trump cards are discarded (except wrong 5)"
- [x] Property: "after re-deal, each player has exactly 6 cards"
- [x] Property: "dealer takes all remaining cards and selects 6"
- [x] Property: "if player has >6 trump after re-deal, must discard non-point cards"
- [x] Property: "cannot discard point cards when reducing hand to 6"
- [x] Property: "dealer gets no cards if all players keep 6 trump cards"

**Validation**: Trump declaration and discard works, properties pass

---

## PHASE 6: Play Engine (Trick-Taking) ✅

**Priority**: CRITICAL | **Effort**: M→L | **Status**: ✅ COMPLETED

### lib/pidro/game/play.ex

- [x] `play_card(state, position, card) :: GameState.t`
- [x] `validate_play(state, position, card) :: :ok | {:error, reason}`
- [x] Only trump cards can be played (Finnish rule)
- [x] `complete_trick(state) :: GameState.t` - determine winner
- [x] `eliminate_player(state, position) :: GameState.t` - mark "cold" when out of trumps
- [x] `reveal_non_trumps(state, position) :: GameState.t` - going cold reveals

### lib/pidro/finnish/rules.ex

- [x] Implement Finnish-specific rules
- [x] Only trumps are valid plays
- [x] Player elimination when out of trumps
- [x] "Going cold" reveals remaining non-trump cards

### Integration into Engine

- [x] Handle `:playing` phase in `apply_action/2`
- [x] Update `legal_actions/2` to return only playable trump cards
- [x] Auto-advance to scoring when all tricks complete or one team has all remaining

### Property Tests (test/properties/trick_properties_test.exs)

- [x] Property: "only trump cards are valid plays"
- [x] Property: "highest trump card wins the trick (except for 2)"
- [x] Property: "player who wins trick leads next trick"
- [x] Property: "when player has no trump, they go 'cold' and lay down remaining cards"
- [x] Property: "cold player does not participate in remaining tricks"

**Validation**: Full trick-taking works, properties pass

---

## PHASE 7: Scoring System and Game Progression ✅

**Priority**: CRITICAL | **Effort**: M | **Status**: ✅ COMPLETED

### lib/pidro/finnish/scorer.ex

- [x] `score_trick(trick, trump_suit) :: {team, points}`
- [x] Handle special 2 rule: player keeps 1 point
- [x] `aggregate_team_scores(state) :: %{team => points}`
- [x] `apply_bid_result(state) :: GameState.t`
  - [x] Bidding team made bid: score points taken
  - [x] Bidding team failed: lose bid amount (can go negative)
  - [x] Defending team: always keep points taken
- [x] `game_over?(state) :: boolean` - check if team reached 62
- [x] `determine_winner(state) :: team | nil`
- [x] If both at 62, bidding team wins

### Integration into Engine

- [x] Handle `:scoring` phase in `apply_action/2`
- [x] Auto-advance to next hand or :complete

### Property Tests (test/properties/scoring_properties_test.exs)

- [x] Property: "total points in a suit always equals 14"
- [x] Property: "point distribution is exactly: A(1) + J(1) + 10(1) + Right5(5) + Wrong5(5) + 2(1)"
- [x] Property: "player with 2 of trump always keeps 1 point"
- [x] Property: "highest card in trick wins all points in trick (except 2)"
- [x] Property: "if bidding team makes bid, they score points taken"
- [x] Property: "if bidding team fails bid, they lose bid amount (can go negative)"
- [x] Property: "defending team always keeps points they took"
- [x] Property: "sum of points taken by both teams equals 14"
- [x] Property: "game ends when one team reaches 62 points"
- [x] Property: "if both teams reach 62, bidding team wins"

**Validation**: Full game can be played start to finish, properties pass

---

## PHASE 8: Event Sourcing and Notation ✅

**Priority**: HIGH | **Effort**: M | **Status**: ❌ NOT STARTED

### lib/pidro/core/events.ex

- [ ] Define all event types from spec
- [ ] `apply_event(state, event) :: GameState.t`
- [ ] Update `apply_action/2` to record events

### lib/pidro/game/replay.ex

- [ ] `replay(events) :: GameState.t`
- [ ] `undo(state) :: {:ok, GameState.t} | {:error, :no_history}`

### lib/pidro/notation.ex

- [ ] `encode(state) :: String.t` - PGN-like notation
- [ ] `decode(pgn) :: {:ok, GameState.t} | {:error, reason}`

### Property Tests (test/properties/event_sourcing_properties_test.exs)

- [ ] Property: "replay from events produces identical state"
- [ ] Property: "PGN round-trip preserves game state"
- [ ] Property: "game state serialization is deterministic"

**Validation**: Events work, replay/undo work, notation round-trips

---

## PHASE 9: Performance Layer (OPTIONAL INITIALLY) ⚠️

**Priority**: MEDIUM | **Effort**: L | **Status**: ❌ NOT STARTED

### lib/pidro/core/binary.ex

- [ ] `encode_card(card) :: binary`
- [ ] `encode_hand([card]) :: binary`
- [ ] `to_binary(state) :: binary`
- [ ] `from_binary(binary) :: {:ok, GameState.t}`

### lib/pidro/perf.ex

- [ ] `hash_state(state) :: integer`
- [ ] `states_equal?(state1, state2) :: boolean`

### lib/pidro/move_cache.ex

- [ ] GenServer for ETS cache
- [ ] `get_or_compute(state, position) :: [action]`
- [ ] `clear_cache() :: :ok`

### Benchmarking

- [ ] Create `bench/pidro_benchmark.exs`
- [ ] Benchmark `apply_action`, `legal_actions`, `to_binary`, `score_hand`

### Property Tests (test/properties/performance_properties_test.exs)

- [ ] Property: "game operations complete in reasonable time (<10ms)"

**Validation**: Operations < 1ms, full game simulation < 100ms

---

## PHASE 10: Developer UX and Documentation ✅

**Priority**: HIGH | **Effort**: S | **Status**: ✅ COMPLETED

### IEx Helpers (lib/pidro/iex.ex)

- [x] `pretty_print(state)` - visualize game state
- [x] `show_legal_actions(state, position)` - display options
- [x] `step(state, action)` - apply and pretty print
- [x] `demo_game()` - run sample game

### Documentation

- [x] ExDoc setup in mix.exs
- [x] `@moduledoc` for all modules
- [x] `@doc` for all public functions
- [x] Usage examples in README
- [x] Performance guide

**Validation**: `mix docs`, code coverage, Credo clean

---

## PHASE 11: OTP Integration ✅

**Priority**: MEDIUM | **Effort**: M | **Status**: ❌ NOT STARTED

### lib/pidro/server.ex

- [ ] GenServer wrapping pure core
- [ ] `start_link(opts) :: {:ok, pid}`
- [ ] `handle_call({:apply_action, position, action}, _, state)`
- [ ] `handle_call({:legal_actions, position}, _, state)`
- [ ] `handle_call(:get_state, _, state)`
- [ ] Optional: telemetry events

### lib/pidro/supervisor.ex

- [ ] Supervision tree
- [ ] Start MoveCache ETS
- [ ] Optional: Registry for game processes

**Validation**: Can start supervised game server, API works

---

## PHASE 12: Phoenix Integration (FUTURE) 🔮

**Priority**: LOW | **Effort**: M→L | **Status**: ❌ NOT STARTED

### Phoenix/LiveView Integration

- [ ] LiveView connects to Pidro.Server via Registry
- [ ] Subscribe to game events (PubSub)
- [ ] Render game state
- [ ] Handle player actions
- [ ] Presence for player connections

**Validation**: Playable in browser

---

## CRITICAL PATH TO "PLAYABLE IN IEX"

**Priority Order** (Minimal viable game):

1. ✅ Phase 0: Scaffold (deps, directories)
2. ✅ Phase 1: Core types (Card, Deck, Player, Trick, GameState)
3. ✅ Phase 2: State machine skeleton (Engine API)
4. ✅ Phase 3: Dealing (initial 9 cards)
5. ✅ Phase 4: Bidding (single round, dealer forced bid)
6. ✅ Phase 5: Trump + Discard (wrong 5 rule, second deal)
7. ✅ Phase 6: Play (trick-taking, elimination)
8. ✅ Phase 7: Scoring (hand scoring, game end)
9. ✅ Phase 10: IEx helpers (pretty print, demo)

**Optional Extensions**:

- Phase 8: Event sourcing (for undo/replay)
- Phase 9: Performance (if needed)
- Phase 11: GenServer (for Phoenix)
- Phase 12: Phoenix UI

---

## DEFINITION OF DONE (Per Phase)

- [ ] All code has `@spec` for Dialyzer
- [ ] All public functions have `@doc`
- [ ] Related properties from `game_properties.md` pass (100 runs)
- [ ] `mix test` passes
- [ ] `mix dialyzer` clean
- [ ] `mix credo --strict` passes
- [ ] No TODOs left in code

---

## KNOWN GAPS & RISKS

### Missing Implementations

- **Everything** - only `PidroEngine.hello/0` exists
- 40+ modules to create
- 50+ property tests to write
- Full state machine with 9 phases
- Complex Finnish rules (wrong 5, dealer robbing, going cold)

### Technical Risks

- Wrong 5 rule complexity (same-color suit trump)
- Dealer edge cases (robbing pack when all keep 6 trump)
- Elimination logic (going cold mid-hand)
- Negative scoring for failed bids
- Tie-breaking at bid 14

### Property Test Risks

- Generator complexity for valid game states
- Ensuring generators only produce legal actions
- State explosion in full game simulations

### Mitigation

- Focus properties on invariants, not procedures
- Use `legal_actions/2` to constrain generators
- Start simple, expand coverage incrementally
- Keep OTP/Phoenix wrapper thin to avoid coupling

---

## NEXT IMMEDIATE ACTIONS

**Completed (Phases 0-7, 10)**:
- Core game engine fully functional
- Full Finnish Pidro rules implemented
- Playable in IEx with helper functions
- Comprehensive property-based test coverage

**Current Focus (Phase 8)**:
1. Implement event sourcing system for game replay
2. Add undo/redo functionality
3. Create PGN-like notation for game serialization
4. Property tests for event sourcing invariants

**Remaining Work**:
- Phase 8: Event sourcing and notation (IN PROGRESS)
- Phase 9: Performance optimizations (OPTIONAL)
- Phase 11: OTP/GenServer wrapper for Phoenix integration
- Phase 12: Phoenix LiveView UI (FUTURE)

---

**Last Updated**: 2025-11-01
**Current Phase**: Phase 8 (Event Sourcing) - In progress
**Completion**: 8/12 phases (67%)
