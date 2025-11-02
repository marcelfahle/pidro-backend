# Pidro LiveView Development Interface

## Technical Specification

**Version:** 1.0  
**Author:** Development Team  
**Date:** November 2025  
**Status:** Draft

---

## 1. Overview

### 1.1 Purpose

The LiveView Development Interface provides a web-based testing and debugging environment for the Pidro multiplayer game server. It enables rapid iteration on game logic, AI behavior, and multiplayer mechanics without requiring multiple clients or complex API testing tools.

### 1.2 Goals

- Enable single-developer testing of 4-player game scenarios
- Provide real-time game state visualization and debugging
- Support bot player integration for automated testing
- Facilitate rapid prototyping of game mechanics
- Reduce development cycle time from hours to minutes

### 1.3 Target Users

- Backend developers testing game logic
- Game designers iterating on rules
- QA engineers debugging multiplayer scenarios
- Solo developers needing to simulate full games

### 1.4 Access Control

- **Environment:** Development only (`Mix.env() == :dev`)
- **Route Prefix:** `/dev`
- **Authentication:** Optional dev authentication (configurable)
- **Production:** Completely disabled

---

## 2. Core Functional Requirements

### 2.1 Game Management

#### FR-1: Game Creation

**Description:** Create new game instances with configurable player setup.

**Acceptance Criteria:**

- Create game with 4 human players (waiting for joins)
- Create game with 1 human + 3 bot players (instant start)
- Create game with 4 bots (fully automated, observable)
- Specify bot difficulty level (random, basic, smart)
- Auto-generate unique game IDs
- Set custom game names for easy identification

**UI Elements:**

```
[New Game (4 Players)]  [New Game (1P + 3 Bots)]  [New Game (4 Bots)]
Bot Difficulty: [Random ▼] [Basic] [Smart]
Game Name: [________________]
```

#### FR-2: Game Discovery

**Description:** List and filter active game sessions.

**Acceptance Criteria:**

- Display all active games in table format
- Show game ID, name, phase, player count, created timestamp
- Filter by phase (bidding, playing, scoring, finished)
- Sort by creation date (newest first)
- Click game to open detailed view
- Display game count badge

**Data Displayed:**
| Game ID | Name | Phase | Players | Created | Status |
|---------|------|-------|---------|---------|--------|
| abc123 | Test Game 1 | Bidding | 4/4 | 2 min ago | 🟢 Active |

#### FR-3: Game Deletion

**Description:** Clean up test games.

**Acceptance Criteria:**

- Delete individual games
- Bulk delete all finished games
- Confirmation dialog for safety
- Automatic cleanup of bot processes

---

### 2.2 Player Impersonation

#### FR-4: Position Switching

**Description:** Switch between player positions within a game.

**Acceptance Criteria:**

- Four clearly labeled buttons: North, South, East, West
- Active position highlighted visually
- Switch takes effect immediately
- Display current position's hand and available actions
- Show position-specific game state (what this player can see)

**UI Elements:**

```
Play as: [North (active)] [South] [East] [West]
Currently viewing: North's perspective
Cards in hand: [A♠] [K♠] [Q♠] [10♠] [5♠] [2♠]
```

#### FR-5: Multi-View Mode

**Description:** View multiple player perspectives simultaneously.

**Acceptance Criteria:**

- Toggle "God Mode" to see all hands
- Split screen showing 2-4 player views
- Clearly indicate which view is active for actions
- Useful for debugging visibility rules

---

### 2.3 Game State Visualization

#### FR-6: Current State Display

**Description:** Real-time visualization of complete game state.

**Acceptance Criteria:**

- Display current phase (Dealing, Bidding, Trump Selection, etc.)
- Show active player indicator
- Display trump suit (when declared)
- Show bid history and current high bid
- Display team scores (North/South vs East/West)
- Show trick pile and points won so far
- Indicate which players have "gone cold"

**Layout:**

