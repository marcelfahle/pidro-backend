# Kamal on Hetzner

This repo is pinned to `Erlang 28.4`, `Elixir 1.19.5`, `Phoenix 1.8.5`, and `Phoenix LiveView 1.1.27`.

The Hetzner host does not need Elixir installed. Kamal deploys the release image built from [Dockerfile](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/Dockerfile), so production runs the same OTP/Elixir pair pinned locally in [.tool-versions](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/.tool-versions).

## First-time setup

1. Create a GHCR token with package read/write access.
2. Copy [.kamal/secrets-common.example](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/.kamal/secrets-common.example) to `.kamal/secrets-common` and fill in real values.
3. Run `just bootstrap` to install Docker on the server and open `22`, `80`, and `443`.
4. Run `just setup` to boot Postgres, push secrets, and deploy the app.
5. Run `just migrate` after the first deploy or any schema change.

## Secrets

Required secrets:

- `KAMAL_REGISTRY_PASSWORD`
- `SECRET_KEY_BASE`
- `POSTGRES_PASSWORD`

## Notes

- `PHX_HOST` is currently set to the server IP in [config/deploy.yml](/Users/mf/code/pidro/_PIDRO2/code-ralph/pidro_backend/config/deploy.yml). Swap this to the real domain before turning on TLS.
- Kamal’s proxy health check hits `/up`, which also verifies database connectivity.
- Postgres runs as a Kamal accessory named `postgres`, and the app connects to it over the internal Docker network with `DB_HOST=postgres`.
- Builds are configured to run on the Hetzner host as a remote `amd64` builder, which avoids local Apple Silicon emulation issues.
