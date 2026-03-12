---
title: "feat: Turn Timers — Server-enforced timeouts with auto-play"
type: feat
status: active
date: 2026-03-11
linear: PID-41
origin: docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md
---

# feat: Turn Timers — Server-enforced timeouts with auto-play

## Overview

A player can sit on an actionable game state forever and the game stalls. This feature adds server-enforced timers that auto-play when connected human players take too long.

A timeout is NOT a kick. The player stays seated, the server resolves one safe action for them, and the game advances. Repeated consecutive seat-owned timeouts escalate into the existing disconnect cascade (PID-30).

**Dependency:** Implement PID-43 (Game Pacing) first. This feature consumes `transition_delay_ms` from PID-43 and adds the same delay to the server-side timeout deadline.

## Problem Statement / Motivation

- Connected-but-idle players can stall the table indefinitely
- The server currently enforces disconnects, but not idleness while still connected
- Bots already have action scheduling; humans do not
- Reconnect logic exists, but it does not protect the table from connected non-actors

## Proposed Solution

### Single Action-Window Timer Per Room

Use **one `Process.send_after` per room action window**. The server schedules only the auto-play deadline. Warning and urgent thresholds stay client-side.

When a timer starts, the server broadcasts `turn_timer_started` with `duration_ms`, `transition_delay_ms`, and `server_time`. Clients derive warning and urgent UI locally.

This keeps the server model small:

- 1 timer ref per room
- 1 timeout handler
- 1 timer lifecycle path
- no server-side warning or urgent timers

### Action Window Model

The timer is keyed to an **action window**, not just `current_turn`.

That distinction matters because this engine can produce:

- a new actionable state for the same position in the same phase
- a non-turn-based `:dealer_selection` phase where any player may act
- reconnects where the same actionable state remains active without a `state_update`

Define the action-window key as:

```elixir
{:seat, position, phase, event_seq}
{:room, :dealer_selection, event_seq}
```

Where `event_seq = length(game_state.events)`.

Using `event_seq` makes the key advance even when the same player keeps control after a successful action, for example when a trick winner leads the next trick.

### Seat-Owned vs Room-Owned Timers

There are two timer scopes:

- **Seat-owned timer:** `{:seat, position, phase, event_seq}` for phases with exactly one actionable connected human seat
- **Room-owned timer:** `{:room, :dealer_selection, event_seq}` for all-human dealer selection

Seat-owned timers count toward consecutive timeout escalation. Room-owned timers do not.

### Timer Durations

- **Bidding:** 45s
- **Playing:** 30s
- **Declaring:** 30s
- **Second deal:** 30s
- **Dealer selection:** 30s, but only as a room-owned timer on all-human tables

Dealer selection is special because the engine treats it as non-turn-based. Any player may submit `:select_dealer`, so this timer cannot belong to a seat and must not increment any seat's timeout count.

### RoomManager Owns Timer Orchestration

`RoomManager` owns timer lifecycle because it already owns:

- room seat state
- disconnect cascade state
- room cleanup
- substitute joins and reconnect flows

To make this work, `RoomManager` must subscribe to each active room's game PubSub topic when the game starts, and unsubscribe when the room closes or is removed.

Add to `RoomManager.State`:

```elixir
field :subscribed_game_topics, MapSet.t(), default: MapSet.new()
field :channel_pids, map(), default: %{}
field :channel_monitors, map(), default: %{}
```

Where:

- `subscribed_game_topics` tracks room codes the `RoomManager` process subscribed to
- `channel_pids` is `%{{room_code, user_id} => MapSet.t(pid())}`
- `channel_monitors` is `%{monitor_ref => {room_code, user_id, pid}}`

Store timer data in the `Room` struct:

```elixir
# In Room struct:
field :turn_timer, map() | nil, default: nil
field :paused_turn_timer, map() | nil, default: nil
field :consecutive_timeouts, map(), default: %{}
```

Suggested shapes:

