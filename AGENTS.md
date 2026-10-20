# Pidro Backend

An Elixir umbrella: the Phoenix server is `apps/pidro_server` (read its
`CLAUDE.md`), the game engine is `apps/pidro_engine` (read its `AGENTS.md`).
Rules belong to the engine; the server only serializes what the engine knows.

## Shipping

- **Prove it.** Run `mix precommit` from the umbrella root, and show in the
  thread what you checked and how it came out.
- **Push to `main`.** No PR: a small set of commits, rebased on
  `origin/main`. Then watch Backend CI on your commit until it is green; if
  you turned it red, fix forward right away.
- **A green `main` deploys itself**, after pidro-frontend's Game and Account
  journeys pass against the commit. Don't run `just deploy` yourself.
- **Roll back** with `mise exec -- scripts/rollback` (previous version) or
  `mise exec -- scripts/rollback <sha>`; add `--dry-run` to look first.
  [docs/deploy.md](docs/deploy.md) says when to roll back and when to fix
  forward.

## Load-bearing paths

A diff that touches any of these gets an independent review before the push
(`coderabbit review --plain` or `codex review` if available, otherwise a
separate skeptical pass over the whole diff). Answer every finding.

- **Engine rules, scoring and turn order:** `apps/pidro_engine/lib/pidro/core/`,
  `apps/pidro_engine/lib/pidro/game/`, `apps/pidro_engine/lib/pidro/finnish/`,
  `apps/pidro_engine/lib/pidro/rules/`, `apps/pidro_engine/lib/pidro/rules.ex`
- **Auth, sessions and Classic claims:** `apps/pidro_server/lib/pidro_server/accounts/`,
  `apps/pidro_server/lib/pidro_server_web/plugs/authenticate.ex`,
  `apps/pidro_server/lib/pidro_server_web/controllers/api/auth_controller.ex`,
  `apps/pidro_server/lib/pidro_server_web/controllers/api/classic_claim_controller.ex`
- **IAP and entitlements:** none exist in this repo yet; the code that adds
  them is load-bearing from its first commit.
- **Database migrations:** `apps/pidro_server/priv/repo/migrations/`
- **Seat passwords:** `apps/pidro_server/lib/pidro_server/games/room/config.ex`,
  `apps/pidro_server/lib/pidro_server/games/room/positions.ex`,
  `apps/pidro_server/lib/pidro_server/games/room_manager.ex`
- **The socket:** `apps/pidro_server/lib/pidro_server_web/channels/`
