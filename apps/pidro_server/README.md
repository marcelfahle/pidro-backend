# Pidro Server

**Phoenix LiveView Game Server & Development UI for Finnish Pidro**

## What Is This?

Phoenix-based multiplayer server for Finnish Pidro (4-player trick-taking card game):
- **Game API**: REST + WebSocket for mobile clients (future)
- **Admin Panel**: LiveView dashboard for monitoring games
- **Dev UI**: Testing environment with bot players and debugging tools
- **Game Engine**: Powered by `pidro_engine` (pure functional Elixir game logic)

## Architecture at a Glance

```
pidro_backend/                    # Umbrella project root
├── apps/pidro_engine/           # Pure game logic (event sourcing, 516 tests)
│   └── lib/pidro/               # Game rules, state machine, OTP server
└── apps/pidro_server/           # Phoenix server (this project)
    ├── lib/pidro_server/        # Business logic
    │   ├── games/               # Room management, game supervision
    │   ├── accounts/            # Auth, users, tokens
    │   ├── dev/                 # Bot system, event recording
    │   └── stats/               # Game statistics
    └── lib/pidro_server_web/    # Web layer
        ├── channels/            # WebSocket (LobbyChannel, GameChannel)
        ├── controllers/         # REST API
        └── live/                # LiveView UIs
            ├── [admin views]    # Admin panel (lobby, game monitor, stats)
            └── dev/             # Dev testing UI (game list, detail, analytics)
```

## Quick Start

```bash
# From umbrella root (pidro_backend/)
mix deps.get
mix ecto.setup
mix phx.server
```

## Routes

### Dev Routes (Development Only)

These routes are only available when `config :pidro_server, dev_routes: true` (set in `config/dev.exs`):

| Route | Description |
|-------|-------------|
| `/dev/games` | Dev UI - create test games, manage bots |
| `/dev/games/:code` | Dev UI - play/debug a specific game |
| `/dev/analytics` | Dev UI - analytics dashboard |
| `/dev/dashboard` | Phoenix LiveDashboard (metrics, processes) |
| `/dev/mailbox` | Swoosh email preview |

### Admin Panel (Basic Auth Protected)

| Route | Description |
|-------|-------------|
| `/admin/lobby` | Room list overview |
| `/admin/games/:code` | Monitor a specific game |
| `/admin/stats` | Server statistics |

### REST API

**Public (no auth):**
| Route | Description |
|-------|-------------|
| `GET /api/swagger` | Interactive API documentation |
| `GET /api/openapi` | OpenAPI spec (JSON) |
| `POST /api/v1/auth/register` | Register new user |
| `POST /api/v1/auth/login` | Login, get JWT token |
| `GET /api/v1/rooms` | List all rooms |
| `GET /api/v1/rooms/:code` | Get room details |
| `GET /api/v1/rooms/:code/state` | Get game state |

**Authenticated (Bearer token):**
| Route | Description |
|-------|-------------|
| `GET /api/v1/auth/me` | Get current user |
| `GET /api/v1/users/me/stats` | Get user stats |
| `POST /api/v1/rooms` | Create a room |
| `POST /api/v1/rooms/:code/join` | Join a room |
| `DELETE /api/v1/rooms/:code/leave` | Leave a room |
| `POST /api/v1/rooms/:code/watch` | Spectate a room |
| `DELETE /api/v1/rooms/:code/unwatch` | Stop spectating |

### WebSocket Channels

| Channel | Topic | Description |
|---------|-------|-------------|
| LobbyChannel | `lobby:main` | Room list updates |
| GameChannel | `game:{code}` | Real-time gameplay events |

## Key Concepts

### Game Lifecycle
1. **Room Created** → waiting for 4 players
2. **4 Players Join** → `Pidro.Server` GenServer spawns
3. **Game Active** → players bid, declare trump, play tricks
4. **Game Over** → stats saved, room closes after timeout

### Process Model
- **RoomManager** (GenServer): Tracks all rooms, player→room mapping
- **GameSupervisor** (DynamicSupervisor): Supervises individual game processes
- **GameRegistry** (Registry): Maps room_code → `Pidro.Server` PID
- **Pidro.Server** (GenServer): Stateful game logic per room (from pidro_engine)
- **PubSub**: Real-time broadcasts on `game:{code}` topics

