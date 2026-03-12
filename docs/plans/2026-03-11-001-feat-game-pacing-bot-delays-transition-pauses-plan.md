---
title: "feat: Game Pacing Config — Bot delays, transition pauses"
type: feat
status: active
date: 2026-03-11
linear: PID-43
origin: docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md
---

# feat: Game Pacing Config — Bot delays, transition pauses

## Overview

When bots play, the game moves at machine speed — actions fire instantly with no breathing room. Humans can't follow. This feature adds deliberate pacing: configurable bot action delays with random variance and client-side transition pauses between tricks and hands.

**Implementation order note:** This feature should be implemented BEFORE PID-41 (Turn Timers) because PID-41's timer-start logic depends on this feature's transition delay model.

## Problem Statement / Motivation

- BotPlayer has a flat `@default_delay_ms 1000` and SubstituteBot uses `@delay_ms 500` — neither is configurable at runtime
- No transition pauses exist between tricks or hands — the engine resolves everything synchronously in one `apply_action` call
- Bot-vs-bot games (dev testing, 4-bot rooms) are unwatchable at machine speed

## Proposed Solution

### 1. Extend Lifecycle Config with Pacing Keys

Add new config keys to `PidroServer.Games.Lifecycle` following the established pattern. Consolidated to 4 keys (reviewed down from 8):

```elixir
# In @defaults map of lifecycle.ex
bot_delay_ms: 1500,                  # base delay before any bot action
bot_delay_variance_ms: 800,          # random +/- variance (plays between 700-2300ms)
bot_min_delay_ms: 300,               # floor — never go below this
trick_transition_delay_ms: 1500,     # client-side pause after trick completes
hand_transition_delay_ms: 3000,      # client-side pause between hands for score display
```

Add corresponding env var overrides in `config/runtime.exs` following the `{:key, "ENV_VAR_NAME"}` pattern.

**Why 5 keys, not 8:** The original plan had separate bid/play delays and separate variance keys per phase. In practice, a single base delay with variance is enough — bot "thinking time" doesn't need to differ by phase for a good UX. If needed later, phase-specific delays can be added without breaking changes.

### 2. Bot Action Delays (Variance Formula)

Replace hardcoded delays in `BotPlayer` and `SubstituteBot` with configurable values. Bots read from `Lifecycle.config/1` at move time — no snapshot needed.

```elixir
# In BotBrain
def compute_delay(base_ms, variance_ms, min_ms) do
  raw = base_ms + Enum.random(-variance_ms..variance_ms)
  max(raw, min_ms)
end

def schedule_move(transition_delay_ms \\ 0, opts \\ []) do
  delay = compute_delay(
    Keyword.get(opts, :base_delay_ms, Lifecycle.config(:bot_delay_ms)),
    Keyword.get(opts, :variance_ms, Lifecycle.config(:bot_delay_variance_ms)),
    Keyword.get(opts, :min_delay_ms, Lifecycle.config(:bot_min_delay_ms))
  )
  Process.send_after(self(), :make_move, delay + transition_delay_ms)
end
```

### 3. BotPlayer Dedup Flag

Add a `move_scheduled?` flag to BotPlayer state to prevent duplicate move scheduling from rapid room-coded `{:state_update, room_code, payload}` messages. Multiple state updates can arrive before the bot acts, and without dedup the bot could schedule two `:make_move` messages.

```elixir
# In BotPlayer state:
%{..., move_scheduled?: false}

# In handle_info({:state_update, room_code, %{state: game_state, transition_delay_ms: delay_ms}}, state):
if BotBrain.should_make_move?(game_state, state.position) and not state.move_scheduled? do
  next_state = BotBrain.schedule_move_once(state, delay_ms)
  {:noreply, next_state}
end

# In handle_info(:make_move, state):
# ... execute move ...
{:noreply, %{state | move_scheduled?: false}}
```

### 4. Client-Side Transition Delays (Metadata Approach)

Broadcast state updates **immediately** but include `transition_delay_ms` metadata. Clients and bots cooperate to animate/respect the pause. No server-side delayed broadcasts.

