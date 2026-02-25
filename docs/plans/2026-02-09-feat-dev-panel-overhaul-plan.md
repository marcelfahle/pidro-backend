---
title: "feat: Dev Panel Overhaul — Unified Admin Control Room"
type: feat
date: 2026-02-09
revised: 2026-02-09
---

# Dev Panel Overhaul — Unified Admin Control Room

> Revised after review by DHH, Kieran, and Simplicity reviewers. Cut ~60% of the original plan. Corrected file paths and scope estimates.

## Overview

Consolidate the split `/dev/` and `/admin/` views into a single dev panel at `/dev/`. Delete the duplicate admin views. Restructure the monolithic `GameDetailLive` (~2,343 lines) into a tabbed interface. Add quick-create presets, fix bot-seat conflicts, and enable the admin to take a seat in any game.

The visual card table (`CardComponents.card_table`) is already production-quality — this overhaul makes it the primary view instead of a sidebar to JSON dumps.

## Problem Statement

1. **Duplicate views** — `lobby_live.ex`, `game_monitor_live.ex`, `stats_live.ex` are read-only copies of the dev views
2. **Monolithic detail view** — `GameDetailLive` is ~2,343 lines with a ~900-line render function
3. **Bot-seat bug** — `BotManager.start_bots` fills positions from north regardless of occupancy
4. **No quick presets** — Every room creation requires filling out a form
5. **No cascading cleanup** — Deleting a room leaves orphaned bot and game processes

## Proposed Solution

### Architecture

```
/dev/                    (compile-time gated via dev_routes)
├── /dev/games           GameListLive (room dashboard + quick-create presets)
├── /dev/games/:code     GameDetailLive (tabbed: Board, Seats & Bots)
└── /dev/analytics       AnalyticsLive (unchanged)
```

**Delete entirely:**
- `apps/pidro_server/lib/pidro_server_web/live/lobby_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/game_monitor_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/stats_live.ex`
- `/admin` scope and routes from `router.ex`

**Business logic fix:**
- `BotManager.start_bots/4` — Query occupied seats, fill empties only

---

## Implementation Phases

Each phase can be shipped independently. Phase 1 is pure deletion + bug fixes. Phase 2 adds quick-create. Phase 3 restructures the UI.

### Phase 1: Delete & Fix

No UI changes. Just remove dead code and fix bugs.

#### 1.1 Delete admin views and routes

- [ ] Delete `apps/pidro_server/lib/pidro_server_web/live/lobby_live.ex` (module: `PidroServerWeb.LobbyLive`)
- [ ] Delete `apps/pidro_server/lib/pidro_server_web/live/game_monitor_live.ex` (module: `PidroServerWeb.GameMonitorLive`)
- [ ] Delete `apps/pidro_server/lib/pidro_server_web/live/stats_live.ex` (module: `PidroServerWeb.StatsLive`)
- [ ] Remove the `/admin` scope (lines 44-50) and `admin_basic_auth` plug from `router.ex`
- [ ] Delete any admin-specific test files if they exist

**File:** `apps/pidro_server/lib/pidro_server_web/router.ex`

#### 1.2 Fix BotManager.start_bots to skip occupied seats

Current bug: `start_bots/4` (line 43-57 of `bot_manager.ex`) does `Enum.take(bot_count)` on `[:north, :east, :south, :west]`. If the host is at `:north` and you request 3 bots, it tries north first and fails.

- [ ] Query `RoomManager.get_room(room_code)` to get occupied positions
- [ ] Filter position list to only empty seats
- [ ] Fill empty seats up to `bot_count`
- [ ] If fewer empty seats than `bot_count`, return `{:error, :not_enough_seats}`
- [ ] Keep existing return type `{:ok, [pid()]}` on success

Note: This creates a dependency direction `BotManager → RoomManager` (read-only query). This is acceptable and should never be reversed.

**File:** `apps/pidro_server/lib/pidro_server/games/bots/bot_manager.ex`