### Dev UI Features (Current)
- ✅ Create games with 0-4 bot players (Random/Basic/Smart difficulty)
- ✅ Switch player positions (North/South/East/West + God Mode)
- ✅ Execute game actions via UI buttons
- ✅ Event log with filtering and export
- ✅ Bot management (pause/resume, configure difficulty)
- ✅ Quick actions (undo, auto-bid, fast-forward)
- ✅ Real-time state updates via PubSub

## Project Status

### Completed (Phase 0-2)
- ✅ **Core Infrastructure**: Routes, LiveViews, PubSub
- ✅ **Game Management**: Create, list, delete, filter games
- ✅ **Player Impersonation**: Position switching, action execution
- ✅ **Bot System**: BotManager, BotPlayer, RandomStrategy, supervision tree
- ✅ **Event Log**: Real-time event recording, filtering, export
- ✅ **Quick Actions**: Undo, auto-bid, fast-forward

### Next Up (Phase 3+)
- [ ] Multi-view mode (split screen)
- [ ] Hand replay functionality
- [ ] Bot reasoning display
- [ ] Statistics dashboard
- [ ] Advanced bot strategies (BasicStrategy, SmartStrategy)

See: [MASTERPLAN-DEVUI.md](MASTERPLAN-DEVUI.md) for detailed roadmap

## Development Workflow

### Testing a Game Feature
```bash
# 1. Start server
iex -S mix phx.server

# 2. Visit http://localhost:4000/dev/games
# 3. Click "New Game (1P + 3 Bots)"
# 4. Switch to North position
# 5. Play through bidding/trump/playing phases
# 6. Review event log
# 7. Use "Undo" or "Fast Forward" as needed
```

### Debugging Game State
```elixir
# In IEx while server running:
alias PidroServer.Games.{RoomManager, GameAdapter}

# List all rooms
RoomManager.list_rooms()

# Get game state
GameAdapter.get_state("ROOM_CODE")

# Get legal actions for a position
GameAdapter.get_legal_actions("ROOM_CODE", :north)
```

### Running Tests
```bash
mix test                          # All tests
mix test test/pidro_server/       # Server tests only
mix test --cover                  # With coverage
mix credo --strict                # Code quality
mix dialyzer                      # Type checking
```

## Key Files & Modules

### Game Domain
- `lib/pidro_server/games/room_manager.ex` - Room lifecycle, player tracking
- `lib/pidro_server/games/game_adapter.ex` - Bridge to pidro_engine
- `lib/pidro_server/games/game_supervisor.ex` - Supervise game processes

### Dev UI (Development Testing)
- `lib/pidro_server_web/live/dev/game_list_live.ex` - Game creation & discovery
- `lib/pidro_server_web/live/dev/game_detail_live.ex` - Play interface
- `lib/pidro_server/dev/bot_manager.ex` - Bot lifecycle management
- `lib/pidro_server/dev/bot_player.ex` - Bot GenServer (auto-plays)
- `lib/pidro_server/dev/event_recorder.ex` - Event logging
- `lib/pidro_server/dev/game_helpers.ex` - Quick actions (undo, auto-bid, etc.)

### Admin Panel (Monitoring)
- `lib/pidro_server_web/live/lobby_live.ex` - Room list overview
- `lib/pidro_server_web/live/game_monitor_live.ex` - Watch live games
- `lib/pidro_server_web/live/stats_live.ex` - Server statistics

### WebSocket Channels
- `lib/pidro_server_web/channels/game_channel.ex` - Real-time gameplay
- `lib/pidro_server_web/channels/lobby_channel.ex` - Room updates
- `lib/pidro_server_web/presence.ex` - Online player tracking

## Documentation Index

**Specifications:**
- [pidro_server_specification.md](specs/pidro_server_specification.md) - Complete server architecture
- [pidro_server_dev_ui.md](specs/pidro_server_dev_ui.md) - Dev UI functional requirements

**API Documentation:**
- [API_DOCUMENTATION.md](thoughts/API_DOCUMENTATION.md) - REST API endpoints
- [WEBSOCKET_API.md](thoughts/WEBSOCKET_API.md) - WebSocket event formats
- [ACTION_FORMATS.md](thoughts/ACTION_FORMATS.md) - Game action reference

