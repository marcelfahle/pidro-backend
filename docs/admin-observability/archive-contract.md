# Game archive v1 — inspector integration contract

Draft handoff on `admin-ops/game-archive`, published before full verification.
This is not a deployment or review-readiness claim. The context below is
`PidroServer.GameArchive`. No HTTP route, channel event, or admin screen is added.
**All reads are trusted internal APIs.** The inspector must use the existing
admin session/password-change authentication. Never send these private hands,
decks, chance streams, or events to a lobby, player, spectator, or client report.

## Exact read APIs

```elixir
alias PidroServer.GameArchive

GameArchive.search(
  from: ~U[2026-10-01 00:00:00Z], # optional, started_at >= from
  to: ~U[2026-11-01 00:00:00Z],   # optional, started_at < to
  user_id: "authenticated-user-uuid", # optional, durable seated participation union
  room_code: "ABCD",              # optional, exact match
  game_instance_id: "opaque-id",  # optional, exact match, NOT a UUID
  status: "closed",              # optional: active/complete/closed/interrupted
  limit: 50                      # default 50, allowed 1..100
)
# => [summary_map, ...], newest started_at then game_instance_id first
# Next page: same filters plus before: {last.started_at, last.game_instance_id}

GameArchive.get(instance_id)                    # => summary_map | nil
GameArchive.snapshot(instance_id)               # => last saved snapshot | nil
GameArchive.snapshot(instance_id, :latest)      # same
GameArchive.snapshot(instance_id, :initial)     # pre-action snapshot | nil
GameArchive.snapshot(instance_id, :initial_deal) # first actual deal | nil
GameArchive.snapshot(instance_id, 17)           # exact saved revision 17 | nil

GameArchive.events(instance_id, after_revision: -1, limit: 50)
# => [%PidroServer.GameArchive.Event{}, ...], ascending authoritative revision
# Exclusive integer cursor; -1 includes revision 0. limit defaults50, range1..100.
# Next page: after_revision: List.last(page).revision. Empty list ends history.

GameArchive.step(instance_id, 17) # => next saved Event after17 | nil
# Step through saved facts, NOT a call to the engine. May skip missing revisions.

GameArchive.health(room_code)
# => {:ok, %{status: :healthy | :degraded, failures: integer,
#            last_acknowledged_revision: integer | nil, state_revision: integer}}
# => {:error, :not_found | :unavailable} when no live process or lookup times out
```

Missing/expired instances return nil or an empty event page. DB read failures
raise; the inspector should show unavailable, not “no history.” Invalid options
are programmer errors, not normalized client input. Summary aliases remain
`summary/1`, `last_snapshot/1`, `initial_snapshot/1`, and `initial_deal/1`.

Summary maps have atom keys: `game_instance_id`, `room_code`, `format_version`
(1), `versions`, `participants`, `status`, `termination_reason`, `last_revision`,
`started_at`, `saved_at`, `ended_at`, `evidence_status`, `failed_checkpoints`,
`missing_revision_count`, `user_ids`, `participation_truncated`.
Timestamps are UTC `DateTime` values; ended_at is nil
while active. Summary queries do not load snapshots.

`participants` is a string-keyed map by `north/east/south/west` containing the
**initial** seat facts: `position`, `occupant_type`, `user_id`, `status`,
`is_owner`, `substitute`, `disconnected_at`, `grace_expires_at`,
`has_reservation`, `joined_at`, `bot_persona`; vacant seats may have `vacated_by`.
No bot PID, email, credentials, or room/seat password is stored. This version
does not claim a complete mid-game seat-occupancy timeline. Separate `user_ids`
is the durable union of initial and later seated humans for this instance;
initial `participants` never changes. The union is capped at 256 distinct users;
overflow sets sticky `participation_truncated: true`, rather than silently
claiming exhaustive participation. Spectators and bot identities are excluded.

`versions` contains string keys `server`, `engine` (application versions),
`server_code`, `engine_code` (SHA256 over sorted module names and BEAM MD5s),
`otp`, `elixir`. Code fingerprints distinguish builds even when app versions
have not changed. They are cached at application startup, not calculated per move.

Each Event struct has `game_instance_id`, `revision`, `occurred_at`, `saved_at`,
`payload`, `snapshot`. Occurred_at is the server snapshot time; saved_at is the
write-attempt timestamp, not a claimed exact WAL commit instant. A payload has
`kind` (`start`, `action`, `initial_deal`, `pace`, `continue_hand`,
`presentation_cleared`, `reset`, `replace_state`), `engine_events` in engine
chronological order, `events_replaced` boolean, and optional `position`, `action`,
`pace`. `reset`/`replace_state` replace, rather than append, the engine event list.
An optional `missing_revisions: [first, last]` marks an inclusive missing range
immediately before this checkpoint. Final closure is summary metadata, not a
fabricated engine revision/event. Use summary status together with the timeline.

## JSON serialization, no engine execution required

Snapshots are string-keyed JSON objects:

```json
{"game_instance_id":"opaque-id","state_revision":17,
 "state":{"$struct":"Elixir.Pidro.Core.Types.GameState","variant":"finnish"},
 "presentation":{"dealer_selection":null,"dealer_rob":null}}
```

The state example is abbreviated: every authoritative state field is saved
except `events` (stored as ordered deltas in Event payloads). This includes hands,
remaining deck order, dealer cuts, discards, killed cards, tricks, scores, hand
history, variant config and exported chance state. Every accepted state revision
attempts a full checkpoint, including automatic deal/presentation transitions.
Initial_deal separately retains the first dealt state for recovery after an early
write failure. It is nil before dealing or if that evidence never reached storage.

Encoding v1 is data-only; viewers must not create atoms or instantiate structs:

| Source | JSON |
|---|---|
| nil / booleans / strings / floats | null / booleans / strings / numbers |
| atoms | strings, e.g. `north` |
| integer with absolute value <=9007199254740991 | JSON number |
| larger integer | `{"$integer":"117085240290607817"}` (exact decimal) |
| tuple, including card `{14, :hearts}` | `{"$tuple":[14,"hearts"]}` |
| proper list | array |
| improper list `[1 | 2]` | `{"$improper_list":[1],"$tail":2}` |
| map | object; atom/integer keys become strings |
| struct | object of fields plus `$struct` module-name string |
| MapSet | `{"$set":[...]}` (set order has no meaning) |
| DateTime | ISO8601 UTC string |
| PID / reference / function / unsupported key | rejected; capture fails safely |

There is no `binary_to_term`, Erlang binary payload, or executable decoder.
**Full deterministic engine replay is not implemented.** `step/2` is checkpoint
navigation, not resimulation. The exact shuffled facts and chance stream are
saved, but future engine/OTP versions are not assumed compatible. Snapshot and
timeline inspection needs only this JSON contract, even without the old engine.
Retain a renderer for each supported format_version; show unknown fields as data.

## Outcome and evidence are separate

`status`: `active` means no durable terminal observation; `complete` means a saved
engine state reached complete; `closed` means explicit room/process closure;
`interrupted` means reconciliation found no matching live instance. Reasons are
`engine_complete`, `room_closed`, and `process_missing`. For interrupted games,
ended_at is **detection time**, not a known crash time. Ordinary multiplayer
departure does not close the continuing game's archive. Rematch starts a new
process and instance, even with the same room code. Completion is never
relabelled closed by later room teardown.

`evidence_status`:

* `continuous`: all revisions through last_revision are present and no known
  write uncertainty. **Not a promise that last_revision is the current live tail.**
* `partial`: one or more exact revision ranges are missing. Later success never
  clears this label; missing_revision_count counts missing checkpoint revisions.
* `uncertain`: a write failed/timed out with unknown commit outcome, or a process
  disappeared without a saved closure. No known interior gap is required.

Gameplay continues if archive persistence fails. One isolated monitored worker per
serial game callback waits at most 50ms (plus BEAM scheduling/process cleanup),
then is killed; SQL statements also have a 40ms timeout. Worker creation does not
call a shared task supervisor. No accumulating retry
queue or overlapping per-game tasks. Failures generate bounded power-of-two
warning logs containing only instance/revision and a `[:pidro,:archive,:failure]`
telemetry counter with no identity labels. `health/1` reports current live write
health; durable failed_checkpoints is updated on recovery. A healthy writer can
have permanently partial historical evidence.

The engine retains its initial snapshot, first deal, latest cause, bounded human
participation union and failure count, not all failed transitions. Seat changes
attempt persistence immediately without inventing an engine revision. The room
manager waits at most 200ms for this serialized operation; exit/timeout does not
reject the seat transition. Next action/timer/closure retries current
evidence. DB last_revision and live last_acknowledged_revision can differ after
an ambiguous timeout. Duplicate identical revisions are idempotent; conflicting
duplicates are rejected, never overwritten. Newer writes identify missing ranges.
Failed closure leaves the last durable record active until reconciliation marks
it interrupted. If DB is unavailable for an entire game's lifetime, **no durable
archive can be promised**; logs may be the only surviving evidence. No successful
write, full coverage, completion or exact crash reason is fabricated.

Reconciliation uses the current **single-serving-node** GameRegistry topology.
It waits 120s after application start (longer than current Kamal 60s deployment /
30s drain), then scans at most 100 active IDs per 60s tick with an exclusive cursor.
It also excludes archives saved in the last 120s, so an old container's running
sweeper cannot interrupt new games on the replacement during the bounded overlap.
It skips busy/unreachable processes rather than treating a timeout as death.
DB failures retry on a later tick. This is not a distributed ownership/lease
protocol: add one before serving games on multiple nodes or allowing longer
deployment overlap. No game process is resumed from an archive.

## Diagnostics participation adapter

```elixir
config :pidro_server, :game_report_archive_lookup, PidroServer.GameArchive

GameArchive.participant?(game_instance_id, room_code, user_id) # => boolean
```

The branch supplies this config. Lookup requires an exact match on **all three**
against the durable server-written **seated participation union**, not current room
occupancy, stats or client claims. Returns false for missing/expired evidence,
spectators, a different room/instance/user, or non-string arguments. A DB error
raises so GameReports can return unavailable; it never authorizes on failure.
Mid-game replacement participants remain eligible after leaving/closure. The
room manager supplies actual human seats, never a client-supplied identity list.
A failed write retains the bounded union in the live game for the next capture;
if the process dies before that membership is durable, lookup conservatively
denies the missing user. Truncated users beyond the cap are likewise denied.
General evidence health and participation_truncated disclose these limitations;
the lookup never guesses membership. No module from the diagnostics branch is
required to compile this archive branch.

## Retention and migration

`cleanup(retention_days: 30, batch_size: 100)` returns `{deleted_archives, nil}`.
Allowed days1..3650 and batch1..1000. It deletes only terminal archives older
than ended_at cutoff, cascading their event rows. Active/fresh games and all
long-term game_stats/ratings are untouched. Maintenance invokes one bounded
cleanup each tick. Configure `PidroServer.GameArchive.Maintenance` with
`enabled: true`, `interval_ms: 60_000` (minimum1000), `retention_days: 30`,
`batch_size: 100`. Tests disable the timer and drive reconciliation explicitly.

Migration `20261022120100_create_game_archives` adds only two new tables,
indexes and an archive-status constraint. No existing data backfill or stats
alteration. Migrate before enabling the new code; otherwise capture degrades
without stopping games. Rollback drops only these archives and their evidence.