#### 1.3 Cascading cleanup on room deletion

Currently `close_room/1` removes the room from state but leaves bot and game processes running.

- [ ] Add `BotManager.stop_all_bots(room_code)` and `GameSupervisor.stop_game(room_code)` calls. Perform these *before* calling `close_room` (from the LiveView delete handler), not inside the RoomManager GenServer — avoids cross-GenServer calls while holding state lock.
- [ ] In `GameDetailLive`'s `assign_seat` handler: check if a bot occupies the target position and call `BotManager.stop_bot(room_code, position)` before reassigning

**Files:**
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex` (delete handlers)
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex` (assign_seat handler)

#### 1.4 Clean up dead code in GameDetailLive

- [ ] Delete commented-out position buttons (lines ~982-1060)
- [ ] Remove any helper functions that become unused after admin view deletion

**File:** `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex`

#### 1.5 Tests for Phase 1

- [ ] Test `BotManager.start_bots` skips occupied seats (host at north, request 3 bots → bots at east/south/west)
- [ ] Test `BotManager.start_bots` returns error when not enough empty seats
- [ ] Test cascading cleanup: after room deletion, `BotManager.list_bots(room_code)` returns `[]`

**File:** `apps/pidro_server/test/pidro_server/games/bots/bot_manager_test.exs`

---

### Phase 2: Quick-Create Presets

Add one-click room creation buttons to `GameListLive`.

#### 2.1 Preset buttons

Add a row of preset buttons above the existing creation form.

- [ ] **"4 Bots"** — Create room, then fill all 4 seats with bots. Must handle auto-start race: create room with dev host, use `dev_set_position` to assign bot IDs to all 4 seats *before* starting bot processes, then start bots to match those positions. This avoids the 4-player auto-start firing before the host is displaced.
- [ ] **"1H + 3B"** — Create room with dev host at north, 3 bots fill remaining seats
- [ ] **"2H + 2B"** — Create room with dev host at north, 2 bots at east and west, south left empty
- [ ] **"Empty Room"** — Create room with dev host at north, no bots, 3 empty seats
- [ ] After creation, navigate to the new room's detail view
- [ ] On bot failure: call `BotManager.stop_all_bots(room_code)` in the existing error branch of `start_bots_if_needed`. No new RoomManager function needed — handle cleanup in the LiveView.

**File:** `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex`

#### 2.2 Room table: add phase and scores columns

- [ ] Add game phase column (e.g., "Trick 3", "Bidding")
- [ ] Add scores column (N/S vs E/W) for active/finished games

**File:** `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex`

---

### Phase 3: Tabbed Detail View

Restructure the ~2,343-line `GameDetailLive` into a tabbed interface.

#### 3.1 Two-tab interface

Two tabs: **Board** and **Seats & Bots**. The Board tab contains everything game-related (card table, actions, replay toggle, raw state collapsible). Seats & Bots is the configuration tab.

- [ ] Add `@active_tab` assign (default `:board`), sync with URL param `?tab=board`
- [ ] Add tab bar with two tabs at the top of the page
- [ ] Render only the active tab's content (conditional render, not CSS hide)
- [ ] Preserve all existing `handle_event` and `handle_info` clauses — only reorganize the template

**Board tab contains:**
- `CardComponents.card_table` with god mode on by default (`selected_position: :all`)
- Legal actions panel (existing, grouped by type)
- Quick actions: "Auto-bid" (pass), "Auto-play" (random legal card)
- Replay controls (existing, as a toggleable mode)
- Raw state JSON (existing `<details>` collapsible at the bottom)
- "Take Seat" button (see 3.3)

**Seats & Bots tab contains:**
- 4-seat visual layout (reuse `CardComponents.waiting_table` pattern)
- Per-seat: current occupant, assign user dropdown, start/stop bot, bot config (difficulty/strategy/delay), pause/resume
- Auto-stop bot when reassigning its seat (from Phase 1.3)

#### 3.2 Extract template into private render functions

