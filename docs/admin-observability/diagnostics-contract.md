# Diagnostics contract v1 — draft integration handoff

This is the client/admin contract for `admin-ops/server-diagnostics`. Draft
published before full verification; it is **not** a deployment or review-readiness
claim. All additions are optional for existing mobile builds. No game rule,
action argument, reply, or state payload is replaced. Reports are private.

## Action correlation

On existing `game:<ROOM>` messages, add optional top-level `action_id`:

```json
{"card":{"rank":14,"suit":"spades"},"action_id":"c62317a9-3f4a-418a-b454-38391fdcb242"}
```

Generate a fresh UUID per **attempt**, including repeated taps/retries. The server
accepts strings matching `^[A-Za-z0-9_-]{1,256}$`, truncates to 64 ASCII bytes,
and ignores absent/invalid metadata without rejecting the action. UUIDs fit
without truncation. This is correlation, **not idempotency**; never automatically
retry a timed-out move. Do not send tokens, cards or human-readable messages as IDs.

Instrumented messages: `bid`, `pass`, `declare_trump`, `play_card`, `select_hand`,
`select_dealer`, `ready`, `rematch`, `set_pace`, `continue_hand`, `open_seat`,
`keep_bot`, `close_seat`. Existing reply shapes remain identical; `action_id` is
not echoed. Client push callbacks already know which local attempt they belong to.

Optional game-channel **join** fields: `app_version`, `app_build`, `platform`.
Each is a nonempty ASCII token `[A-Za-z0-9_.:-]`, truncated to 64 bytes, otherwise
omitted. Prefer semver, numeric build, and `ios`/`android`/`web` respectively.
These are untrusted labels, not authoritative identity. Authentication supplies
`user_id`; room membership is unchanged. Never send credentials in these fields.

## Optional state acknowledgement

After consuming a join snapshot or `game_state`, clients may send:

```json
{"game_instance_id":"D4jqEkT8GaWrbl2J","state_revision":17}
```

Event name: `state_received`. Reply: normal channel success `{}` for all payloads,
including malformed/ignored acknowledgements. No protocol requirement depends on
this event. Server logs only acknowledgements for the channel's current instance,
with integer revision 0 through the latest revision sent to that channel.
Duplicates/older revisions are coalesced. At most one event is logged per five
seconds per channel, with no pending timer/task/queue. Acknowledgements in the
interval are dropped, not deferred. The first valid acknowledgement is eligible.
Clients should also coalesce to their newest observed revision every five seconds.
The acknowledgement is a **client claim**, not evidence of rendering or a game
decision; it never changes server revision, turn timers, or gameplay.

## POST /api/v1/game-reports

Send `Content-Type: application/json` and existing `Authorization: Bearer <token>`.
Only authenticated **seated participants** in the specified instance can submit.
Spectators cannot submit. Do not supply a user ID. Required top-level fields:

```json
{
  "room_code":"ABCD",
  "game_instance_id":"D4jqEkT8GaWrbl2J",
  "app_version":"1.2.3",
  "build":"123",
  "platform":"ios",
  "events":[
    {"type":"tap","code":"pending","action":"play_card","offset_ms":0,"action_id":"c62317a9-3f4a-418a-b454-38391fdcb242"},
    {"type":"timeout","code":"unavailable","action":"play_card","offset_ms":5000,"action_id":"c62317a9-3f4a-418a-b454-38391fdcb242"},
    {"type":"state","code":"received","action":"none","offset_ms":5020,"state_revision":17}
  ]
}
```

Limits and exact allowlist:

* Body: at most **32768 bytes**, including chunked requests; JSON object only.
* `room_code`: 4–12 uppercase ASCII letters/digits.
* `game_instance_id`: opaque **non-UUID** string, `[A-Za-z0-9_-]{1,64}`. Copy the
  server snapshot value exactly. A room code is not a game identity: rematches
  and process restarts create new instances; room codes can be reused.
* `app_version`: 1–32 ASCII characters, first a digit, remainder digits/dots/hyphens.
  `build`: 1–20 digits. `platform`: `ios`, `android`, `web`.
* `events`: 1–100 entries in ring-buffer order. No nested payloads/free-text.
* Required event keys: `type`, `code`, `action`, `offset_ms`.
* Optional event keys: `action_id` (`[A-Za-z0-9_-]{1,64}`, no truncation here),
  `state_revision` (integer 0–9007199254740991). Omit unavailable keys; not null.
* `offset_ms`: integer 0–86400000, relative to the first retained client event.
  This is not an authoritative timestamp.
* `type`: `tap`, `blocked`, `push`, `timeout`, `state`, `connection`, `lifecycle`.
* `action`: `bid`, `pass`, `play_card`, `select_card`, `confirm`, `ready`, `join`,
  `leave`, `reconnect`, `none`, `declare_trump`, `select_hand`, `select_dealer`,
  `rematch`, `set_pace`, `continue_hand`.
* `code`: `ok`, `unavailable`, `illegal_action`, `not_your_turn`, `disconnected`,
  `reconnecting`, `connected`, `foreground`, `background`, `resumed`, `paused`,
  `expired`, `stale`, `pending`, `received`, `failed`, `invalid_action`,
  `invalid_phase`, `card_not_in_hand`, `must_follow_suit`, `stale_readiness`,
  `game_unavailable`, `invalid_card`, `action_failed`.

Unknown keys at either level are **rejected**, not silently retained. Never send
hands, card identity, raw state, JWTs, email, passwords, screenshots, exception
text or arbitrary error messages. Map unsupported local reasons to `failed` or
`illegal_action`; do not serialize the source error. Query parameters are ignored.