```elixir
%{
  ref: ref,
  timer_id: timer_id,
  key: {:seat, :north, :playing, 42},
  scope: :seat,
  actor_position: :north,
  phase: :playing,
  duration_ms: 30_000,
  transition_delay_ms: 1_500,
  started_at_mono: 123_456,
  deadline_mono: 154_956
}

%{
  key: {:seat, :north, :playing, 42},
  actor_position: :north,
  phase: :playing,
  remaining_ms: 18_250
}
```

### TurnTimer Module

```elixir
defmodule PidroServer.Games.TurnTimer do
  @moduledoc """
  Manages one active room action timer.
  """

  def start_timer(target_pid, room_code, key, scope, actor_position, phase, duration_ms, transition_delay_ms \\ 0) do
    timer_id = System.unique_integer([:positive, :monotonic])
    total_ms = duration_ms + transition_delay_ms
    started_at_mono = System.monotonic_time(:millisecond)
    deadline_mono = started_at_mono + total_ms

    ref =
      Process.send_after(
        target_pid,
        {:turn_timer_expired, room_code, timer_id, key},
        total_ms
      )

    %{
      ref: ref,
      timer_id: timer_id,
      key: key,
      scope: scope,
      actor_position: actor_position,
      phase: phase,
      duration_ms: duration_ms,
      transition_delay_ms: transition_delay_ms,
      started_at_mono: started_at_mono,
      deadline_mono: deadline_mono
    }
  end

  def cancel_timer(nil), do: :ok
  def cancel_timer(%{ref: ref}), do: Process.cancel_timer(ref)

  def pause_timer(nil), do: nil

  def pause_timer(%{key: key, actor_position: actor_position, phase: phase, deadline_mono: deadline_mono}) do
    now_mono = System.monotonic_time(:millisecond)

    %{
      key: key,
      actor_position: actor_position,
      phase: phase,
      remaining_ms: max(deadline_mono - now_mono, 0)
    }
  end
end
```

### Action Window Detection

Add a `current_action_window/2` helper in `RoomManager`:

```elixir
defp current_action_window(room, game_state) do
  event_seq = length(game_state.events)

  cond do
    game_state.phase == :dealer_selection and all_human_table?(room) ->
      actor_position = first_connected_human_position(room)

      if actor_position do
        {:ok, {:room, :dealer_selection, event_seq}, :room, actor_position, :dealer_selection}
      else
        :none
      end

    game_state.phase in [:bidding, :declaring, :playing, :second_deal] ->
      position = game_state.current_turn
      seat = position && room.seats[position]

      if seat && Seat.connected_human?(seat) && Engine.legal_actions(game_state, position) != [] do
        {:ok, {:seat, position, game_state.phase, event_seq}, :seat, position, game_state.phase}
      else
        :none
      end

    true ->
      :none
  end
end
```

Key rules:

- `:dealer_selection` is timer-eligible only on all-human tables
- if the actionable seat is disconnected, reconnecting, a bot, or bot-substituted, do not start a human timer
- if legal actions are empty, do not start a timer
- automatic phases never get timers

### State Update Handling

`RoomManager` needs the emitting room code. Update the game PubSub message shape to include it:

```elixir
{:state_update, room_code, %{state: game_state, transition_delay_ms: ms}}
{:state_update, room_code, game_state}
```

During rollout, `RoomManager`, `GameChannel`, `BotPlayer`, and `SubstituteBot` should all accept both payload variants, but the `room_code` wrapper is required.

On each state update:

1. Load the room by `room_code`
2. Extract `game_state` and `transition_delay_ms`
3. Compute `current_action_window(room, game_state)`
4. Compare it to `room.turn_timer.key`
5. Reconcile the timer

Reconciliation rules:

- **Same key, active timer exists:** keep the timer
- **Different key, active timer exists:** cancel old timer, clear `paused_turn_timer`, start new timer if new window exists
- **No active timer, new window exists:** start timer
- **No new window:** cancel old timer and clear paused timer
- **Paused timer exists and reconnect restored the same key:** resume using paused remaining time plus reconnect extension

### When Timers Start

Start or resume a timer when:

1. The action-window key changes to a timer-eligible window
2. The first post-start `:dealer_selection` state arrives for an all-human room
3. A reconnect restores a seat-owned action window whose timer was paused on disconnect

This is intentionally broader than "when `current_turn` changes".

### When Timers Cancel or Pause

- **Cancel** on game completion
- **Cancel** on room cleanup or room close
- **Cancel** when a new action window replaces the old one
- **Pause** when the active timed seat disconnects
- **Drop paused timer** if the action window changes while the player is disconnected

### Reconnect Semantics

Do not reset the turn timer on reconnect.

If the timed player disconnects while owning a seat-owned action window:

1. Cancel the active timer
2. Store `paused_turn_timer.remaining_ms`
3. Let PID-30 handle disconnection state as usual

If that player reconnects and the same action window is still active:

```elixir
resume_ms =
  min(
    configured_duration_ms,
    paused_remaining_ms + Lifecycle.config(:reconnect_turn_extension_ms)
  )
```

This uses the already-existing `reconnect_turn_extension_ms` config. It avoids timer-reset abuse while still giving reconnecting players a short grace top-up.

If the action window changed while they were gone, drop the paused timer and do not resume it.

### Auto-Play via TimeoutStrategy

Reuse the existing bot strategy interface for timeout auto-play.

```elixir
defmodule PidroServer.Games.Bots.TimeoutStrategy do
  @behaviour PidroServer.Games.Bots.Strategy

  def pick_action(legal_actions, game_state) do
    action =
      case game_state.phase do
        :bidding -> :pass
        :declaring -> pick_declared_trump(game_state)
        :playing -> pick_lowest_legal_trump(legal_actions, game_state)
        :second_deal -> {:select_hand, :choose_6_cards}
        :dealer_selection -> :select_dealer
      end

    {:ok, action, "timeout auto-play"}
  end
end
```

Concrete rules:

- **Bidding:** always `:pass`
- **Declaring:** choose the suit with the highest count in the player's hand; tie-break by highest total point value under that suit; final tie-break by fixed suit order
- **Playing:** choose the lowest legal trump using `Card.compare/3`
- **Second deal:** return `{:select_hand, :choose_6_cards}` and let existing `BotBrain.resolve_action/3` call `DealerRob.select_best_cards/2`
- **Dealer selection:** `:select_dealer`

For room-owned dealer-selection auto-play, submit `:select_dealer` using the first connected human position in seat order. That action does not increment any timeout counter.

### Timeout Resolution Path

When `{:turn_timer_expired, room_code, timer_id, key}` fires:

1. Load the room
2. Confirm `room.turn_timer.timer_id == timer_id`
3. Confirm `room.turn_timer.key == key`
4. Fetch current game state
5. Recompute the current action window and confirm it still matches
6. Pick the timeout action
7. Call `GameAdapter.apply_action(room_code, actor_position, action)`

If `apply_action` returns:

- `{:ok, _state}`: success path
- `{:error, {:not_your_turn, _}}`: stale/raced timeout, discard silently
- `{:error, :game_already_complete}`: discard silently
- `{:error, :not_found}`: room/game already gone, discard silently
- any other error: log at `:debug`, not `:warning`

The `Pidro.Server` GenServer serializes action application, so at most one of the real action or timeout auto-play can win.

### Consecutive Timeout Tracking

Track seat-owned timeouts in `Room.consecutive_timeouts`.

Increment only when:

- the timer scope is `:seat`
- the timeout auto-play succeeds
- the seat is still a connected human

Do NOT increment for:

- room-owned dealer-selection auto-play
- disconnected or bot-substituted seats
- raced/stale timeout messages

Reset a seat's counter when:

- the seat submits a voluntary valid action
- the seat reconnects successfully
- a substitute human fills the seat
- a new hand begins
- a new game starts in the room

### Third-Strike Escalation

At `count >= Lifecycle.config(:consecutive_timeout_threshold)`:

1. Broadcast `turn_auto_played`
2. Force-close the registered game channel pid(s) for that `{room_code, user_id}`
3. Let `GameChannel.terminate/2` enter the normal disconnect cascade