```
┌─────────────────────────────────────┐
│ Phase: Bidding                      │
│ Active Player: East                 │
│ Trump: Not yet declared             │
│ High Bid: 10 (North)                │
│ Team Scores: N/S: 18 | E/W: 24      │
└─────────────────────────────────────┘
```

#### FR-7: Event Log

**Description:** Scrollable history of all game events.

**Acceptance Criteria:**

- Display events in chronological order (newest first)
- Include timestamp for each event
- Color-code by event type (deal, bid, play, score)
- Show player who triggered the event
- Format: `[10:23:45] North bid 8`
- Exportable as JSON or text
- Clear log button

**Example:**

```
[10:24:01] North played A♠
[10:23:58] West played 5♠
[10:23:55] South played K♠
[10:23:52] East played 10♠
[10:23:45] Round started by North
[10:23:40] Trump declared: Spades
```

#### FR-8: Raw State Inspector

**Description:** Expandable technical view of GameState struct.

**Acceptance Criteria:**

- Collapsible section showing raw Elixir struct
- Pretty-printed with syntax highlighting
- Copy to clipboard button
- Useful for debugging edge cases
- Update in real-time as game progresses

---

### 2.4 Game Interaction

#### FR-9: Action Execution

**Description:** Execute legal moves for the current player.

**Acceptance Criteria:**

- Display all legal actions as buttons
- Disable illegal actions (grayed out)
- Show action descriptions (e.g., "Bid 8", "Play A♠", "Pass")
- Execute action on click
- Show loading state during action processing
- Display success/error feedback
- Update game state immediately after action

**UI Elements:**

```
Available Actions for North:
[Bid 6] [Bid 7] [Bid 8] [Bid 9] [Pass]
```

#### FR-10: Quick Actions

**Description:** Shortcuts for common testing scenarios.

**Acceptance Criteria:**

- "Deal Next Hand" - skip to next deal
- "Complete Current Hand" - auto-play to end of hand
- "Auto-bid" - have all players auto-bid sensibly
- "Fast Forward" - play game at 5x speed with bots
- "Undo Last Action" - revert to previous state (if event sourcing supports)

**UI Elements:**

```
Quick Actions:
[⏭ Skip to Playing] [⚡ Auto-complete Hand] [↩ Undo] [⏩ Fast Forward]
```

---

### 2.5 Bot Management

#### FR-11: Bot Configuration

**Description:** Control bot player behavior per game.

**Acceptance Criteria:**

- Set bot difficulty per position (Random/Basic/Smart)
- Enable/disable bots for specific positions
- Adjust bot thinking time (instant to 3 seconds)
- Override bot decision for next move (manual control)
- View bot's decision-making reasoning (debug mode)

**UI Elements:**

```
Bot Players:
North: [Human]
South: [Bot ▼] Difficulty: [Basic ▼] Delay: [1s ▼]
East:  [Bot ▼] Difficulty: [Smart ▼] Delay: [2s ▼]
West:  [Bot ▼] Difficulty: [Random ▼] Delay: [0s ▼]

[Apply Changes]
```

#### FR-12: Bot Observation

**Description:** Monitor bot decision-making in real-time.

**Acceptance Criteria:**

- Show bot's current evaluation of game state
- Display legal actions with bot's internal scoring
- Highlight chosen action before execution
- Log bot reasoning: "Bot chose 'Bid 8' because: has A♠, K♠, 5♠"
- Useful for debugging bot strategies

---

### 2.6 Game Analysis

#### FR-13: Hand Replay

**Description:** Step through completed hands move-by-move.

**Acceptance Criteria:**

- Select any finished hand from game history
- Navigate: First, Previous, Next, Last
- Scrub through moves with slider
- Pause on interesting states
- View game state at each step
- Compare different lines of play (if event sourcing allows branching)

#### FR-14: Statistics View

**Description:** Aggregate game statistics for testing balance.

**Acceptance Criteria:**

