# Kamal on Hetzner

This repo is pinned to Erlang 29.0.3, Elixir 1.20.2, Ruby 4.0.5,
Kamal 2.12.0, Phoenix 1.8.9, Phoenix LiveView 1.2.6, and PostgreSQL
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
