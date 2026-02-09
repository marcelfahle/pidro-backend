---
title: "feat: Production Bot System — Rage-Quit Replacement & Intentional Bot Games"
type: feat
date: 2026-02-09
---

# Production Bot System

## Overview

Promote the existing dev bot infrastructure to production and extend it with two player-facing features:

1. **Rage-quit auto-replacement** — When any player (including the host) disconnects mid-game, a 10-second reconnection grace fires. If they don't return, a bot automatically takes their seat. If they reconnect later, they reclaim the seat. No voting. Zero game-freeze.

2. **Intentional bot games** — Players can create rooms with 1-3 bot seats for practice/solo play. First-class feature, not hidden. Bots are always transparently labeled.

## Problem Statement

**Today:** When a player rage-quits (especially when losing), the game is effectively dead. No replacement mechanism exists. The remaining 3 players are stuck. For 70K players (10K active), this is the #1 frustration. Additionally, players can't practice or play when friends aren't online — you always need 4 humans.

**After this:** Disconnected players are auto-replaced by bots within 10 seconds. Games continue seamlessly. Players can also create practice rooms with bots anytime. The existing dev bot infrastructure (BotManager, BotPlayer, BotSupervisor, RandomStrategy) is promoted to production with minimal changes.

## Technical Approach

### Phase 1: Promote Bot Infrastructure to Production

Move the existing dev-only bot system to a production-available namespace. No new features — just availability in all environments.

#### 1a. Move modules from `Dev.*` to `Games.Bots.*`

| Current Location | New Location |
|------------------|-------------|
| `PidroServer.Dev.BotSupervisor` | `PidroServer.Games.Bots.BotSupervisor` |
| `PidroServer.Dev.BotManager` | `PidroServer.Games.Bots.BotManager` |
| `PidroServer.Dev.BotPlayer` | `PidroServer.Games.Bots.BotPlayer` |
| `PidroServer.Dev.Strategies.RandomStrategy` | `PidroServer.Games.Bots.Strategies.RandomStrategy` |
| `PidroServer.Dev.GameHelpers` | `PidroServer.Games.Bots.GameHelpers` |

**Files to create:**
- `apps/pidro_server/lib/pidro_server/games/bots/bot_supervisor.ex`
- `apps/pidro_server/lib/pidro_server/games/bots/bot_manager.ex`
- `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex`
- `apps/pidro_server/lib/pidro_server/games/bots/strategies/random_strategy.ex`
- `apps/pidro_server/lib/pidro_server/games/bots/game_helpers.ex`

**Key changes per module:**
- Remove the `if Mix.env() == :dev do` wrapper
- Update module name from `PidroServer.Dev.*` to `PidroServer.Games.Bots.*`
- Update all internal references (BotPlayer references BotManager, etc.)
- Rename ETS table from `:dev_bots` to `:pidro_bots`

#### 1b. Define Strategy behaviour

Create a formal `@behaviour` for strategies:

**File:** `apps/pidro_server/lib/pidro_server/games/bots/strategy.ex`

```elixir
defmodule PidroServer.Games.Bots.Strategy do
  @callback pick_action(legal_actions :: [term()], game_state :: map()) ::
              {:ok, action :: term(), reasoning :: String.t()}
end
```

Update `RandomStrategy` to `@behaviour PidroServer.Games.Bots.Strategy`.

#### 1c. Update supervision tree

**File:** `apps/pidro_server/lib/pidro_server/application.ex`

Move BotSupervisor and BotManager from `dev_children/0` to the always-started children list, inside `Games.Supervisor` or alongside it:

```elixir
children = [
  # ... existing children ...
  PidroServer.Games.Supervisor,
  PidroServer.Games.Bots.BotSupervisor,
  PidroServer.Games.Bots.BotManager,
  PidroServerWeb.Endpoint
]
```

Remove the `dev_children/0` function entirely.

#### 1d. Update dev UI references

The existing dev LiveView pages reference `PidroServer.Dev.BotManager`, etc. Update these imports to the new namespace:

**Files:**
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_detail_live.ex`
- `apps/pidro_server/lib/pidro_server_web/live/dev/game_list_live.ex`

#### 1e. Fix GameHelpers auto_bid bug

`GameHelpers.auto_bid/2` calls `RandomStrategy.pick_action()` but doesn't destructure the `{:ok, action, reasoning}` return. The raw tuple gets passed to `GameAdapter.apply_action()`, which would fail.

**File:** `apps/pidro_server/lib/pidro_server/games/bots/game_helpers.ex` (~line 179)

#### 1f. Wire RandomStrategy to use the proven bidding approach

The existing `Dev.Strategies.RandomStrategy` uses `Enum.random(legal_actions)` for all actions including bidding. This causes infinite games (documented in `docs/solutions/logic-errors/random-bidding-causes-infinite-games.md`).

Update production `RandomStrategy` to use the proven approach from `Pidro.IEx.random_strategy/0`: pass 70% during bidding, bid minimum otherwise.

**Acceptance criteria:**
- [x] All 6 bot modules compile and are available in `:test` and `:prod` environments
- [x] `Strategy` behaviour defined with `@callback pick_action/2`
- [x] `RandomStrategy` implements behaviour with proven bidding strategy
- [x] BotSupervisor + BotManager start in all environments
- [x] Dev UI still works with new namespace
- [x] `GameHelpers.auto_bid` handles `{:ok, action, reasoning}` return correctly
- [x] Existing engine tests still pass (564+)
- [x] Old dev module files deleted or aliased

---

### Phase 2: Rage-Quit Auto-Replacement

When any player disconnects mid-game, auto-replace with a bot after a short grace period. No voting. Seamless.

#### 2a. Extend Room struct with bot tracking

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

Add to Room struct:

```elixir
defstruct [
  # ... existing fields ...
  original_players: %{},    # %{position => original_user_id} — persists through bot replacement
  bot_positions: MapSet.new() # set of positions currently occupied by bots
]
```

When a room is created, `original_players` starts empty. When players join, their position is tracked in `original_players`. This map never changes — it records who was originally in each seat.

#### 2b. New RoomManager functions for bot replacement

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

```elixir
@doc "Replace a disconnected player with a bot. Bypasses join checks."
def replace_with_bot(room_code, position, bot_user_id)

@doc "Reclaim a seat from a bot when the original player reconnects."
def reclaim_from_bot(room_code, position, original_user_id)
```

`replace_with_bot/3`:
1. Verify position is in `disconnected_players` (the human left)
2. Save original user_id in `original_players` map (if not already there)
3. Swap positions map entry: `%{north: "user123"}` → `%{north: "bot_ABCD_north"}`
4. Add position to `bot_positions` set
5. Remove from `disconnected_players`
6. Update `player_rooms` mapping
7. Broadcast room update with bot metadata

`reclaim_from_bot/3`:
1. Verify position is in `bot_positions`
2. Verify `original_user_id` matches `original_players[position]`
3. Swap positions back: `%{north: "bot_ABCD_north"}` → `%{north: "user123"}`
4. Remove from `bot_positions`
5. Update `player_rooms` mapping
6. Broadcast room update

#### 2c. Restructure disconnect grace period

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

The current flow: disconnect → 2-minute grace → remove player from room.

New flow for `:playing` rooms:

```
disconnect detected
  → mark as disconnected (existing)
  → schedule {:bot_replacement_timeout, room_code, position} after 10 seconds

10 seconds later:
  → if player still disconnected: trigger bot replacement
  → if player reconnected: cancel (already handled)
```

For non-`:playing` rooms (`:waiting`, `:ready`), keep the existing 2-minute grace + removal behavior.

**Changes to `handle_player_disconnect/2`:**
- If room status is `:playing`: schedule 10-second bot replacement timeout
- If room status is not `:playing`: keep existing behavior

**New `handle_info({:bot_replacement_timeout, ...})`:**
1. Check player is still disconnected
2. Get the position from room
3. Call `BotManager.start_bot(room_code, position, :random, delay_ms: 1000)`
4. Call `replace_with_bot(room_code, position, bot_user_id)`
5. Broadcast `"bot_replaced_player"` event to game channel

#### 2d. Host disconnect handling

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

Currently, host disconnect → `remove_room()` → game destroyed.

**Change:** During `:playing` status, host disconnect follows the same bot-replacement flow as any other player. The host privilege transfers to the next human player (clockwise from the host's position). If no humans remain, the room persists until the game completes (bots finish it).

For non-`:playing` rooms, host disconnect still closes the room (existing behavior).

#### 2e. Reconnection → seat reclaim

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

Extend `handle_player_reconnect/2`:

If the player's original position is now occupied by a bot (check `bot_positions`):
1. Stop the bot: `BotManager.stop_bot(room_code, position)`
2. Reclaim the seat: `reclaim_from_bot(room_code, position, user_id)`
3. Broadcast `"player_reclaimed_seat"` event

The reclaim window lasts until the game ends (`:complete` phase). After that, no reclaim.

#### 2f. Race condition prevention: bot action vs reconnecting player

When a human reconnects, the bot might have a scheduled `:make_move` pending (via `Process.send_after`). The sequence must be:

1. Stop the bot process (`BotManager.stop_bot` → `GenServer.stop`)
2. This kills any pending `send_after` messages
3. *Then* reclaim the seat in RoomManager
4. *Then* broadcast to channels

Since `GenServer.stop` is synchronous, step 1 completes before step 3. No race.

#### 2g. Channel protocol updates

**File:** `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`

New broadcast events:

```elixir
# When a bot replaces a disconnected player
broadcast!(socket, "bot_replaced_player", %{
  position: :north,
  bot_name: "Bot (N)",
  original_player_id: "user123"
})

