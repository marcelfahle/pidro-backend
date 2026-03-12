---
date: 2026-03-08T15:53:00+01:00
researcher: ralph
git_commit: a5e8493
branch: feat/lobby2
repository: pidro_backend
topic: "Code quality tooling audit: formatting, testing, linting, credo, sobelow, dialyzer, warnings-as-errors"
tags: [research, code-quality, credo, dialyzer, formatter, sobelow, testing, precommit]
status: complete
last_updated: 2026-03-08
last_updated_by: ralph
---

# Research: Code Quality Tooling Audit

**Date**: 2026-03-08T15:53:00+01:00
**Researcher**: ralph
**Git Commit**: a5e8493
**Branch**: feat/lobby2
**Repository**: pidro_backend

## Research Question

What is the current state of code quality tooling (formatting, testing, linting, credo, sobelow, warnings-as-errors, dialyzer, precommit hooks, CI) across the pidro_backend umbrella?

## Summary

The project has **partial** code quality tooling. Credo, Dialyzer, ExCoveralls, and the formatter are configured as dependencies. However, several gaps exist: **no `mix precommit` task** (referenced but not implemented), **no sobelow** dependency, **no `warnings_as_errors`** compiler option, **no git hooks**, and **no CI pipeline**. The tools that do exist all report issues when run.

## Detailed Findings

### 1. Formatting (`mix format`)

**Status: CONFIGURED, CURRENTLY FAILING**

Three `.formatter.exs` files exist:

- **Root** (`pidro_backend/.formatter.exs`): delegates to `apps/*` subdirectories
- **pidro_server** (`apps/pidro_server/.formatter.exs`): imports deps `:ecto`, `:ecto_sql`, `:phoenix`; uses `Phoenix.LiveView.HTMLFormatter` plugin; covers `*.{heex,ex,exs}`
- **pidro_engine** (`apps/pidro_engine/.formatter.exs`): standard `{mix,.formatter}.exs`, `{config,lib,test}/**/*.{ex,exs}`

**Current failures** (2 files):
- `apps/pidro_server/lib/pidro_server/games/bots/substitute_bot.ex` — trailing blank line before `end`
- `apps/pidro_server/lib/pidro_server/stats/stats.ex` — long pattern match needs multi-line formatting

### 2. Credo (`mix credo --strict`)

**Status: CONFIGURED, EXIT CODE 30 (issues found)**

- Config: `apps/pidro_server/.credo.exs` with `strict: true`
- pidro_engine has no `.credo.exs` (uses Credo defaults)
- Dependency: `{:credo, "~> 1.7"}` in both apps

**Current findings** (147 files scanned):
| Category | Count |
|---|---|
| Warnings | 6 |
| Refactoring opportunities | 84 |
| Code readability issues | 78 |
| Software design suggestions | 61 |

Key issue categories:
- **Warnings (6)**: `length/1` used where `Enum.empty?/1` would be cheaper (all in pidro_engine)
- **Refactoring (84)**: mostly `apply/2` usage (9 in pidro_engine), plus various others
- **Readability (78)**: alias ordering, module doc, max line length
- **Design (61)**: TODO tags, nested module aliasing

### 3. Dialyzer (`mix dialyzer`)

**Status: CONFIGURED, EXIT CODE 2 (warnings emitted)**

- Config in `pidro_server/mix.exs`: PLT file at `priv/plts/dialyzer.plt`, adds `:ex_unit`
- Dependency: `{:dialyxir, "~> 1.4"}` in both apps
- No `.dialyzer_ignore` file exists

**Current warnings** (3 legacy + 3 dialyxir bugs):
1. `game_channel.ex:194` — unreachable variable `_error@1`
2. `card_helpers.ex:113` — unreachable catch-all clause for suit atom
3. `game_list_live.ex:194` and `:1032` — unreachable `{:error, _reason}` patterns

Plus 3 `Protocol.UndefinedError` bugs in dialyxir itself (cosmetic, not blocking).

### 4. Compiler Warnings-as-Errors

**Status: NOT CONFIGURED**