Do NOT call `Seat.disconnect/1` directly on a connected seat for this path. We want the real channel shutdown path, not an in-memory seat mutation that leaves the socket alive.

### Room-Scoped Channel Targeting

Do not use `UserSocket.id/1` and disconnect the whole websocket. That is too broad and would drop unrelated channels or devices.

Instead:

- `GameChannel.join/3` registers `self()` with `RoomManager`
- `GameChannel.terminate/2` unregisters
- `RoomManager` monitors registered channel pids and prunes stale entries on `:DOWN`
- `RoomManager` sends `{:force_disconnect, :timeout_threshold}` to the game channel pid(s) for that room/user only

If no live game channel pid is registered at threshold time, call the same internal disconnect helper used by `handle_player_disconnect/2` so the room still enters PID-30 cleanly.

### Client Contract

PID-42 is the client ticket for our client applications. This plan defines the server contract those clients consume.

Clients need both live events and join-time hydration.

#### Live Events

```elixir
turn_timer_started: %{
  timer_id: 123,
  scope: :seat,
  position: :north,
  phase: :playing,
  duration_ms: 30_000,
  transition_delay_ms: 1_500,
  server_time: "2026-03-11T12:34:56.789Z",
  event_seq: 42
}

turn_timer_cancelled: %{
  timer_id: 123,
  scope: :seat,
  position: :north,
  reason: :acted
}

turn_auto_played: %{
  scope: :seat,
  position: :north,
  phase: :playing,
  action: %{type: :play_card, card: %{rank: 2, suit: :hearts}},
  reason: :timeout
}
```

For room-owned dealer selection:

- `scope: :room`
- `position: nil`
- `phase: :dealer_selection`

#### Join / Rejoin Hydration

Add `turn_timer` to the `GameChannel` join reply:

```elixir
turn_timer: nil | %{
  timer_id: 123,
  scope: :seat,
  position: :north,
  phase: :playing,
  duration_ms: 30_000,
  transition_delay_ms: 1_500,
  server_time: "2026-03-11T12:34:56.789Z",
  remaining_ms: 18_250,
  event_seq: 42
}
```

This is required so:

- reconnecting players can rehydrate the countdown
- spectators joining mid-turn can render the active timer
- clients do not depend on having observed the original `turn_timer_started` event

Clients still compute warning and urgent thresholds locally.

## Technical Considerations

### Lifecycle Config

Add three new keys:

```elixir
turn_timer_bid_ms: 45_000,
turn_timer_play_ms: 30_000,
consecutive_timeout_threshold: 3,
```

Use the existing `reconnect_turn_extension_ms` key for reconnect resumes. No new reconnect config is needed.

### Card Ranking for Auto-Play

Do not reference a non-existent `Card.trump_rank/2`.

Use `Card.compare/3` to sort legal trump cards and pick the lowest legal card for timeout auto-play.

### Interaction with PID-43 Transition Delays

PID-43 broadcasts state updates immediately with `transition_delay_ms`. This plan keeps the same invariant:

```elixir
state_update(payload_with_transition_delay)
  -> RoomManager starts timer with total delay = transition_delay_ms + duration_ms
  -> Client animates for transition_delay_ms
  -> Client renders countdown for duration_ms
  -> Server auto-plays at total deadline
```

No delayed state broadcasts are introduced here.

### Phoenix PubSub Gotcha

Once `RoomManager` subscribes to `game:<room_code>`, it will receive both direct game messages and channel broadcasts on the same topic. Add a `%Phoenix.Socket.Broadcast{}` ignore clause just like the bot processes already do.

### Stale Timer Guard

Use `timer_id` plus `key` in the timeout message and compare both against the current room timer before acting. This is stricter and clearer than comparing only timestamps.

### Timeout Ordering

On a successful seat-owned timeout:

1. clear active timer
2. increment timeout counter
3. broadcast `turn_auto_played`
4. if threshold reached, force-disconnect game channel pid(s)
5. rely on the resulting `terminate/2` to trigger PID-30
6. let the subsequent `state_update` start the next timer if needed

