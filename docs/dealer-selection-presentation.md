# Dealer-selection timing and catch-up

The dealer-selection ceremony is a presentation of authoritative game state. It
does not control game progression.

## Server contract

Every game-channel join reply and `game_state` event includes one atomic
snapshot:

```json
{
  "game_instance_id": "opaque id",
  "state_revision": 1,
  "server_time_ms": 1788782400000,
  "state": {
    "phase": "dealer_selection",
    "current_dealer": "west",
    "dealer_selection_cuts": {}
  },
  "presentation": {
    "dealer_selection": {
      "started_at_ms": 1788782400000,
      "ends_at_ms": 1788782403000
    }
  }
}
```

- `state.current_dealer` is the outcome. A client must not independently choose
  a dealer from the displayed cards.
- `started_at_ms` and `ends_at_ms` define one shared server-owned window. They
  are unchanged in reconnect and spectator snapshots during that window.
- `server_time_ms` is sampled with the snapshot. Clients should account for
  request/transport time rather than assuming their wall clock matches it.
- `state_revision` increases for every committed state transition. A client
  must ignore revisions less than or equal to the newest revision it has
  accepted for the same `game_instance_id`.
- `presentation.dealer_selection` is `null` before cards are cut and as soon as
  the authoritative phase advances. `dealer_selection_cuts` may remain in later
  game state and must not, by itself, trigger the ceremony.
- No acknowledgement or client barrier extends the deadline. A stalled,
  disconnected, or spectating client never pauses the room.

The default reveal window is 3000 ms. The server advances to bidding when that
window expires even if no client renders it.

## Client presentation

While the active snapshot is `dealer_selection`, show **Choosing the dealer**.
Clearly mark `state.current_dealer` as soon as cuts are present.

At render time, estimate how much of the authoritative window remains:

```text
remaining = ends_at_ms - estimated_server_time_now
```

- With enough time remaining, seek the animation to the corresponding elapsed
  point; do not restart it from zero.
- Near the deadline, skip the cut animation and show the selected dealer as a
  catch-up result for the remaining time.
- If the deadline has passed but the server still reports dealer selection,
  keep the selected dealer visible without replaying animation until a newer
  authoritative snapshot arrives.
- On bidding (or any higher revision with a null presentation), cancel dealer
  animation immediately. The bidding UI may identify the dealer in its normal
  static state, but must not overlay or replay the ceremony.
- Reconnect and late spectator entry follow exactly the same rules and never
  restart the countdown.

## Timing evidence and delay profiles

Before this contract, a controlled run with the production 3000 ms delay
received cuts at +4 ms and bidding at +3005 ms. A client delayed by 2800 ms had
only 205 ms to render the same un-timestamped snapshot. This reproduced the
reported fast/slow mismatch.

Backend tests exercise the contract represented by these four client profiles:

| Profile | Deliberate delay | Expected behavior |
| --- | ---: | --- |
| Fast device | 0 ms | Uses nearly the full shared window |
| iOS simulator | Delayed render | Seeks/catches up; does not start a new 3 s window |
| Android device | Delayed network delivery | Uses the original deadline; catches up or skips |
| Reconnecting player / late spectator | Join during or after the window | Receives the same active deadline or bidding with null presentation |

The backend repository contains no mobile client or device harness, so physical
Android/simulator rendering must be checked in the client repository. The
server-side verification here covers delayed delivery, delayed consumption,
reconnect snapshots, stale update rejection, and progression without consumers.