- Win rate by position (North/South/East/West)
- Average bid values
- Most common trump suits
- Average points per hand
- Bot performance metrics
- Based on last N games (configurable)

---

## 3. User Interface Layout

### 3.1 Main Layout Structure

```
┌─────────────────────────────────────────────────────────┐
│  Pidro Development Interface                    [Logout] │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌─────────────────┐  ┌───────────────────────────────┐ │
│  │ Game Management │  │ Active Game: Test Game #1     │ │
│  │                 │  │                               │ │
│  │ [New Game]      │  │ ┌─────────────────────────┐   │ │
│  │ [Load Game]     │  │ │ Game State              │   │ │
│  │ [Delete All]    │  │ │                         │   │ │
│  │                 │  │ │ Phase: Bidding          │   │ │
│  │ Active Games:   │  │ │ Active: North           │   │ │
│  │ • Test Game #1  │  │ │ Trump: --               │   │ │
│  │ • Bot Game #2   │  │ └─────────────────────────┘   │ │
│  │                 │  │                               │ │
│  └─────────────────┘  │ ┌─────────────────────────┐   │ │
│                        │ │ Player Switcher         │   │ │
│                        │ │ [North] [South]         │   │ │
│                        │ │ [East]  [West]          │   │ │
│                        │ └─────────────────────────┘   │ │
│                        │                               │ │
│                        │ ┌─────────────────────────┐   │ │
│                        │ │ Available Actions       │   │ │
│                        │ │ [Bid 6] [Bid 7] [Pass]  │   │ │
│                        │ └─────────────────────────┘   │ │
│                        │                               │ │
│                        │ ┌─────────────────────────┐   │ │
│                        │ │ Event Log               │   │ │
│                        │ │ [10:24] North bid 7     │   │ │
│                        │ │ [10:23] West passed     │   │ │
│                        │ └─────────────────────────┘   │ │
│                        └───────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Page Structure

#### Page 1: Game List (`/dev/games`)

- List of all active games
- New game creation buttons
- Quick filters and search

#### Page 2: Game Detail (`/dev/games/:id`)

- Full game state visualization
- Player impersonation
- Action execution
- Event log
- Bot controls

#### Page 3: Analytics (`/dev/analytics`)

- Aggregate statistics
- Bot performance metrics
- Game balance analysis

---

## 4. Technical Implementation

### 4.1 Technology Stack

**Frontend:**

- Phoenix LiveView (real-time updates)
- Tailwind CSS (styling)
- Alpine.js (optional, for enhanced interactions)
- Heroicons (UI icons)

**Backend:**

- Phoenix PubSub (state broadcasting)
- GenServer (game state management)
- ETS (bot process tracking)

### 4.2 Key Components

```elixir
# Primary LiveView modules
PidroWeb.Dev.GameListLive      # Game discovery and creation
PidroWeb.Dev.GameDetailLive    # Main game interface
PidroWeb.Dev.AnalyticsLive     # Statistics dashboard

# Supporting modules
Pidro.Dev.GameHelpers          # Quick action helpers
Pidro.Dev.BotManager           # Bot lifecycle management
Pidro.Dev.Recorder             # Game recording for analytics
```

### 4.3 Real-Time Updates

**Strategy:** Phoenix PubSub with topic per game

```elixir
# Subscribe to game updates
Phoenix.PubSub.subscribe(Pidro.PubSub, "game:#{game_id}")

# Broadcast state changes
Phoenix.PubSub.broadcast(
  Pidro.PubSub,
  "game:#{game_id}",
  {:game_updated, new_state}
)

# LiveView receives updates automatically
def handle_info({:game_updated, new_state}, socket) do
  {:noreply, assign(socket, :game_state, new_state)}
end
```

### 4.4 Bot Integration

**Bot Process Management:**

```elixir
# Start bot for a position
{:ok, bot_pid} = Pidro.BotPlayer.start_link(
  game_id: "abc123",
  position: :north,
  difficulty: :basic,
  delay_ms: 1000
)

