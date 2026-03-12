# Kamal on Hetzner

This repo is pinned to `Erlang 28.4`, `Elixir 1.19.5`, `Phoenix 1.8.5`, and `Phoenix LiveView 1.1.27`.

The Hetzner host does not need Elixir installed. Kamal deploys the release image built from [Dockerfile](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/Dockerfile), so production runs the same OTP/Elixir pair pinned locally in [.tool-versions](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/.tool-versions).

## First-time setup

1. Create a GHCR token with package read/write access.
2. Copy [.kamal/secrets-common.example](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/.kamal/secrets-common.example) to `.kamal/secrets-common` and fill in real values.
3. Run `just bootstrap` to install Docker on the server and open `22`, `80`, and `443`.
4. Create Route53 records for `play.pidro.online` before the first TLS deploy.
5. Run `just setup` to boot Postgres, push secrets, and deploy the app.
6. Run `just migrate` after the first deploy or any schema change.

## Secrets

Required secrets:

- `KAMAL_REGISTRY_PASSWORD`
- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`

## DNS

Create these records in the `pidro.online` hosted zone:

- `A` record: `play.pidro.online` -> `95.217.3.224`
- optional `AAAA` record: `play.pidro.online` -> `2a01:4f9:c013:e90d::1`

Use a low TTL like `300` for the first cutover.

## Notes

- [config/deploy.yml](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/config/deploy.yml) is now set to `play.pidro.online` with Kamal-managed Let's Encrypt TLS.
- Kamal’s proxy health check hits `/up`, which also verifies database connectivity.
- Postgres runs as a Kamal accessory named `postgres`, and the app connects to it over the internal Docker network with `DB_HOST=postgres`.
- Builds are configured to run on the Hetzner host as a remote `amd64` builder, which avoids local Apple Silicon emulation issues.