This guarantees the timed-out player sees the final timeout event before their channel is shut down.

## System-Wide Impact

- `RoomManager` becomes a game-topic subscriber for active rooms
- `GameChannel` gains pid registration, join hydration, and a forced-disconnect handler
- timeout logic reuses the existing `GameAdapter.apply_action/3` validation path
- reconnect flow now resumes a paused timer instead of silently resetting it
- dealer selection gets a room-scoped safety net on all-human tables

## Acceptance Criteria

- [x] `RoomManager` subscribes to each active room's game topic on game start and unsubscribes on room removal
- [x] Game PubSub `state_update` messages include `room_code`
- [x] `RoomManager`, `GameChannel`, `BotPlayer`, and `SubstituteBot` handle both `{:state_update, room_code, state}` and `{:state_update, room_code, %{state: state, transition_delay_ms: ms}}`
- [x] One active server timer exists per room action window
- [x] The timer key uses action-window scope plus `event_seq`, not just `current_turn`
- [x] Seat-owned timers start for connected human action windows in `:bidding`, `:declaring`, `:playing`, and `:second_deal`
- [x] Room-owned timer starts for all-human `:dealer_selection`
- [x] Bot seats never get human turn timers
- [x] A disconnected timed seat pauses its timer and stores remaining time
- [x] Reconnect resumes the same timer window using `paused_remaining_ms + reconnect_turn_extension_ms`, clamped to configured duration
- [x] If the action window changed while disconnected, the paused timer is discarded
- [x] Join and rejoin replies include `turn_timer` hydration when a timer is active
- [x] `turn_timer_started` includes `duration_ms`, `transition_delay_ms`, `server_time`, `scope`, and `event_seq`
- [x] Auto-play uses `TimeoutStrategy` and passes through `GameAdapter.apply_action/3`
- [x] Playing timeout chooses the lowest legal trump using `Card.compare/3`
- [x] Dealer-selection timeout submits `:select_dealer` without incrementing any seat timeout counter
- [x] Race-condition failures from timeout auto-play are silently discarded
- [x] Seat-owned successful timeout increments that seat's counter
- [x] Counters reset on voluntary action, successful reconnect, substitute human join, new hand, and new game
- [x] Third strike force-closes only the game channel pid(s) for that room/user, not the whole user socket
- [x] If no channel pid is registered, the same internal disconnect helper is used as a fallback
- [x] Timer refs and channel-pid registrations are cleaned up on room teardown
- [x] Tests cover room-scoped dealer selection, reconnect resume, same-position-same-phase new action windows, channel targeting, and stale timeout messages

## Implementation Phases

### Phase 1: State Model + Config

**Files:**
- `apps/pidro_server/lib/pidro_server/games/lifecycle.ex`
- `config/config.exs`
- `config/runtime.exs`
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

**Work:**
- add timer config keys
- use existing `reconnect_turn_extension_ms`
- add `turn_timer`, `paused_turn_timer`, and `consecutive_timeouts` to `Room`
- add `subscribed_game_topics`, `channel_pids`, and `channel_monitors` to `RoomManager.State`

### Phase 2: RoomManager PubSub + Action Window Reconciliation