# Bot subscribes to game events
# When it's bot's turn, automatically makes move
# Can be paused/resumed/replaced with human
```

---

## 5. Implementation Phases

### Phase 1: Core Infrastructure (2-3 days)

- [ ] Basic LiveView routing under `/dev`
- [ ] Game list page with creation
- [ ] Game detail page with state display
- [ ] Player position switching
- [ ] Action execution buttons

### Phase 2: Bot Integration (1-2 days)

- [ ] Simple random bot implementation
- [ ] Bot process management
- [ ] Bot configuration UI
- [ ] Auto-play with bots

### Phase 3: Enhanced Debugging (1-2 days)

- [ ] Event log with filtering
- [ ] Raw state inspector
- [ ] Quick actions (skip, undo, etc.)
- [ ] Multi-view mode

### Phase 4: Analysis & Polish (1-2 days)

- [ ] Hand replay functionality
- [ ] Statistics dashboard
- [ ] Bot reasoning display
- [ ] UI polish and styling

---

## 6. Success Metrics

**Quantitative:**

- Reduce test iteration time from 30min → 5min
- Enable testing of complete game in < 2 minutes
- Support simultaneous observation of 5+ games

**Qualitative:**

- Developer can test full game without leaving browser
- Easy to reproduce specific game states
- Bot behavior is observable and debuggable
- Interface is intuitive without documentation

---

## 7. Future Enhancements

**Nice-to-have features for later iterations:**

- Visual card table representation (drag-and-drop)
- Game state diffing between turns
- Snapshot save/restore for specific states
- Load testing tools (spawn 100 games)
- Integration test recording (export to test suite)
- Spectator mode for real production games
- Time-travel debugging (event sourcing replay)

---

## 8. Non-Functional Requirements

### Performance

- Page load: < 1 second
- Action execution: < 200ms
- Real-time updates: < 100ms latency
- Support 10+ simultaneous dev sessions

### Security

- No production deployment (build-time check)
- Optional dev-only authentication
- Rate limiting on game creation
- Resource cleanup on session end

### Accessibility

- Keyboard navigation support
- Screen reader friendly labels
- High contrast mode option
- Responsive design (works on tablets)

---

## 9. Open Questions

1. Should we support saving/loading game snapshots for regression testing?
2. Do we need integration with the existing admin panel, or keep separate?
3. Should event log support real-time filtering/search?
4. Do we want video recording of game sessions for bug reports?
5. Should bots be configurable with custom strategies (hot-reload code)?

---

## 10. Appendix

### A. Related Documents

- `README.md` - Pidro Engine documentation
- `API_DOCUMENTATION.md` - REST/WebSocket API spec
- Finnish Pidro Rules documents

### B. Example User Flows

**Flow 1: Test New Bidding Logic**

1. Developer opens `/dev/games`
2. Clicks "New Game (1P + 3 Bots)"
3. Selects "Basic" difficulty
4. Game starts immediately in bidding phase
5. Developer plays as North, observes bot bids
6. Tests edge case: bids 14
7. Watches bots complete hand
8. Reviews event log to verify behavior
9. Time elapsed: 3 minutes

**Flow 2: Debug Scoring Bug**

1. Developer loads existing game with issue
2. Switches to "God Mode" to see all hands
3. Steps through replay move-by-move
4. Identifies the trick where scoring went wrong
5. Copies raw game state to clipboard
6. Creates test case in test suite
7. Time elapsed: 5 minutes

**Flow 3: Balance Testing**

1. Developer creates 20 bot-only games
2. Sets fast-forward mode (no delays)
3. Games complete in 2 minutes
4. Opens analytics dashboard
5. Reviews win rates by position
6. Identifies North wins 60% (imbalanced)
7. Adjusts dealer rotation logic
8. Re-runs batch test
9. Time elapsed: 10 minutes

---

**Document Status:** Ready for Review  
**Next Steps:** Technical design review → Implementation sprint planning