# When the original player reclaims their seat
broadcast!(socket, "player_reclaimed_seat", %{
  position: :north,
  player_id: "user123"
})
```

Update Presence metadata for bot players: add `is_bot: true` (the WEBSOCKET_API.md `PlayerSummary` already has this field defined).

#### 2h. Bot cleanup on game end

When the game reaches `:complete` phase, clean up all bot processes for that room.

**File:** `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`

In `broadcast_state_update/2`, when `state.phase == :complete`:

```elixir
BotManager.stop_all_bots(room_code)
```

#### 2i. Stats handling

**File:** `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`

In `save_game_stats/2`, filter out bot user IDs from `player_ids`. Track bot replacement as metadata:

```elixir
%{
  player_ids: human_player_ids,
  had_bot_replacement: true,
  bot_positions: [:north]
}
```

**Acceptance criteria:**
- [ ] Disconnected player auto-replaced by bot after 10 seconds (`:playing` rooms)
- [ ] Bot is transparently labeled ("Bot (N)", `is_bot: true` in presence)
- [ ] Original player can reconnect and reclaim seat (bot stops, human takes over)
- [ ] Host disconnect during `:playing` triggers bot replacement, not room destruction
- [ ] Host privileges transfer to next human player
- [ ] No race condition between bot action and human reclaim
- [ ] Bots cleaned up on game completion
- [ ] Game stats track human players only (bot IDs filtered)
- [ ] Non-`:playing` rooms keep existing disconnect behavior (2-min grace)
- [ ] Channel broadcasts new events: `"bot_replaced_player"`, `"player_reclaimed_seat"`

---

### Phase 3: Intentional Bot Games

Players can create rooms with bot seats for practice/solo play.

#### 3a. Extend room creation API

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

Add `bot_config` option to `create_room/2`:

```elixir
create_room(host_id, %{
  name: "Practice Room",
  bot_seats: [:east, :south, :west],   # specific positions
  bot_strategy: :random,               # strategy for all bots
  bot_delay_ms: 1000                   # action delay
})
```

When `bot_seats` is provided:
1. Create room as normal (host at `:north` or preferred position)
2. Mark room as `room_type: :practice` (new field on Room struct)
3. Store bot config in room metadata
4. Do NOT spawn bots yet — wait for host to join the channel

#### 3b. Bot spawn on host channel join

**File:** `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`

When the host joins the game channel for a room with `bot_seats` configured:
1. Spawn bots for each configured seat: `BotManager.start_bot(room_code, pos, strategy, delay_ms)`
2. Each bot joins via `RoomManager.join_room()` (room is `:waiting`, seats available — standard flow works)
3. When all 4 seats filled, game auto-starts (existing flow)

This avoids the race condition where bots fill the room before the host subscribes to PubSub.

#### 3c. Lobby visibility

**File:** `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

Add `room_type` field to Room struct: `:public` (default) or `:practice`.

Practice rooms (any room with bot seats) are excluded from lobby broadcasts. They don't appear in `list_rooms/0` results unless explicitly filtered.

Players access practice rooms only via the room code returned at creation.

#### 3d. REST API updates

**File:** `apps/pidro_server/lib/pidro_server_web/controllers/api/room_controller.ex`

Update `create` action to accept bot configuration:

```json
POST /api/v1/rooms
{
  "room": {
    "name": "Practice",
    "bot_seats": ["east", "south", "west"],
    "bot_strategy": "random"
  }
}
```

Validate: `bot_seats` must be valid positions, cannot include the host's position, max 3 bots.

#### 3e. Channel state includes bot indicators

When serializing game state for channel broadcasts, include `is_bot` flag per seat:

```json
{
  "seats": {
    "north": {"player_id": "user123", "is_bot": false},
    "east": {"player_id": "bot_ABCD_east", "is_bot": true, "bot_name": "Bot (E)"},
    ...
  }
}
```

The `PlayerSummary` in WEBSOCKET_API.md already defines `is_bot: boolean`. Wire it up.

**Acceptance criteria:**
- [ ] Room creation accepts `bot_seats` parameter (specific positions)
- [ ] Bots spawn when host joins the game channel (not before)
- [ ] Practice rooms don't appear in public lobby
- [ ] Game auto-starts when all seats filled (human + bots)
- [ ] Bot indicators visible in channel state (`is_bot: true`)
- [ ] REST API validates bot configuration
- [ ] Max 3 bots per room (at least 1 human)
- [ ] Bot cleanup when practice game ends

---

### Phase 4: Dev Panel Improvements (Deferred)

Improve the existing dev UI for QA testing. This is lower priority and can be planned separately after Phases 1-3 ship.

Key improvements:
- One-click "4 bots, go" button
- Visual card table for watching games
- Jump-in capability (take over a bot's seat)
- Better state inspector (collapsible)

---

## Files Modified

| File | Change |
|------|--------|
| `games/bots/bot_supervisor.ex` | **New** — Promoted from Dev.BotSupervisor |
| `games/bots/bot_manager.ex` | **New** — Promoted from Dev.BotManager |
| `games/bots/bot_player.ex` | **New** — Promoted from Dev.BotPlayer |
| `games/bots/strategy.ex` | **New** — Strategy behaviour |
| `games/bots/strategies/random_strategy.ex` | **New** — Promoted + improved bidding |
| `games/bots/game_helpers.ex` | **New** — Promoted, auto_bid bug fixed |
| `games/room_manager.ex` | Add `replace_with_bot`, `reclaim_from_bot`, restructure disconnect handling, add `original_players`/`bot_positions`/`room_type` to Room struct |
| `games/game_adapter.ex` | Bot cleanup on game completion |
| `application.ex` | Start BotSupervisor + BotManager in all envs |
| `channels/game_channel.ex` | Bot spawn on host join, new broadcast events, stats filtering |
| `controllers/api/room_controller.ex` | Accept bot_seats in room creation |
| `live/dev/game_detail_live.ex` | Update imports to new bot namespace |
| `live/dev/game_list_live.ex` | Update imports to new bot namespace |

## Files Deleted (After Promotion)

| File | Reason |
|------|--------|
| `dev/bot_supervisor.ex` | Replaced by `games/bots/bot_supervisor.ex` |
| `dev/bot_manager.ex` | Replaced by `games/bots/bot_manager.ex` |
| `dev/bot_player.ex` | Replaced by `games/bots/bot_player.ex` |
| `dev/strategies/random_strategy.ex` | Replaced by `games/bots/strategies/random_strategy.ex` |
| `dev/game_helpers.ex` | Replaced by `games/bots/game_helpers.ex` |

## Open Questions (Resolved)

| Question | Decision |
|----------|----------|
| Vote or auto-replace? | **Auto-replace** — simpler, faster, no vote infrastructure |
| Grace period for bot replacement? | **10 seconds** — short enough to avoid game freeze |
| Host disconnect during game? | **Bot replaces host too** — host privileges transfer |
| Bot transparency? | **Always labeled** — "Bot (N)", `is_bot: true` |
| Intentional bot games? | **First-class feature** — practice rooms with bot seats |
| Lobby visibility for bot rooms? | **Hidden** — practice rooms not in public lobby |
| Bot strategy? | **Random (proven)** — passes 70% during bidding, ships today |
| Bot play speed? | **Real-time** — 1s delay per action |
| Seat reclaim window? | **Until game ends** — no time limit during active game |

## References

- Brainstorm: `docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md`
- Agent play guide: `docs/AGENT_PLAY_GUIDE.md`
- Infinite games fix: `docs/solutions/logic-errors/random-bidding-causes-infinite-games.md`
- Eliminated player fix: `docs/solutions/logic-errors/current-turn-stuck-on-eliminated-player.md`
- Existing bot code: `apps/pidro_server/lib/pidro_server/dev/` (6 modules, ~1,400 LOC)
- Room manager: `apps/pidro_server/lib/pidro_server/games/room_manager.ex` (1,277 LOC)
- Game channel: `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex` (611 LOC)
- WEBSOCKET_API: `apps/pidro_server/thoughts/WEBSOCKET_API.md` (PlayerSummary.is_bot defined)