Use private `defp` render functions inside `GameDetailLive` to break up the ~900-line render function. Do NOT create a separate DevComponents module — keep code co-located with event handlers.

- [ ] `defp render_board_tab(assigns)` — card table + actions + replay + raw state
- [ ] `defp render_seats_tab(assigns)` — seat assignment + bot configuration
- [ ] `defp render_tab_bar(assigns)` — horizontal tab navigation
- [ ] Target: main `render/1` under 50 lines (tab bar + conditional render)

**File:** `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex`

#### 3.3 Take a Seat

Simple approach — no identity system. Use the existing seat assignment dropdown pattern.

- [ ] Add a "Take Seat" button on the Board tab that shows a position picker (North/South/East/West)
- [ ] Position picker also shows the existing user dropdown to select which user to seat
- [ ] Calls `RoomManager.dev_set_position(room_code, position, user_id)` — same as the Seats & Bots tab
- [ ] This is a convenience shortcut, not a new feature — it uses the same mechanism as the Seats tab

#### 3.4 God mode: manual position selection

God mode (`:all`) is the default — all hands visible. To execute an action, the admin clicks on a player's name/position to switch to that perspective, then acts. No auto-detect-turn — it's clearer and avoids race conditions with concurrent bots.

- [ ] Default `selected_position` to `:all` on mount
- [ ] Clicking a position name switches to that player's perspective and shows their legal actions
- [ ] Clicking "All" / god-mode toggle returns to `:all` view
- [ ] Current turn is highlighted prominently so the admin knows who to click

---

### Phase 4: Deferred (v2)

- [ ] Basic auth on dev routes (defer until staging deployment)
- [ ] Replay tab as separate rich view with auto-play, jump-to-phase
- [ ] Analytics with bot metrics, error rates, game duration histograms
- [ ] Room auto-cleanup (finished rooms deleted after configurable time)
- [ ] Bot strategy comparison tools
- [ ] Game state snapshots (save/load for reproducing bugs)
- [ ] Pagination for room list (50+ rooms)
- [ ] Dev rooms badge in public lobby
- [ ] Per-seat advanced configurator at room creation time (Seats & Bots tab provides this post-creation)

---

## Acceptance Criteria

### Functional Requirements

- [ ] All `/admin/*` routes return 404
- [ ] Room dashboard shows all rooms with status, players, phase, scores
- [ ] Quick-create presets work in one click, navigate to detail view
- [ ] `start_bots` skips occupied seats (no more bot-seat conflicts)
- [ ] Room deletion cascades: bots stopped, game process stopped
- [ ] Reassigning a bot's seat auto-stops the bot
- [ ] Game detail view has 2 tabs: Board and Seats & Bots
- [ ] Board tab shows CardComponents.card_table with god mode on by default
- [ ] Admin can take a seat from the Board tab via position picker + user dropdown
- [ ] Seats & Bots tab shows per-seat controls with bot config
- [ ] Raw state JSON accessible as collapsible on Board tab

### Non-Functional Requirements

- [ ] No new LiveComponents — follow existing function component pattern
- [ ] No new modules for template extraction — use private `defp` render functions
- [ ] All PubSub subscriptions inside `if connected?(socket)` guard
- [ ] Use explicit match maps for string-to-atom conversion on new code (not `String.to_existing_atom`)
- [ ] GameDetailLive `render/1` under 50 lines (delegates to private render functions)

### Testing Requirements

- [ ] Unit tests for `start_bots` seat-skipping behavior
- [ ] Unit tests for cascading cleanup on room deletion
- [ ] Manual test: create room with each preset, verify bots start correctly
- [ ] Manual test: "4 Bots" preset does not trigger premature auto-start

---

## Key Files

### Files to Modify
- `apps/pidro_server/lib/pidro_server_web/router.ex` — Delete admin scope and routes
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex` — Add presets, phase/scores columns, bot cleanup in error branch
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex` — Tabbed interface, private render functions, take-a-seat, auto-stop bot on reassign
- `apps/pidro_server/lib/pidro_server/games/bots/bot_manager.ex` — Fix start_bots to skip occupied seats

