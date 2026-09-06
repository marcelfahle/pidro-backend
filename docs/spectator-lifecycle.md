# Spectator admission and reconnect (PID-79)

RoomManager owns membership, network cleanup, and admission. `Room.Seat` owns
seat transitions; the card engine does not decide who may occupy a seat.

## Invariants

- A game channel join attaches to an existing player/reservation or watch. It
  never claims a vacancy, even if join parameters request a player role.
- `POST /rooms/:code/join` is explicit player intent. In a playing room it uses
  the existing substitute transition, validating membership, lock, kick status,
  and vacancy in one RoomManager callback. Failed admission preserves watching.
- A successful claim ends the account's watch (also if watching another room),
  revokes old watcher channels, and publishes the final seat/membership state.
  An account cannot be both an active player and spectator.
- Watch is idempotent for the same room. Unwatch is scoped to its URL room.
- Watcher channels are monitored separately from player channels. Only the last
  registered watcher transport closing starts expiry. Duplicate unregisters and
  old monitor messages cannot disconnect a player or delete a newer watch.
- Watch admission without attachment and last-channel disconnect both expire
  after `Lifecycle.grace_timeout_ms` (120 seconds by default). Attachment cancels
  expiry; timer-reference fencing rejects already-queued stale timer messages.
  After expiry a user must explicitly Watch again, never implicitly Join.
- Public seat availability comes from vacant `Room.Seat` occupants, not missing
  human IDs in `positions`. Bots are not vacancies. Locks suppress public Join,
  not existing players' reserved-seat reconnection or spectator admission.
- Initial lobby categories and incremental categories use the same server
  function. A null category means remove the room from actionable categories.

## Compatibility and rollout

Ship the server and frontend PRs together. Older mobile clients that navigate
directly for Substitute will receive an authorization error rather than acquire
a seat. The replacement client calls REST Join before navigating. Existing
players reconnect without new admission; existing Watch clients need no new
channel parameters. No unsafe legacy vacancy fallback is retained.

## Regression coverage

- `game_channel_test.exs`: E4W2's two departures, Keep Bot dismissal, delayed Open
  Seat, concurrent players/watchers, spectator broadcast, watcher reconnect,
  rejected role-parameter claim, explicit substitute admission, lobby updates.
- `spectator_lifecycle_test.exs`: multiple transports, repeated/reordered cleanup,
  killed and never-attached watchers, finite expiry, rewatch/cross-room fencing,
  failed claims, simultaneous claims, lock validation, membership exclusivity,
  canonical availability, room teardown.
- `room_controller_test.exs`: authenticated Watch/Join/Unwatch HTTP contract.

Mixed native-device QA still requires current iOS and Android builds plus web:
repeat the E4W2 sequence, background/foreground both watchers while a seat is
open, then explicitly claim it. Verify unchanged watcher roles, one winner,
and updated Join/Watch availability on all three clients. The distinct frozen
replacement-bot failure is PID-80, not fixed by this change.