Responses:

| Status | JSON body / meaning |
|---|---|
| 201 | `{"data":{"id":"<server-generated report UUID>"}}`; id is the `report_id` used in logs/admin lookup |
| 400 | `{"error":"invalid_body"}`; malformed JSON/non-object |
| 413 | `{"error":"invalid_body"}`; oversized body |
| 415 | `{"error":"invalid_body"}`; not application/json |
| 422 | `{"error":"invalid_report"}`; allowlist/type/range violation |
| 403 | `{"error":"not_participant"}`; participation cannot be verified |
| 429 | `{"error":"rate_limited"}` with `Retry-After` seconds |
| 503 | `{"error":"unavailable"}`; quota/authorization/storage dependency failed; no unmetered insert |
| 401 | Existing bearer-auth error envelope (unchanged); missing/invalid/expired/revoked credentials |

Both quotas apply: ten authenticated submission attempts per minute per node
(including invalid reports), and five **stored** reports per rolling hour per
user across nodes. Hourly quota uses Postgres serialization with insertion.
Respect `Retry-After`; never loop/report a failure to report. Reports are not
idempotent: a lost 201 response may leave a stored report. Keep reporting user
initiated and show an unavailable result rather than unbounded automatic retries.

## Participation, archived games and admin access

Current-game verification checks authoritative seated membership and matching
engine instance across stable room observations. Completed-game fallback uses
matching `game_stats.game_instance_id` **and** `room_code`, with the authenticated
user in server-recorded `player_ids`. Null-instance legacy stats never authorize.
Closing the room does not revoke that durable completed-game participation.

Stats are not a complete archive: crashed/abandoned unfinished games and some
replacement histories may have no verified row. Such reports fail closed.
Archive integration is isolated through optional server configuration
`config :pidro_server, :game_report_archive_lookup, ArchiveModule` implementing
`participant?(game_instance_id, room_code, user_id) :: boolean()`. Only literal
`true` authorizes; missing/unavailable lookup must not authorize. The archive orb
must check durable server-written participation for **all three identifiers**,
not current room occupancy. This integration is **not yet verified** against
the archive orb and is not required to compile/start this branch.

Postgres stores only validated data, server-generated report UUID, authenticated
user UUID and server UTC insertion timestamp. `PidroServer.GameReports.admin_get(id)`
and `admin_list(limit \\ 50)` (maximum 100) are read-only **trusted internal context
APIs**. The admin inspector must call them only after existing admin auth. There
is no public GET route, player-channel read, or new admin UI.

Retention default: 30 days. `GameReports.cleanup(limit \\ 1000)` deletes at most
1000 eligible rows per call. Operations must invoke this periodically; this is
not a database TTL. User deletion cascades their reports. Archive retention is
owned elsewhere and may be shorter than report eligibility.

## Structured server events

Each default-handler line is a JSON object with `level` and `timestamp` (Unix
microseconds). Diagnostic records have `event` and `server_build` (`SERVER_BUILD`,
otherwise `unknown`). Global production logging stays `info`. Never index user
IDs as metric labels. Available correlation fields, omitted when unavailable:
`room_code`, `game_instance_id`, `user_id`, `action_id`, `app_version`, `app_build`,
`platform`, `report_id`, `action`, `outcome`, `error_code`, `reason`, `join_type`,
`state_revision`, `observed_revision`, `duration_ms`.

| Event | Meaning / fields |
|---|---|
| `channel_joined` | Successful join, `join_type=new/reconnect`; observed cursor and build labels |
| `channel_closed` | Channel ends; bounded reason, no raw exit payload |
| `action_received` | Handler entered; `action`, optional `action_id`, authenticated user, observed cursor |
| `action_applied` | Engine accepted; **exact atomic resulting** `game_instance_id/state_revision`, engine-call `duration_ms`; no extra snapshot read |
| `action_outcome` | Legacy handler reply; `outcome=accepted/rejected/unknown`, stable `error_code` if present, full handler `duration_ms` |
| `action_failed` | Handler exception/exit; error level, `reason=timeout/process_failure`; behavior is not swallowed or retried |
| `state_broadcast` | Adapter published a revision; same action correlation when action-originated |
| `state_pushed` | Channel pushed that revision to a viewer; correlate through instance/revision/user, not a new action ID |
| `state_received` | Sampled client claim for instance/revision/user |
| `game_process_failed` | Engine timeout/crash/exception; warning/error, bounded reason |
| `state_broadcast_failed` | Broadcast exception; error; does not rewrite an accepted engine result |
| `report_created` | Durable insert completed; server `report_id`, identity, room and instance only; **never report contents** |

`observed_revision` is the socket cursor at receipt, **not** the resulting revision.
Use `action_applied.state_revision` for the latter. Readiness/rematch acceptance
does not necessarily start a game, so its outcome has no fabricated resulting
revision. Subsequent joins/pushes identify the new instance.

Timeout is ambiguous: the engine may apply after the caller times out. Thus
`game_unavailable` outcomes are `unknown`, not asserted rejections. Client push
timeout/local blocks exist only in its ring buffer until reported. Missing ack
logs do not prove packet loss (optional clients, sampling, overload drops).

No provider network calls occur in game processes. Diagnostics logging is
best-effort and nonthrowing. The stdout handler drops at overload instead of
entering synchronous mode (`sync_mode_qlen = drop_mode_qlen = 200`, flush 1000).
Collector/network loss must not change game outcomes; logs are not an audit WAL.
Hosted ingestion is **not configured or claimed active** by this draft.