### Files to Delete
- `apps/pidro_server/lib/pidro_server_web/live/lobby_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/game_monitor_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/stats_live.ex`

### Files to Create
- `apps/pidro_server/test/pidro_server/games/bots/bot_manager_test.exs` — Tests for seat-skipping and cleanup

---

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Number of tabs | 2 (Board, Seats & Bots) | Actions and raw state belong with the board view. Replay is a mode toggle, not a tab. |
| Template extraction | Private `defp` render functions | Keeps code co-located with event handlers. No new module needed for 2 tabs. |
| God mode action execution | Manual position click | Auto-detect-turn races with concurrent bots. Clicking the player is explicit and clear. |
| Admin identity / Take a Seat | Reuse existing user dropdown | No identity system needed. Same mechanism as Seats & Bots tab. |
| Atomic room+bot creation | Handle cleanup in LiveView error branch | RoomManager should stay thin. Orphaned rooms are harmless and deletable. |
| Cascading cleanup location | In LiveView delete handler, before close_room | Avoids cross-GenServer calls inside RoomManager's handle_call. |
| Advanced seat configurator | Deferred to v2 | Presets cover 90% of cases. Seats & Bots tab provides per-seat config post-creation. |
| DevHelpers module | Not needed | After admin deletion, duplication drops to 2 files. Trivial. |
| DevComponents module | Not needed | Private render functions avoid creating a new monolith. |
| Basic auth on dev routes | Deferred | Routes already compile-gated. Auth is an ops concern for staging. |

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GameDetailLive refactor breaks existing events | Medium | High | Keep all handle_event clauses unchanged, only reorganize template. Test manually. |
| "4 Bots" preset triggers auto-start before host displaced | High | Medium | Assign bot IDs to seats via dev_set_position *before* starting bot processes. |
| Bot-seat fix introduces dependency BotManager → RoomManager | Low | Low | Read-only query. Acceptable direction. Never reverse it. |
| ~2,343-line file still large after refactor | Medium | Low | Private render functions make it navigable. Further splitting can happen later. |

---

## What Was Cut (and Why)

Items removed after review by DHH, Kieran, and Simplicity reviewers:

| Cut Item | Reason |
|----------|--------|
| `DevComponents` module | Would create a new monolith. Private render functions suffice. |
| `DevHelpers` module | Duplication drops to 2 files after admin deletion. Not worth a new module. |
| `RoomManager.create_room_with_bots/4` | Violates "thin GenServers." Cleanup belongs in LiveView error branch. |
| Advanced seat configurator | YAGNI. Seats & Bots tab provides this post-creation. |
| Admin identity system (`@dev_user_id`) | Over-engineered. Reuse existing user dropdown for Take-a-Seat. |
| God-mode auto-detect-turn | Races with concurrent bots. Manual click is clearer. |
| 5 tabs → 2 tabs | Actions belong with board. Raw state is a collapsible. Replay is a mode toggle. |
| Basic auth on dev routes | Ops concern, not a dev panel feature. Routes already compile-gated. |
| Live-updating age column | Timer-driven re-render for marginal value. Timestamp suffices. |
| Spectate button on room rows | "Watch" link already exists. |

---

## References

- Brainstorm: `docs/brainstorms/2026-02-09-dev-panel-overhaul-brainstorm.md`
- Bot system plan: `docs/plans/2026-02-09-feat-production-bot-system-plan.md`
- Dev UI masterplan: `apps/pidro_server/MASTERPLAN-DEVUI.md`
- CardComponents: `apps/pidro_server/lib/pidro_server_web/components/card_components.ex`
- GameDetailLive: `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex`
- GameListLive: `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex`
- RoomManager: `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- BotManager: `apps/pidro_server/lib/pidro_server/games/bots/bot_manager.ex`
