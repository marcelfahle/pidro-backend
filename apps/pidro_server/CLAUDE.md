# Pidro Backend

Multiplayer card game server built with Phoenix 1.8, Elixir, and OTP.

## Commands

```bash
mix precommit           # Format, compile, test, dialyzer, credo (run before commits)
mix test                # Run all tests
mix test --failed       # Re-run failed tests
mix test path/to/test.exs:42  # Run specific test at line
mix format              # Format code
mix dialyzer            # Type checking
mix credo --strict      # Linting
```

## Architecture

- **Pure functions over GenServer logic**: Business logic in pure modules, GenServers only coordinate state
- **Single source of truth**: Derive data, don't store duplicates
- **Thin GenServers**: Validation → delegate to pure function → update state → broadcast

## Key Directories

- `lib/pidro_server/games/` - Game engine, room management
- `lib/pidro_server_web/` - Phoenix web layer (controllers, channels)
- `thoughts/` - Plans, research, documentation

## Progressive Disclosure

Read these when relevant:
- `thoughts/AGENTS.md` - Phoenix/Elixir patterns and gotchas
- `thoughts/shared/plans/` - Implementation plans for features
- `thoughts/shared/research/` - Technical research documents