```elixir
# In GameAdapter.broadcast_state_update/3, detect transitions and add metadata:
transition_delay_ms = cond do
  trick_completed?(old_state, new_state) ->
    Lifecycle.config(:trick_transition_delay_ms)
  hand_completed?(old_state, new_state) ->
    Lifecycle.config(:hand_transition_delay_ms)
  true ->
    0
end

payload = %{state: new_state, transition_delay_ms: transition_delay_ms}
PubSub.broadcast(..., {:state_update, room_code, payload})
```

**Why client-side, not server-side:** Server-side delayed broadcasts create stale-state problems (a player could act during the delay, making the held broadcast obsolete). Client-side metadata preserves the invariant that every `apply_action` is followed by an immediate state broadcast. Since we control bot code, the cooperative approach is reliable — bots add `transition_delay_ms` to their `schedule_move` delay.

Bots integrate naturally:

```elixir
# In BotBrain.schedule_move, account for transition delay:
def schedule_move(transition_delay_ms \\ 0, opts \\ []) do
  bot_delay = compute_delay(...)
  total_delay = transition_delay_ms + bot_delay
  Process.send_after(self(), :make_move, total_delay)
end
```

### Transition State Detection

Detect transitions by comparing old vs new state fields after engine resolves:
- **Trick completed:** `new_state.current_trick == nil` AND `length(new_state.tricks) > length(old_state.tricks)`
- **Hand completed:** `new_state.hand_number > old_state.hand_number`
- **Game over:** `new_state.phase == :complete` — no delay needed

**Caveat:** The engine's `maybe_auto_transition/1` chains multiple phase transitions synchronously. The server only sees the final state in `broadcast_state_update`. If you need to distinguish trick-complete from hand-complete, compare specific state fields (trick count, hand number) rather than phase names, since intermediate phases are resolved within the same `apply_action` call.

## Technical Considerations

### Architecture

- Pure engine (`pidro_engine`) remains untouched — all pacing is server-side
- `BotBrain.schedule_move/1` already uses `Process.send_after` — extend to accept transition delay parameter
- `BotPlayer` and `SubstituteBot` both need the same pacing updates + dedup flag

### PubSub Broadcast Gotcha

Per documented learning (`docs/plans/2026-02-10-fix-botplayer-crash-on-channel-broadcasts-plan.md`): any GenServer subscribing to game PubSub must handle `%Phoenix.Socket.Broadcast{}` messages. Already handled in `BotPlayer` with catch-all clause.

### No pacing_config Snapshot

The original plan proposed snapshotting pacing config into the Room struct at creation time. This is dropped — bots and GameAdapter read from `Lifecycle.config/1` at the time they need a value. This means admin/env-var changes apply to all rooms immediately, which is acceptable for pacing values (unlike game rules).

## System-Wide Impact

- **Interaction graph:** BotPlayer/SubstituteBot `handle_info({:state_update, room_code, %{state: game_state, transition_delay_ms: delay_ms}})` -> `BotBrain.should_make_move?` -> `schedule_move_once(state, delay_ms)` -> `:make_move` -> `GameAdapter.apply_action`
- **Error propagation:** No delayed broadcasts, so no stale-state risk. If `apply_action` fails for a bot, existing error handling applies.
- **State lifecycle risks:** None introduced — no new timer refs to manage, no server-side state held during delays.
- **API surface parity:** Both `BotPlayer` and `SubstituteBot` need the same pacing updates. `transition_delay_ms` metadata is available to all PubSub subscribers.

## Acceptance Criteria