**Files:**
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`

**Work:**
- subscribe `RoomManager` on game start
- unsubscribe on room removal
- update game PubSub `state_update` messages to include `room_code`
- add `handle_info({:state_update, room_code, ...})`
- ignore `%Phoenix.Socket.Broadcast{}`
- implement `current_action_window/2`
- implement timer reconcile / pause / resume logic

### Phase 3: TurnTimer + TimeoutStrategy

**Files:**
- `apps/pidro_server/lib/pidro_server/games/turn_timer.ex` (NEW)
- `apps/pidro_server/lib/pidro_server/games/bots/timeout_strategy.ex` (NEW)
- `apps/pidro_server/lib/pidro_server/games/bots/bot_brain.ex`

**Work:**
- start/cancel/pause timer helpers
- timeout action selection
- reuse `BotBrain.resolve_action/3` for dealer-rob hand selection

### Phase 4: Channel Registration + Forced Disconnect

**Files:**
- `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`
- `apps/pidro_server/lib/pidro_server/games/room_manager.ex`

**Work:**
- register/unregister channel pid per room/user
- monitor channel pids
- handle `{:force_disconnect, :timeout_threshold}`
- make forced disconnect reason render as timeout, not generic connection loss
- use the same internal disconnect helper as normal channel termination

### Phase 5: Client Contract + Tests

**Files:**
- `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`
- `apps/pidro_server/test/pidro_server/games/room_manager_test.exs`
- `apps/pidro_server/test/pidro_server_web/channels/game_channel_test.exs`
- new tests for `TurnTimer` and `TimeoutStrategy`

**Work:**
- add `turn_timer` join hydration
- broadcast timer lifecycle events
- cover reconnect resume, dealer-selection timeout, threshold disconnect, and same-position repeated action windows

## Future Work (Not in MVP)

- telemetry events for timer start, cancel, pause, resume, and auto-play
- per-game timer processes if RoomManager ever becomes a bottleneck
- richer timeout analytics in admin tooling

## Dependencies & Risks

- **PID-43 (Game Pacing):** required first; this plan depends on `transition_delay_ms` and extends the `state_update` payload contract to include `room_code`
- **PID-30 (Disconnect Cascade):** escalation target after repeated consecutive timeouts
- **PID-42 (Client Turn Timer UI):** client-app Linear ticket that consumes the server contract defined here
- **Risk:** `RoomManager` becomes a subscriber for every active room topic. Message volume is still low at this scale, but `%Phoenix.Socket.Broadcast{}` must be ignored explicitly.
- **Risk:** reconnect resume is easy to get subtly wrong. Tests must prove no timer reset abuse and no stale paused timer carry-over.
- **Risk:** channel pid registration can leak if not monitored. `:DOWN` cleanup is required.
- **Risk:** dealer-selection timeout is room-scoped while other timers are seat-scoped. That distinction must stay explicit in event payloads and acceptance tests.

## Sources & References

### Internal References

- `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- `apps/pidro_server/lib/pidro_server/games/game_adapter.ex`
- `apps/pidro_server/lib/pidro_server/games/lifecycle.ex`
- `apps/pidro_server/lib/pidro_server/games/room/seat.ex`
- `apps/pidro_server/lib/pidro_server/games/bots/bot_brain.ex`
- `apps/pidro_server/lib/pidro_server_web/channels/game_channel.ex`
- `apps/pidro_server/lib/pidro_server_web/channels/user_socket.ex`
- `apps/pidro_engine/lib/pidro/game/engine.ex`
- `apps/pidro_engine/lib/pidro/game/dealing.ex`
- `apps/pidro_engine/lib/pidro/game/dealer_rob.ex`
- `apps/pidro_engine/lib/pidro/core/card.ex`
- `docs/plans/2026-03-11-001-feat-game-pacing-bot-delays-transition-pauses-plan.md`
- `docs/plans/2026-02-10-fix-botplayer-crash-on-channel-broadcasts-plan.md`

### Origin

- **Brainstorm:** [docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md](docs/brainstorms/2026-02-09-bot-system-and-dev-control-brainstorm.md)
- **Linear issue:** [PID-41](https://linear.app/boldvideo/issue/PID-41/turn-timers-server-enforced-timeouts-with-auto-play)

### Review Changes Applied

- replaced turn-change detection with action-window detection
- made `:dealer_selection` explicitly room-scoped instead of seat-scoped
- added `RoomManager` PubSub subscription ownership and cleanup
- added reconnect pause/resume semantics using existing `reconnect_turn_extension_ms`
- replaced whole-socket disconnect with room-scoped game-channel pid targeting
- added join-time timer hydration for reconnecting players and spectators
- replaced nonexistent `Card.trump_rank/2` with `Card.compare/3`
- clarified counter reset rules and third-strike ordering