- Neither `mix.exs` has `elixirc_options: [warnings_as_errors: true]`
- `mix compile --warnings-as-errors` succeeds cleanly (0 exit code) — no compiler warnings currently exist
- But since it's not in project config, CI/precommit won't enforce it

### 5. Testing (`mix test`)

**Status: CONFIGURED, ALL PASSING**

| App | Tests | Properties | Doctests | Failures | Skipped | Time |
|---|---|---|---|---|---|---|
| pidro_engine | 531 | 170 | 79 | 0 | 4 | 2.1s |
| pidro_server | 354 | — | — | 0 | 1 | 106.8s |

- pidro_engine: fast, comprehensive (780 total assertions)
- pidro_server: slow (106.8s, mostly sync integration tests)
- ExCoveralls configured in pidro_server (`test_coverage: [tool: ExCoveralls]`)
- No coveralls threshold configured
- pidro_server test alias: `["ecto.create --quiet", "ecto.migrate --quiet", "test"]`

**Skipped items:**
- pidro_engine: 4 skipped (3 binary encoding TODOs, 1 other)
- pidro_server: 1 skipped (the known flaky `SupervisorTest.lookup_game/1` race condition)

**Warnings during server tests:** Multiple "Game already exists for room" warnings and a SubstituteBot action failure warning — these are test-expected log output, not failures.

### 6. Sobelow (Security Scanner)

**Status: NOT INSTALLED**

- Not in any `mix.exs` deps
- No `.sobelow-conf` file
- `mix sobelow` fails with "task not found"

### 7. `mix precommit` Task

**Status: REFERENCED BUT NOT IMPLEMENTED**

- `CLAUDE.md` documents: `mix precommit # Format, compile, test, dialyzer, credo`
- `pidro_server/mix.exs` has `preferred_envs: [precommit: :test]`
- **No actual Mix task module exists** — `mix precommit` fails with "task not found"

### 8. Git Hooks

**Status: NONE ACTIVE**

- Only `.sample` hook files exist in `.git/hooks/`
- No `pre-commit`, `pre-push`, or `commit-msg` hooks installed

### 9. CI/CD Pipeline

**Status: NOT CONFIGURED**

- No `.github/workflows/` directory
- No other CI configuration files found

### 10. ExDoc

**Status: CONFIGURED**

- `{:ex_doc, "~> 0.34"}` in pidro_server, `{:ex_doc, "~> 0.31"}` in pidro_engine
- Both apps have detailed `docs` configuration with module groupings
- pidro_engine has extras (README, guides, specs) and custom JS for copy buttons

## Code References

- `apps/pidro_server/mix.exs:1-168` — Server project config (deps, aliases, dialyzer, coveralls)
- `apps/pidro_engine/mix.exs:1-193` — Engine project config
- `apps/pidro_server/.credo.exs:1-146` — Credo config (67 enabled checks, 32 disabled)
- `apps/pidro_server/.formatter.exs:1-6` — Server formatter config
- `apps/pidro_engine/.formatter.exs:1-3` — Engine formatter config
- `.formatter.exs:1-5` — Root umbrella formatter config
- `config/config.exs` — No compiler options set
- `config/dev.exs` — No warnings_as_errors
- `config/test.exs` — No test-specific compiler config

## Current Tool Status Summary

| Tool | Installed? | Configured? | Currently Passing? |
|---|---|---|---|
| `mix format` | built-in | yes | **NO** (2 files) |
| `mix credo --strict` | yes | yes | **NO** (exit 30, 229 issues) |
| `mix dialyzer` | yes | yes | **NO** (exit 2, 3 warnings) |
| `mix compile --warnings-as-errors` | built-in | **NO** | yes (0 warnings currently) |
| `mix test` (engine) | built-in | yes | yes |
| `mix test` (server) | built-in | yes | yes |
| `mix sobelow` | **NO** | no | N/A |
| `mix precommit` | **NO** | partial | N/A |
| Git hooks | **NO** | no | N/A |
| CI pipeline | **NO** | no | N/A |
| ExCoveralls | yes | yes | not run (no threshold) |
| ExDoc | yes | yes | not verified |
