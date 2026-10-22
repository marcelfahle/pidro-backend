# Durable archive implementation evidence

Branch: `admin-ops/game-archive`. Backend context/storage only; no admin UI,
public route, game-rule change, PR, main push or deployment.
The stable consumer API and JSON format are in [archive-contract.md](archive-contract.md).

## Observed behavior

Real PostgreSQL tests exercise the production RoomManager, GameSupervisor,
GameAdapter, engine processes, bots and PubSub. No archive persistence mocks:

- Solo start, initial deal, accepted action and leave: process dies; private
  seats/personas, first dealt hands/deck, ordered events and last snapshot remain.
- A real game completes, then rematches in the same room: distinct instance IDs,
  separate histories; abandoned rematch closes without relabelling the completed game.
- A human leaving multiplayer does not close its continuing game. A later seated
  replacement plays and leaves during a write outage; recovery durably retains
  membership after closure. Wrong instance/room/user and spectators are denied.
- Duplicate transitions/finalization are idempotent; conflicting revision evidence
  is rejected. The bounded human-participation union discloses truncation.
- Real database constraint failures do not reject actions, stop bots or suppress
  broadcasts. Recovery preserves exact missing revision ranges and failed counts.
- A PostgreSQL trigger sleeps for five seconds while the shared TaskSupervisor
  is suspended. Accepted action returns within the test's one-second ceiling,
  revisions 1 and 2 broadcast, process stays alive and health degrades. After
  removing the trigger, persistence recovers with `partial` history and closure.
  The production worker budget remains 50ms and SQL statement timeout 40ms.
- Failed initial write can recover initial facts; killed process is marked
  interrupted after the reconciliation grace, not mistaken for its replacement.
- Finnish and Louisiana snapshots round-trip through JSON, retain exact large
  chance integers and reject executable/runtime resources.
- Retention removes old terminal archives/events in bounded batches, preserves
  stats and fresh/active games. No public archive route or extra private snapshot
  fields are introduced.

## Commands and results

Run from the umbrella root with `mise exec --` in this orb:

```sh
mix test apps/pidro_server/test/pidro_server/game_archive_test.exs \
  apps/pidro_server/test/pidro_server/game_archive_outage_test.exs \
  apps/pidro_server/test/pidro_server/games/disconnect_cascade_test.exs \
  apps/pidro_server/test/pidro_server/games/own_pace_test.exs
# Result: 72 passed (18.8 seconds), using disposable databases.

MIX_ENV=test mix ecto.rollback -r PidroServer.Repo --step 1
MIX_ENV=test mix ecto.migrate -r PidroServer.Repo
# Migration 20261022120100 reversed, then migrated successfully in local test DB.

MIX_TEST_PARTITION=archive_verified mix precommit
# Exit 0: engine 911 passed (79 doctests, 169 properties, 663 tests), 1 skipped.
# Server 1970 passed (67 doctests, 1903 tests), 1 skipped.
# Hex audit: no retired/security-advisory packages. Compile/format passed.
# Credo: added no issues. Dialyzer: passed (56 existing filters, none unused).
```

Archive/outage tests plus `profiles/profiles_test.exs` separately passed all 57
cases on this fresh partition. After full precommit, direct Repo queries returned
zero rows in users, player_profiles, player_achievements, game_xp, game_stats,
game_archives and game_archive_events; pg_database contained zero generated
`pidro_archive_*` databases. Every ArchiveCase teardown also asserts those original
table counts are unchanged.

ArchiveCase creates a unique disposable database per test, runs all migrations,
uses a normal connection pool, and restores the original Repo configuration before
dropping only its generated database. CREATE DATABASE permission is required;
the existing local/CI role is postgres. Ordinary SQL Sandbox tests disable capture
by default; real archive tests explicitly enable the unchanged production path.

Earlier runs exposed shared-Sandbox connection loss when cancelling a writer;
that harness was invalid for cancellation tests and was replaced, not worked
around by increasing production deadlines. Independent review also caught that
auto-mode cleanup could mutate pre-existing test archives; disposable databases
remove that risk. The earlier harness leaked four orphan profiles, so the final
full run used the fresh task-owned `archive_verified` partition. The outage test
now pauses real bots before readiness and resumes them only after installing the
SQL fault, avoiding a race where they had already selected the dealer.
One existing bot-test driver read bidding before consuming its
deal broadcast; its guard now waits for the observed deal. Bot-delay assertions
are unchanged. No new skips, warning filters or relaxed checks were added.

## Review, compatibility and limits

Independent lifecycle/migration reviews found two production issues, both fixed:
old-container reconciliation now excludes saves within 120 seconds as well as
delaying startup; worker creation uses `spawn_monitor` instead of synchronously
depending on TaskSupervisor. Follow-up review found no remaining production
correctness issue. Migration `20261022120100` is additive: archive tables/indexes
only, cascading event deletion, no stats alteration/backfill. Its unused draft
timestamp was renamed before deployment to avoid the bot catalogue collision.

The feature adds no client protocol requirements. Diagnostics is configured with
`:game_report_archive_lookup, PidroServer.GameArchive`; `participant?/3` consults
only durable, server-written membership. Admin callers must enforce existing
admin authentication; these are trusted internal APIs, not an authorization layer.

**Full deterministic engine replay is not implemented.** Snapshot/revision
navigation and event inspection use versioned JSON without executing an engine.
Future engine incompatibility does not prevent inspecting saved data.

Persistence is fail-open: an outage lasting the whole game can leave no archive;
membership lost before recovery cannot authorize a report. Missing evidence is
never relabelled continuous. Reconciliation assumes one serving node and the
current bounded deploy/drain overlap (60s/30s); distributed serving requires
ownership/leases first. Default detailed retention is 30 days; stats are untouched.

No browser screenshots apply: this branch adds no visual UI. The history inspector
orb owns browser verification against this runtime. Combined-feature verification
and deployment remain with the coordinator; this branch's checks do not claim
those other branches were integrated here.
