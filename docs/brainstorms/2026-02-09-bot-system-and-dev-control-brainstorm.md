# Bot System & Dev Game Control

**Date:** 2026-02-09
**Status:** Brainstorm complete, ready for planning

## What We're Building

A production bot/AI player system that serves three use cases:

1. **Rage-quit replacement** — When a player disconnects mid-game, remaining players vote to replace them with a bot. The bot plays transparently (labeled as AI) under reasonable strategy. If the human reconnects, they reclaim control. This solves the #1 frustration for our 70K player base: abandoned games.

2. **Intentional bot games** — Players can create games with 1-3 bot seats. Practice mode, solo play, play when friends aren't online. First-class feature, not hidden. This increases engagement by removing the "waiting for 3 other humans" barrier.

3. **Dev/QA game control** — A rebuilt dev panel for creating games, watching them play out in real-time, controlling individual seats, jumping into games, and reproducing bugs. Primary use: QA and testing. Not a production operations tool (yet).

## Why This Approach

### Promote + Extend the Existing Dev Bot System

We already have a working bot infrastructure in dev-only mode:

- **BotManager** (GenServer) — Tracks all bots, lifecycle management, ETS lookup
- **BotPlayer** (GenServer) — One process per bot, joins room like a real player, subscribes to PubSub, detects its turn, calls strategy, applies action with configurable delay
- **BotSupervisor** (DynamicSupervisor) — Manages bot processes
- **RandomStrategy** — Returns `{:ok, action, reasoning}` tuple
- **GameHelpers** — `auto_bid/2`, `fast_forward/2` for dev testing

The architecture is sound: bots are real players that join rooms via `RoomManager.join_room()`, occupy actual seats, and interact through the same `GameAdapter.apply_action()` path as humans. This means zero special-casing in the game engine or channels.

**Decision: Promote from `Dev.*` namespace to `Games.*` namespace.** Same code, available in all environments, extended with production features (auto-replacement, reconnection handoff, transparency labels).

### Process-Per-Bot (Not Inline)

Each bot is a GenServer that joins the room like a human player. This gives us:

- **Observability** — Can monitor, pause, resume, inspect each bot individually
- **Delay control** — Real-time play with configurable per-action delays (0.5-2s)
- **Crash isolation** — One bot crashing doesn't affect the game or other bots
- **Consistency** — Same join/play/leave flow as humans, no special paths
- **Already built** — The dev system works exactly this way

### Real-Time Play Speed

Bots play at human-like speed with configurable delays. No hyper-fast mode for now.

For the "watch a game" use case, the existing event sourcing + replay system already lets you scrub through completed games at any speed. So the workflow is: bots play in real-time → game completes → replay at any speed if needed.

### Random Strategy is Good Enough (For Now)

The `random_strategy/0` we built today is the production default:
- Passes 70% during bidding, bids minimum otherwise
- Plays random legal cards during tricks
- Games complete in ~9 hands, no infinite loops
- For a game that's 70-80% done (rage-quit scenario), it's more than adequate

Smarter strategies (`:basic`, `:smart`) are already stubbed in the strategy module system. Build them later when there's demand.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bot architecture | Process-per-bot (GenServer) | Already built, observable, crash-isolated |
| Production availability | Promote dev code to prod | Same proven code, wider availability |
| Rage-quit flow | Remaining players vote | Social, fair, not disruptive |
| Bot transparency | Always labeled as AI | Honest, builds trust with players |
| Intentional bot games | First-class feature | Removes "waiting for humans" barrier |
| Play speed | Real-time with delays | Natural feel; use replay for fast review |
| Default strategy | Random (passes 70% in bidding) | Good enough, ships today |
| Dev panel focus | QA & testing | Not production ops (yet) |
| Reconnection | Human reclaims seat from bot | Seamless handoff, bot stops |

## Architecture Overview

```
Current (dev-only):                    Target (all envs):

PidroServer.Application                PidroServer.Application
├── Games.Supervisor                   ├── Games.Supervisor
│   ├── GameRegistry                   │   ├── GameRegistry
│   ├── GameSupervisor                 │   ├── GameSupervisor
│   └── RoomManager                    │   ├── RoomManager
├── Dev.BotSupervisor  ← dev only      │   ├── BotSupervisor    ← all envs
└── Dev.BotManager     ← dev only      │   └── BotManager       ← all envs
                                       │
                                       ├── Bots.RandomStrategy
                                       ├── Bots.BasicStrategy   (future)
                                       └── Bots.SmartStrategy   (future)
```

