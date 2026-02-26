# Dev Panel Overhaul — Brainstorm

**Date:** 2026-02-09
**Status:** Ready for planning

---

## What We're Building

A unified, powerful dev/admin panel for Pidro — a single `/dev/` area (protected by basic auth) that gives an admin full control over the game system. Drop all duplicate `/admin/` views. The panel should feel like a game master's control room: see everything, control everything, jump into any game.

### Core Capabilities

1. **Room Dashboard** — See all rooms in the system at a glance (status, players, phase, scores). Filter, sort, search.
2. **Quick Room Creation** — One-click presets ("4 bots", "1 human + 3 bots", "2v2", "empty room") plus an advanced seat configurator where you assign each of the 4 seats individually.
3. **Jump Into Any Room** — Click a room to enter a tabbed game detail view with full god-mode powers.
4. **God-Mode Game Control** — See all 4 hands, execute actions as any player, take a seat yourself, control bots, undo moves, pause/resume.
5. **Rich Visual Board** — Reuse the existing `CardComponents.card_table` (which is already good) as the primary view, not raw JSON tables.
6. **Analytics** — Server stats, room metrics, system info. Clean up the existing AnalyticsLive.

---

## Current State Assessment

### What's Good
- **CardComponents** (`card_components.ex`, 1159 lines) — Fully-functional visual card game UI with table layout, 4 positions, trick display, bidding/trump/hand-selection panels, god mode toggle. This is production-quality.
- **RoomManager** — Solid GenServer with proper indexing, spectator support, PubSub broadcasts.
- **BotManager** — Proper DynamicSupervisor + ETS architecture with pause/resume.
- **GameAdapter** — Clean bridge to engine with undo support via event sourcing.
- **ReplayController** — Event history scrubbing works.
- **GameListLive** — Room list with filtering, stats, creation form. Functional but needs polish.

### What's Messy
- **GameDetailLive** (600+ lines) — Does too much in one file: game state inspection, bot control, seat management, action execution, event replay. Needs to be split into tabs.
- **Duplicate views** — `/admin/stats` = `/dev/analytics`, `/admin/lobby` ≈ `/dev/games`, `/admin/games/:code` ≈ `/dev/games/:code` but read-only. Wasteful.
- **Bot-seat conflicts** — BotManager and RoomManager manage positions independently. Creating a game with a human host + 4 bots can conflict (host occupies north, but BotManager tries to fill north too).
- **No atomic room+bot creation** — Game creation and bot startup are separate calls. If bots fail, you get an orphaned empty room.
- **"dev_host" hardcoding** — Uses placeholder string as user ID; doesn't integrate with real user lookups cleanly.
- **Analytics incomplete** — Marked "Phase 2" with TODO comments. Basic metrics only.
- **Bot config gap** — GameListLive doesn't expose delay/strategy options that BotManager supports. GameDetailLive does.

### What to Delete
- `apps/pidro_server/lib/pidro_server_web/live/admin/lobby_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/admin/game_monitor_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/admin/stats_live.ex`
- All `/admin/` routes from `router.ex`

---

## Why This Approach

**Unified panel** instead of split dev/admin because:
- Eliminates code duplication (3 files doing the same thing as existing dev views)
- One mental model — everything is at `/dev/`
- Basic auth makes it safe enough for staging/prod if needed
- No one uses the read-only admin views when the dev views exist

**Tabbed GameDetail** instead of separate pages because:
- Context stays on screen — you're always looking at one game
- Quick switching between "watch the board" and "control bots" and "inspect events"
- Code separation via LiveView components (one per tab) keeps files manageable
- URL stays stable: `/dev/games/:code?tab=board`

**Presets + Advanced configurator** because:
- 90% of the time you want "4 bots, go" — one click
- 10% of the time you need fine control over specific seats
- Advanced toggle keeps the common case clean

---

## Key Decisions

1. **Unified /dev/ panel** — Drop all /admin/ routes and views. One panel, basic auth protected.
2. **Tabbed game detail** — Split GameDetailLive into tabs: Board, Seats & Bots, Actions, Replay, Raw State.
3. **Visual board as primary view** — The existing CardComponents.card_table is the default "Board" tab, not a secondary view.
4. **Quick presets for room creation** — One-click buttons above the advanced form.
5. **God mode by default in dev** — All hands visible, actions available for any position. No need to toggle.
6. **Atomic room+bot creation** — Room creation with bots should be a single operation that rolls back if bots fail.
7. **Admin can take a seat** — Ability to sit down as a player in any position from the dev panel.

---

## Proposed Tab Structure (Game Detail)

| Tab | Purpose | Key Features |
|-----|---------|--------------|
| **Board** | Visual game view | CardComponents.card_table with god mode on, all hands visible, click to play as any player |
| **Seats & Bots** | Manage who's playing | 4-seat visual layout, assign users/bots per seat, bot difficulty/delay/strategy config, kick/swap |
| **Actions** | Execute game actions | Action buttons for current phase (bid, declare, play), position selector, action log |
| **Replay** | Event history | Event timeline, step forward/back, filter by type/player, jump to any point |
| **Raw State** | JSON inspection | Full game state dump, copy to clipboard, position-filtered view |

---

## Proposed Room Dashboard Layout

```
┌─────────────────────────────────────────────────────┐
│  PIDRO DEV PANEL                        [Analytics] │
├─────────────────────────────────────────────────────┤
│  Stats: 12 rooms │ 3 waiting │ 5 active │ 4 done   │
├─────────────────────────────────────────────────────┤
│  Quick Create:                                      │
│  [4 Bots] [1H + 3B] [2H + 2B] [Empty] [Advanced…] │
├─────────────────────────────────────────────────────┤
│  Filter: [All ▾] [Search...        ] [Sort: New ▾] │
├─────────────────────────────────────────────────────┤
│  Room     Status   Players  Phase     Scores  Age   │
│  ABC123   Playing  4/4      Trick 3   12-8    5m    │
│  DEF456   Waiting  1/4      —         —       2m    │
│  GHI789   Done     4/4      Complete  62-58   15m   │
│  ...                                                │
└─────────────────────────────────────────────────────┘
```

---

## Resolved Questions

1. **Auth for unified panel** — Keep existing basic auth config (`admin_username`/`admin_password` env vars). Good enough for dev tooling.
2. **Live game creation from lobby** — Room stays in **waiting state** after creation. Admin can take a seat, configure bots, then start when ready. Auto-starts when all 4 seats filled (existing behavior).
3. **Default mode when opening a game** — **God-mode spectator**: see all hands, can act as any player immediately. "Take Seat" button to actually sit down as a player.
4. **Room cleanup** — Defer to v2. Manual cleanup for now (existing delete buttons).

---

## Scope Estimate

### Must Have (v1)
- Delete admin duplicate views
- Unified /dev/ routes with basic auth
- Room dashboard with stats, filtering, presets
- Tabbed game detail (Board, Seats & Bots, Actions, Raw State)
- Atomic room+bot creation
- Fix bot-seat conflict (respect occupied seats)
- Admin can take a seat

### Nice to Have (v2)
- Replay tab with event timeline
- Analytics tab with richer metrics
- Room auto-cleanup
- Bot strategy comparison tools
- Game state snapshots (save/load)