**Implementation:**
- [MASTERPLAN.md](thoughts/MASTERPLAN.md) - Server implementation roadmap
- [MASTERPLAN-DEVUI.md](thoughts/MASTERPLAN-DEVUI.md) - Dev UI implementation tracker (Phase 0-2 complete)
- [ARCHITECTURE_SUMMARY.md](thoughts/ARCHITECTURE_SUMMARY.md) - System design overview

**Features:**
- [FR10_QUICK_ACTIONS_FEASIBILITY.md](thoughts/FR10_QUICK_ACTIONS_FEASIBILITY.md) - Quick actions analysis
- [SPECTATOR_MODE_INDEX.md](thoughts/SPECTATOR_MODE_INDEX.md) - Spectator mode design (future)
- [RECONNECTION_IMPLEMENTATION_GUIDE.md](thoughts/RECONNECTION_IMPLEMENTATION_GUIDE.md) - Reconnection handling (future)

**Operations:**
- [DEPLOYMENT.md](thoughts/DEPLOYMENT.md) - Production deployment guide
- [SECURITY_SAFETY_REQUIREMENTS.md](thoughts/SECURITY_SAFETY_REQUIREMENTS.md) - Security analysis

**Coding Standards:**
- [AGENTS.md](thoughts/AGENTS.md) - Coding conventions for AI agents

## Configuration

Config files are at the umbrella level: `pidro_backend/config/`

```
config/
├── config.exs    # Shared config (all environments)
├── dev.exs       # Development settings
├── prod.exs      # Production settings
├── runtime.exs   # Runtime config (env vars for prod)
└── test.exs      # Test settings
```

### Admin Panel Credentials

The admin panel (`/admin/*`) uses HTTP Basic Auth. Credentials are configured in:

**Development** (`config/dev.exs`):
```elixir
config :pidro_server,
  admin_username: "admin",
  admin_password: "pidro_admin_2025"
```

**Production** (`config/runtime.exs`): Set via environment variables:
```elixir
config :pidro_server,
  admin_username: System.get_env("ADMIN_USERNAME") || "admin",
  admin_password: System.get_env("ADMIN_PASSWORD") || raise "ADMIN_PASSWORD required"
```

### Environment Variables
```bash
# Database
DATABASE_URL=ecto://postgres:postgres@localhost/pidro_server_dev

# Phoenix
SECRET_KEY_BASE=...  # Generate with: mix phx.gen.secret
PORT=4000
HOST=localhost

# Admin (production)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=your_secure_password

# For production
MIX_ENV=prod
```

### Mix Tasks
```bash
mix setup           # Install deps, create DB, run migrations
mix ecto.reset      # Reset database
mix assets.build    # Compile CSS/JS
mix phx.routes      # List all routes
```

## Tech Stack

- **Phoenix 1.8.1** - Web framework
- **Phoenix LiveView 1.1** - Real-time UI
- **Ecto 3.13** - Database wrapper
- **PostgreSQL** - Database
- **Tailwind CSS** - Styling
- **Heroicons** - UI icons
- **OpenAPI Spex** - API documentation
- **Pidro Engine** - Game logic (sibling app)

## Testing the Dev UI

1. **Create a game**: Visit `/dev/games`, click "New Game (1P + 3 Bots)"
2. **Switch positions**: Click North/South/East/West buttons
3. **Make moves**: Use action buttons (Bid 6, Pass, etc.)
4. **View events**: Scroll event log, filter by type/player
5. **Bot controls**: Pause/resume bots, change difficulty
6. **Quick actions**: Try Undo, Auto-bid, Fast Forward
7. **Delete game**: Click delete button when done

## Troubleshooting

**LiveView not updating?**
- Check PubSub subscriptions in GameDetailLive mount
- Verify broadcasts in GameAdapter after state changes

**Bots not playing?**
- Check BotSupervisor is started (only in :dev env)
- Verify `BotManager.list_bots()` shows active bots
- Check EventRecorder logs for bot actions

**Database issues?**
```bash
mix ecto.reset
mix ecto.migrate
```

**Asset compilation errors?**
```bash
mix assets.setup
mix assets.build
```

## Contributing

See implementation masterplans for feature roadmap and task breakdown.
Follow coding conventions in [AGENTS.md](AGENTS.md).

---

**Version**: 0.1.0
**Phoenix**: 1.8.1
**Elixir**: ~> 1.15
**Status**: Dev UI Phase 2 Complete (Bot System, Event Log, Quick Actions)