### Rage-Quit Replacement Flow

```
1. Player disconnects
   └── GameChannel detects disconnect
   └── RoomManager marks player as "disconnected" (existing 2-min grace)

2. Grace period expires (30s? configurable)
   └── Broadcast to remaining 3 players: "Player X left. Replace with bot?"

3. Players vote (majority = 2 of 3)
   └── If yes: BotManager.start_bot(room_code, position, :random, delay_ms: 1000)
   └── Bot joins seat, labeled "[Player X] (Bot)" — transparent
   └── Bot starts playing on its turn

4. Original player reconnects
   └── BotManager.stop_bot(room_code, position)
   └── Human reclaims seat
   └── Other players notified: "Player X is back!"

5. If vote fails or no quorum
   └── Extended grace period continues
   └── Eventually game can be abandoned (existing flow)
```

### Intentional Bot Game Flow

```
1. Player creates room
   └── Selects "Play with bots" or fills specific seats with bots

2. Room created with bot seats marked
   └── BotManager.start_bot() for each bot seat
   └── Bots join via RoomManager.join_room() (normal flow)

3. When 4 seats filled (human + bots)
   └── Game auto-starts (existing flow)
   └── Bots play at human-like speed with delays
   └── Player sees bot actions with small "Bot" indicator

4. Game completes normally
   └── Bots cleaned up
   └── Stats tracked (bot games vs human games)
```

### Dev Panel Improvements

The existing dev UI (`GameDetailLive`) is feature-rich but "kind of sucks" UX-wise. Rather than rewriting, focus on:

1. **Streamlined game creation** — One-click "4 bots, go" button
2. **Better seat management** — Visual card table layout, drag-to-assign
3. **Live game visualization** — Show cards being played, trick winners, score changes
4. **Jump-in capability** — Take over a bot's seat mid-game for manual testing
5. **State inspector** — Collapsible, not in-your-face. Focus on the game view.

## What We're NOT Building (Yet)

- **Smart bot strategies** — Random is fine for now. Build when players complain.
- **Bot difficulty selection for players** — Just "Bot" for now. Difficulty tiers later.
- **Production operations panel** — Dev panel is for QA. Admin dashboard is a separate feature.
- **Bot ELO/rating** — No competitive ranking for bots.
- **Hyper-fast simulation mode** — Real-time play + replay covers the use cases.
- **Cross-game bot management** — Each bot lives in one game. No "bot pool" concept.

## Open Questions

1. **Vote timeout** — How long do remaining players have to vote on bot replacement? 30s? 60s? What if one voter is AFK?
2. **Bot naming** — Should bots have fun names ("BotBjorn", "RoboPekka") or just "[Player] (Bot)"?
3. **Stats separation** — Should games with bots count toward player rankings/stats, or be tracked separately?
4. **Max bots per game** — Can a player play 1v3 bots? Or max 2 bots per game?
5. **Mobile client changes** — What channel messages need to change to support bot transparency? Is this purely server-side or does the client need updates?

## Implementation Phases (High-Level)

**Phase 1: Promote Bot Infrastructure**
- Move `Dev.BotManager`, `Dev.BotPlayer`, `Dev.BotSupervisor` → `Games.*`
- Start in all environments
- Wire `random_strategy()` as the production strategy
- No new features, just availability

**Phase 2: Rage-Quit Replacement**
- Add disconnect detection + vote mechanism
- Bot auto-start on vote pass
- Human reconnection handoff
- Transparency labels in channel broadcasts

**Phase 3: Intentional Bot Games**
- Room creation with bot seat selection
- Lobby UI for "Play with Bots" option
- Channel protocol for bot indicators

**Phase 4: Dev Panel Rebuild**
- Streamlined game creation
- Visual card table for watching games
- Jump-in capability
- Better mobile-friendly layout

## References

- Existing bot code: `apps/pidro_server/lib/pidro_server/dev/` (BotManager, BotPlayer, etc.)
- Game adapter: `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`
- Room manager: `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- Agent play guide: `docs/AGENT_PLAY_GUIDE.md`
- Strategy interface: `pick_action(legal_actions, game_state) → {:ok, action, reasoning}`
- Dev UI: `apps/pidro_server/lib/pidro_server_web/live/dev/`
