# Server diagnostics implementation evidence

Branch: `admin-ops/server-diagnostics`. Feature-branch delivery only: no main
push, PR, merge, deployment, hosted log account, or archive implementation.

## Exercised behavior

* Real local Bandit HTTP + Phoenix WebSocket + engine + Postgres run on commit
  `173ef5c6a8410d9d8eb3f0fb3dee1a7f5cdf15ce`: joined at revision 0, submitted
  `select_dealer` with `wire-attempt-1`, received unchanged `ok/{}` reply. The
  atomic action revision was 1; the later automatic transition reached revision 2.
  Captured 14 structured records including receipt, applied revision, broadcast,
  push, outcome, acknowledgement and durable report correlation. All records
  carried that exact SHA through `KAMAL_VERSION`.
* Two identical real `state_received` pushes produced one logged acknowledgement.
  Invalid card rank returned `invalid_card`; stale ready returned
  `stale_readiness`. Neither raw payload nor card/token sentinels appeared in
  stdout. The verification also checked all five actual bearer tokens against
  the complete server log without printing them.
* Real HTTP report returned 201 and UUID
  `da9372ad-8764-4546-bf90-93b96aebe799`. A separate PostgreSQL connection retrieved
  the same ID, authoritative user, instance and two stored events. Outsider =
  403; spoofed user field = 422; 34,000-byte **chunked** body = 413 with CORS.
  The proof database, credentials and service were removed afterward.
* Integration tests exercise a suspended real engine (250 ms timeout), unchanged
  `game_unavailable` reply and correlated warning; a removed Logger handler with
  accepted legacy action; and a temporarily unavailable real report table with
  503 while a real game action still advances its revision. No provider is mocked
  into an apparent successful hosted delivery.
* Real DB/controller tests cover authenticated ownership, completed-game stats
  after room closure, current players versus spectators, reused/wrong instances,
  unknown fields, string/revision/count/body bounds, malformed and encoded-route
  spam, durable five/hour quota, UTC admin filtering and tied-timestamp keysets,
  bounded cleanup and repeated supervised timer cleanup. The no-archive fallback
  test explicitly clears/restores the optional archive provider; the coordinator
  owns cross-feature closure→201 proof with the real archive.

The first scratch live run was discarded: `mix run --no-start` skipped Mix's
normal Logger initialization, and its short-lived fixture owner disconnected
the seats before the client ran. The corrected run used normal app startup and
kept the fixture owner alive. No game rules were changed to make the run pass.

## Commands and checks

* `mise exec -- mix test apps/pidro_server/test/pidro_server/diagnostics_test.exs apps/pidro_server/test/pidro_server_web/controllers/api/game_report_controller_test.exs apps/pidro_server/test/pidro_server_web/plugs/rate_limit_test.exs`:
  **44 passed** after CORS/request-ID corrections.
* `mise exec -- mix test apps/pidro_server/test/pidro_server_web/controllers/api/game_report_controller_test.exs`:
  **16 passed** after encoded-path admission fix and no-archive test isolation.
* Full `mix precommit` first passed engine/server tests but correctly failed a
  new Credo metadata warning. Adding the sanitized `diagnostic` metadata key to
  Logger config fixed that finding. A later run passed 911 engine and 1979 server
  tests and diff-scoped Credo, then failed while building a PLT because a concurrent
  Mix invocation removed a consolidated beam. The incomplete generated dependency
  PLT was deleted and a serial full rerun completed; no checks or warning
  suppressions were weakened.
* **Final `mise exec -- mix precommit` on `525285f`: exit 0.** Engine: **911
  passed**, 1 skipped. Server: **1980 passed**, 1 skipped. Formatting,
  warnings-as-errors compilation, diff-scoped Credo (`added no issues`), and
  Dialyzer (`done (passed successfully)`) passed. Dialyzer retained the repository's
  existing 56 skips, with zero unnecessary skips; its ignore file was unchanged.

Wire artifacts are attached in the implementation thread under
`.amp/in/artifacts/diagnostics-wire.jsonl`, `diagnostics-http-websocket.json`, and
`diagnostics-persisted.json`. They contain only disposable fixture identifiers and
sanitized outcomes, no credentials or hands. UI was not changed; no screenshots
are applicable.

## Independent review and integration

Independent review found malformed bodies bypassing the attempt counter and
whole-value label validation occurring after truncation. Both were corrected.
Follow-up review reproduced percent-encoded route admission bypass; the plug now
uses the same decoded segment matching as Phoenix, covered by endpoint tests.
Coordinator review found early-error CORS loss and ordinary-log request-ID loss;
both have explicit regression coverage and were published in an incremental commit.

Only RoomManager change: an additive diagnostic-context argument carried through
the existing serialized seat-authorization/action boundary, retaining the old
arity/message compatibility. No rules/scoring/turn order, bot catalogue, archives,
or LiveView changes.

Migration **20261022120200_create_game_reports.exs** is additive and was applied
to disposable databases. It creates a private report table/indexes with a user
foreign key and cascading user deletion. Scheduled cleanup starts after Repo,
deletes at most 1000 reports older than 30 days every minute, and retries on the
next scheduled tick after a failure. The global timer is disabled in tests.

Exact client/admin API: [diagnostics-contract.md](diagnostics-contract.md).
Operations/build identity/managed shipping recipe:
[diagnostics-operations.md](diagnostics-operations.md).

Remaining integration limits: real archive callback/wiring is supplied by the
archive orb/coordinator, not verified here; production deployment, collector
overload under sustained host pressure, and hosted ingestion are not exercised.
The local wire run used `173ef5c`; later admission/test fixes have endpoint
integration coverage. No claim of client UI, native app, or hosted ingestion proof.
