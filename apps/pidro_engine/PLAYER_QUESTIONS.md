# Finnish Pidro - Player Experience Questions

This document collects questions about gameplay experience to help inform design decisions for the mobile game implementation.

---

## Question 1: Dealer Rob Automation (Finnish Variant Only)

### Background

In Finnish Pidro, after trump is declared and the second deal completes, the dealer has a special privilege called "robbing the pack":

1. **Dealer combines** their current hand with all remaining deck cards into a pool
2. **Dealer views** this pool (could be 6-15+ cards depending on what non-dealers requested)
3. **Dealer selects** the best 6 cards from this pool
4. **Unselected cards** go to the discard pile face-down

This is a **strategic advantage** - the dealer sees more cards than anyone else and can optimize their hand.

### The Trade-off

**Manual Selection (Current Implementation)**
- ✅ Full player control over card selection
- ✅ Strategic decisions (e.g., keeping trump vs. point cards)
- ✅ Matches real-life gameplay exactly
- ❌ Slows down game flow (extra UI step)
- ❌ May frustrate casual players who just want "best 6"
- ❌ Mobile UI needs extra screen/modal for card selection

**Automatic Selection (Proposed Default)**
- ✅ Faster gameplay (no waiting for dealer decision)
- ✅ Simpler mobile UX (one less screen)
- ✅ AI can pick "best 6" based on trump strength + point values
- ❌ Removes strategic choice from dealer
- ❌ AI might not match player's preferred strategy
- ❌ Less educational for new players learning optimal play

### Proposed Implementation

**Option A: Auto by Default, Manual Optional**
```
Settings > Dealer Rob: [Auto] [Manual]
Default: Auto (AI selects best 6 cards)
Advanced: Manual (player selects 6 cards from pool)
```

**Option B: Manual by Default, Auto Optional**
```
During dealer rob screen:
[View Cards and Select 6] [Auto-Select Best Cards]
Default: Manual selection required
Quick option: Auto button for fast play
```

**Option C: Difficulty-Based**
```
Easy Mode: Dealer rob always automatic
Normal Mode: Manual selection by default, auto button available
Hard Mode: Manual selection only (no auto)
```

### Questions for Players

1. **How often would you want to manually select cards as dealer?**
   - [ ] Every time (I want full control)
   - [ ] Sometimes (depends on game situation)
   - [ ] Rarely (only when learning)
   - [ ] Never (always auto-select)

2. **What should be the DEFAULT behavior in a mobile game?**
   - [ ] Auto-select (faster, simpler)
   - [ ] Manual select (more strategic)
   - [ ] Ask on first game, remember preference
   - [ ] Tie to difficulty setting

3. **If auto-select is available, what strategy should it use?**
   - [ ] Maximize point cards (prioritize A, J, 10, 5s, 2)
   - [ ] Maximize trump strength (prioritize high rank + points)
   - [ ] Balanced (mix of high cards and points)
   - [ ] Let me configure the strategy in settings

4. **How important is the dealer rob decision to your enjoyment?**
   - [ ] Critical - it's a key strategic moment
   - [ ] Important - I want to think about it sometimes
   - [ ] Minor - I'd rather play tricks faster
   - [ ] Not important - automate it

5. **For teaching new players, which approach is better?**
   - [ ] Manual (shows them the pool, helps learn)
   - [ ] Auto with explanation (faster but still educational)
   - [ ] Auto only (avoid overwhelming beginners)

### Additional Considerations

**Technical Notes:**
- The game engine supports both manual and automatic dealer rob
- Current IEX demo uses manual selection: `Engine.apply_action(state, dealer, {:dealer_rob_pack, selected_cards})`
- Automatic selection would need an AI helper: `DealerRob.select_best_cards(pool, trump_suit)` 
- Settings can be per-player or per-game

**Related Mechanics:**
- This question applies **only to Finnish variant** (other Pidro variants don't have dealer rob)
- Kill rule (discarding excess trump) could also be automated, but that's a separate question
- Bidding automation is NOT recommended (core strategic choice)

---

## How to Contribute

Please share your thoughts by:

1. **GitHub Discussions**: [Link TBD]
2. **Community Discord**: [Link TBD]
3. **Email**: [Contact TBD]
4. **Reddit Thread**: [Link TBD]

Include:
- Your experience level with Pidro (beginner/intermediate/expert)
- Whether you play mostly in-person or digitally
- Your preference and reasoning

---

## Decision Timeline

- **Feedback Collection**: 2-3 weeks
- **Design Decision**: Based on community consensus
- **Implementation**: Shortly after decision
- **Testing**: Beta release to validate UX

---

## Future Questions

Additional gameplay questions will be added here as they arise:

- [ ] Kill rule automation (when player has >6 trump)
- [ ] Trick-taking speed (auto-play vs. manual confirm)
- [ ] Animation preferences (realistic vs. fast)
- [ ] Sound effects and notifications
- [ ] Spectator mode features

---

**Last Updated**: 2025-11-02  
**Status**: Open for feedback
