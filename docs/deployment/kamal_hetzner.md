# Kamal on Hetzner

This repo is pinned to Erlang 29.0.3, Elixir 1.20.2, Ruby 4.0.5,
Kamal 2.12.0, Phoenix 1.8.9, Phoenix LiveView 1.2.8, and PostgreSQL
18.4. The Mix lockfile pins the remaining Hex dependencies, and the production
container base images are pinned by digest.

The Hetzner host does not need Elixir installed. Kamal deploys the release image built from [Dockerfile](../../Dockerfile), so production runs the same OTP/Elixir pair pinned locally in [.tool-versions](../../.tool-versions).

## First-time setup

1. Run `mise install`, `bundle install`, and `mix deps.get`.
2. Create a GHCR token with package read/write access.
3. Copy [.kamal/secrets-common.example](../../.kamal/secrets-common.example) to `.kamal/secrets-common` and fill in real values.
4. Run `just bootstrap` to install Docker on the server and open `22`, `80`, and `443`.
5. Create Route53 records for `app.pidro.online` before the first TLS deploy.
6. Run `just setup` to boot Postgres, push secrets, and deploy the app.
7. Run `just install-backup-timer` once to install the daily database backup.
8. Run `just deploy`. Deploys automatically back up the database, run pending
   migrations against the new image before it boots, and smoke-test production.

## Secrets

Required secrets:

- `KAMAL_REGISTRY_PASSWORD`
- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`

## DNS

Create these records in the `pidro.online` hosted zone:

- `A` record: `app.pidro.online` -> `95.217.3.224`
- optional `AAAA` record: `app.pidro.online` -> `2a01:4f9:c013:e90d::1`

Use a low TTL like `300` for the first cutover.

## Notes

- [config/deploy.yml](../../config/deploy.yml) is set to `app.pidro.online` with Kamal-managed Let's Encrypt TLS.
- Kamal’s proxy health check hits `/up`, which also verifies database connectivity.
- PostgreSQL 18.4 runs as a Kamal accessory named `postgres`, persists its
  versioned data directory in the `postgres18-data` volume, and is available
  only on the internal Docker network and host loopback interface.
- Builds are configured to run on the Hetzner host as a remote `amd64` builder, which avoids local Apple Silicon emulation issues.
- Production developer routes are disabled. Do not add the developer Basic Auth
  password to the production secret contract.

## Proxy headers and rate limiting

The API rate limiter (`PidroServerWeb.Plugs.RateLimit`) keys most policies by
client address, so the release must learn the real client behind kamal-proxy.

- kamal-proxy terminates TLS and forwards to the container over the Docker
  bridge network, so Phoenix sees the proxy's private address as the TCP peer.
- [config/deploy.yml](../../config/deploy.yml) keeps kamal-proxy's
  `forward_headers` at its default (off with TLS). kamal-proxy then strips any
  client-supplied `X-Forwarded-*` headers and writes exactly one
  `X-Forwarded-For` value: the true peer. Do not add a `forward_headers` key;
  the `deployment-config` CI job fails if one appears.
- `PidroServerWeb.Plugs.TrustedProxy`, the first plug in the endpoint, honours
  `X-Forwarded-For` and `X-Forwarded-Proto` only when `TRUST_PROXY_HEADERS` is
  true (the production default; false in dev and test) and the TCP peer is a
  loopback, RFC 1918, CGNAT, IPv6 loopback, ULA or link-local address. It takes
  the rightmost `X-Forwarded-For` value, so even if `forward_headers` were ever
  enabled and client-supplied values were kept, the proxy-appended peer would
  still win.
- `TRUST_PROXY_HEADERS: "false"` under `env.clear` makes the limiter key on the
  TCP peer instead; every client then shares the proxy's bucket, so use it only
  to diagnose a limiter problem.
- Limits are tuned with `RATE_LIMIT_<POLICY>_LIMIT` and
  `RATE_LIMIT_<POLICY>_SCALE_MS`, where `<POLICY>` is one of `LOGIN`,
  `REGISTER`, `PASSWORD_RESET`, `PASSWORD_RESET_IDENTIFIER`,
  `PASSWORD_RESET_CONFIRM`, `ROOM_CREATE` or `ROOM_LOOKUP`, for example
  `RATE_LIMIT_LOGIN_LIMIT: "20"`. There is no off switch: raise a limit and
  redeploy. Never roll back a release to fix limiter behaviour.
- Limits are per node and per fixed window; counters reset on restart.

### One-time production check

`ops/smoke-production` cannot see the derived client address, so verify the
header contract once after the first deploy that carries the limiter:

1. Add `RATE_LIMIT_LOGIN_LIMIT: "1"` under `env.clear` in
   [config/deploy.yml](../../config/deploy.yml) and run `just deploy`.
2. From your own network, `POST https://app.pidro.online/api/v1/auth/login`
   twice within one minute (any credentials). The second response must be
   `429` with a `Retry-After` header.
3. From a second network (a phone on mobile data), send the same request
   once. It must not be `429` (expect `401` for bad credentials). A `429` here
   means the limiter keyed on the proxy address: check that
   `TRUST_PROXY_HEADERS` is not `false` and that `forward_headers` has not been
   enabled.
4. Remove the override and run `just deploy` again.

## Release flow

Run the local quality gate and deploy only from a clean commit:

```bash
just quality
just deploy
```

The Kamal hooks enforce the release order:

1. Refuse to build from a dirty worktree.
2. Create and validate a PostgreSQL custom-format backup.
3. Run all pending Ecto migrations using the exact image being deployed.
4. Boot the new container and wait for `/up` to verify database connectivity.
5. Verify TLS, API authentication, CORS, disabled developer routes, and the
   WebSocket endpoint.

Use `just rollback <git-sha>` to restore a retained application image. Database
migrations are not automatically reversed; restore the database only when a
rollback is incompatible with the migrated schema.

## Database backups

Backups are stored on the server in `/var/backups/pidro` as PostgreSQL custom
format dumps with SHA-256 checksums. Every dump is validated with
`pg_restore --list` before it is accepted. The systemd timer runs daily at
02:00 UTC with up to one hour of jitter, retains 30 days, and catches up after a
server outage.

Useful commands:

```bash
just backup
just install-backup-timer
ssh root@95.217.3.224 'systemctl list-timers pidro-backup.timer'
ssh root@95.217.3.224 'ls -lh /var/backups/pidro'
```

To verify a restore without touching production, restore into a disposable
database on a non-production PostgreSQL instance:

```bash
createdb pidro_restore_test
pg_restore --clean --if-exists --no-owner --dbname pidro_restore_test pidro-YYYYMMDDTHHMMSSZ.dump
dropdb pidro_restore_test
```

These host-local backups protect against bad migrations and accidental data
changes. Enable Hetzner server backups or copy the dumps to separate object
storage for host-level disaster recovery.

## PostgreSQL major upgrades

Never point a newer PostgreSQL major image at an older major's data volume.
Create a verified custom-format dump, stop application writes, boot the new
major against a new volume, restore the dump, verify the schema and row counts,
and only then resume traffic. Keep the stopped old container and volume until
the new database has passed production smoke checks and a scheduled backup.