- [x] Bot action delays use configurable base + random variance from `Lifecycle.config`
- [x] Bot delay never falls below `bot_min_delay_ms` (300ms default)
- [x] `move_scheduled?` flag prevents duplicate `:make_move` scheduling in BotPlayer
- [x] `move_scheduled?` flag prevents duplicate `:make_move` scheduling in SubstituteBot
- [x] State broadcasts include `transition_delay_ms` metadata (1500ms after trick, 3000ms after hand, 0 otherwise)
- [x] Bots add `transition_delay_ms` to their action delay before scheduling moves
- [x] All config keys have corresponding `LIFECYCLE_*` env var overrides in `runtime.exs`
- [x] Tests: bot delay falls within expected range (base +/- variance, floored at min)
- [x] Tests: transition delay metadata is correct for trick/hand completions
- [x] Tests: `move_scheduled?` dedup prevents double-scheduling

## Implementation Phases

### Phase 1: Lifecycle Config (~30m)

**Files:**
- `apps/pidro_server/lib/pidro_server/games/lifecycle.ex` — add 5 pacing keys to `@defaults`
- `config/config.exs` — add pacing defaults
- `config/runtime.exs` — add env var overrides
- Tests for config reading

### Phase 2: Bot Delay Updates + Dedup (~1.5h)

**Files:**
- `apps/pidro_server/lib/pidro_server/games/bots/bot_brain.ex` — add `compute_delay/3`, update `schedule_move` to accept transition delay
- `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex` — use configurable delays, add `move_scheduled?` dedup flag
- `apps/pidro_server/lib/pidro_server/games/bots/substitute_bot.ex` — same changes
- Tests for delay computation, variance bounds, dedup behavior

### Phase 3: Transition Delay Metadata (~1h)

**Files:**
- `apps/pidro_server/lib/pidro_server/games/game_adapter.ex` — detect transitions in `broadcast_state_update`, include room-coded `transition_delay_ms` metadata
- `apps/pidro_server/lib/pidro_server/games/bots/bot_brain.ex` — read `transition_delay_ms` from state update and add to delay
- Tests for transition detection, metadata correctness

## Future Work (Not in MVP)

- **Admin panel** — "Game Pacing" section in `/dev` panel to edit pacing values at runtime. Currently tunable via env vars, which is sufficient.
- **Phase-specific bot delays** — Separate bid vs play delays if testing reveals a need.
- **Game start delay** — Pause after room starts before dealing (2s). Deferred to see if it's actually needed.

## Dependencies & Risks

- **PID-40 (Lifecycle Config):** Already implemented — provides the config pattern to extend
- **PID-30 (SubstituteBot):** Must update SubstituteBot to use new delay config
- **Risk:** `Lifecycle.config/1` is a hot path (called every bot move). Current implementation reads from `Application.get_env` which is ETS-backed and fast. No concern at current scale.

## Sources & References

### Internal References
- Lifecycle config: `apps/pidro_server/lib/pidro_server/games/lifecycle.ex`
- BotPlayer: `apps/pidro_server/lib/pidro_server/games/bots/bot_player.ex`
- SubstituteBot: `apps/pidro_server/lib/pidro_server/games/bots/substitute_bot.ex`
- BotBrain: `apps/pidro_server/lib/pidro_server/games/bots/bot_brain.ex`
- BotManager: `apps/pidro_server/lib/pidro_server/games/bots/bot_manager.ex`
- GameAdapter: `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`
- Runtime config: `config/runtime.exs`
- Bot PubSub crash fix: `docs/plans/2026-02-10-fix-botplayer-crash-on-channel-broadcasts-plan.md`

### Origin
- **Brainstorm:** [docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md](docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md) — Bot delays, dev panel controls, process-per-bot architecture
- **Linear issue:** [PID-43](https://linear.app/boldvideo/issue/PID-43/game-pacing-config-bot-delays-transition-pauses-admin-panel-controls)

### Review Changes Applied
- Dropped `pacing_config` snapshot pattern — read from Lifecycle at move time (simpler, no Room struct changes)
- Switched from server-side delayed broadcasts to client-side metadata approach (eliminates stale-state risk)
- Consolidated config keys from 8 to 5 (merged bid/play delays, dropped separate variance-per-phase)
- Cut admin panel from MVP (env vars sufficient for now)
- Added `move_scheduled?` dedup flag to prevent duplicate bot move scheduling
