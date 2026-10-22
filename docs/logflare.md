# Production Logflare

Pidro 2 uses a separate private Logflare source, `Pidro2.production`:
https://logflare.app/sources/38407
Source UUID: `98f914b0-6af5-4f2f-b245-f9c6be1c1b1a`.

The current account permits three-day retention for new sources. Seven days was
rejected by the plan limit; billing was not changed. Game archives and reports
have their own 30-day retention. This source starts collecting after installation;
it does not reconstruct prior incidents.

## Collection

A pinned Vector 0.60.0 container runs under `pidro-logflare.service` on the game
host. It follows Docker containers whose name starts `pidro-backend-web-` and
whose labels identify the Pidro web service, including replacement releases.
The game keeps its existing local Docker logging driver. No network request to
Logflare occurs inside a game process, and installing the collector never
restarts the game server.

`ops/server/logflare.toml` forwards the allowlisted structured diagnostics. Search
metadata by `game_instance_id`, `action_id`, `room_code`, `request_id`, revision,
user ID or `server_build`. Every record includes service and environment.
Generic warning/error records become a `runtime_warning_or_error` signal with
request ID; their arbitrary message/stack/state stays in local Docker logs.
Ordinary request logs and non-JSON output are discarded. Full private game
snapshots and client reports remain in the admin database, not hosted logs.

The collector batches up to 50 events and flushes after one second. Its disk
buffer is bounded to approximately 256 MiB and drops new records when full;
this is best-effort operational evidence. Docker source collection is also
best effort: collector downtime can leave gaps, and retries/restarts may
produce duplicates. It is not the durable game archive. The container has
192 MiB memory and 0.25 CPU limits; its own logs rotate at 2 × 5 MiB.

The collector needs Docker API access through the Unix socket. A read-only
socket mount does not remove the authority of the Docker API. The image is
pinned by digest, capabilities are dropped, its filesystem is read-only apart
from its buffer, and no ports are published. Treat collector configuration and
host access as privileged infrastructure.

## Install or update

Create a private mode-0600 file outside version control containing:

```json
{"api_key":"<existing ingest key>","source_id":"98f914b0-6af5-4f2f-b245-f9c6be1c1b1a"}
```

Run `ops/install-logflare /path/to/credentials`. The installer validates the
configuration and runs its privacy tests before installing/restarting only the
collector. Credentials live at `/etc/pidro-logflare/credentials.json`, mode 0600.
Vector reads its file secret backend; environment interpolation remains disabled.
The installer does not change the backend deployment pipeline or billing.

Check `systemctl status pidro-logflare` and `docker logs pidro-logflare` on the
host. Verify a known diagnostic action ID in the source UI; service health alone
does not establish successful ingestion. To stop shipping logs without changing
game behavior, use `systemctl disable --now pidro-logflare`.

`ops/test-logflare` exercises the real pinned collector against a local HTTP
receiver on a Linux Docker host. It checks the actual source query parameter and
ingest header, batching, correlation fields and omission of private payloads.
The configuration also contains four Vector privacy/drop tests, run by the
installer. This catches unresolved secret placeholders that syntax validation
alone cannot detect.
