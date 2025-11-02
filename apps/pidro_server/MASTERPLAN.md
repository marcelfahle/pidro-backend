# Pidro Server - Implementation Master Plan

**Last Updated**: 2025-11-02
**Status**: Phase 0 Complete - Engine Integrated
**Coverage**: ~2% (only infrastructure)
**Critical Path**: Auth → Games → Channels → Testing

---

## Executive Summary

### Current State
- ✅ **Phoenix scaffolding** complete (19 files)
- ✅ **Umbrella app** properly configured with config at root
- ✅ **Ecto Repo** configured (Postgres)
- ✅ **Basic infrastructure** (PubSub, Telemetry, Endpoint)
- ✅ **Engine app** exists in umbrella (apps/pidro_engine)
- ✅ **Engine integrated** - dependency declared and working
- ✅ **Password hashing** - bcrypt_elixir added
- ❌ **NO business logic** implemented
- ❌ **NO authentication** system
- ❌ **NO API endpoints** beyond defaults
- ❌ **NO WebSocket channels**
- ❌ **NO database migrations**
- ❌ **NO tests** beyond Phoenix defaults (5 tests)

### Implementation Status by Phase

| Phase | Area | Spec % | Status | Priority |
|-------|------|--------|--------|----------|
| Phase 1 | Foundation | 0% | ❌ Not Started | P0 |
| Phase 2 | Room Management | 0% | ❌ Not Started | P0 |
| Phase 3 | Game Integration | 0% | ❌ Not Started | P0 |
| Phase 4 | Real-time Gameplay | 0% | ❌ Not Started | P1 |
| Phase 5 | Lobby System | 0% | ❌ Not Started | P1 |
| Phase 6 | Admin Panel | 0% | ❌ Not Started | P2 |
| Phase 7 | Stats & Polish | 0% | ❌ Not Started | P2 |

### Critical Gaps (Blocking MVP)

1. ~~**🔴 CRITICAL: Engine not integrated**~~ ✅ DONE
2. ~~**🔴 CRITICAL: No config/ directory**~~ ✅ EXISTS at umbrella root
3. **🔴 No accounts/auth system** - Required for all protected endpoints
4. **🔴 No games domain** - Core game management missing
5. **🔴 No API controllers** - REST endpoints missing
6. **🔴 No WebSocket channels** - Real-time gameplay impossible
7. **🔴 No database migrations** - Cannot persist data
8. **🔴 No tests for business logic** - <5% coverage vs 80% target

---

## Implementation Roadmap (Prioritized)

### Phase 0: URGENT FIXES (Est: 30min-1 hour) ⚠️ ✅ COMPLETED

**MUST DO FIRST** - Blocking game integration

- [x] **[P0-A]** Add `{:pidro_engine, in_umbrella: true}` to apps/pidro_server/mix.exs deps (5min) ⏱️
- [x] **[P0-B]** Run `mix deps.get` from umbrella root to fetch engine (2min) ⏱️
- [x] **[P0-C]** Verify engine compiles: `mix compile` from root (5min) ⏱️
- [x] **[P0-D]** Verify tests run: `mix test` (5min) ⏱️
- [x] **[P0-E]** Add password hashing library (bcrypt_elixir or argon2_elixir) to mix.exs (5min) ⏱️

**Note**: Config already exists at umbrella root (../../config/) ✅

**Validation**: `mix precommit` passes from umbrella root ✅

---

### Phase 1: Authentication Foundation (Est: 1-2 days)

**Goal**: Users can register, login, receive JWT tokens

#### Database & User Schema (4-6 hours)
- [ ] **[P1-01]** Create users migration with fields: username, email, password_hash, guest, timestamps (30min)
- [ ] **[P1-02]** Create `lib/pidro_server/accounts/user.ex` schema (45min)
  - Add unique indices for username and email
  - Add changeset validations
- [ ] **[P1-03]** Add password hashing library (bcrypt_elixir or argon2_elixir) to mix.exs (15min)
- [ ] **[P1-04]** Run migration and verify DB structure (15min)

#### Auth Context (4-6 hours)
- [ ] **[P1-05]** Create `lib/pidro_server/accounts/auth.ex` context (2h)
  - `register_user/1` - create user with hashed password
  - `authenticate_user/2` - verify credentials
  - `get_user!/1` - fetch user by ID
  - `get_user_by_email/1` - lookup by email
- [ ] **[P1-06]** Create `lib/pidro_server/accounts/token.ex` for JWT (1h)
  - Use `Phoenix.Token.sign/4` and `verify/4`
  - Configure signing salt
  - Set token expiry (30 days per spec)
- [ ] **[P1-07]** Add authentication plug `lib/pidro_server_web/plugs/authenticate.ex` (1h)
  - Extract Bearer token from header
  - Verify token and load current_user
  - Handle unauthorized errors

#### REST API Controllers (3-4 hours)
- [ ] **[P1-08]** Create `lib/pidro_server_web/controllers/api/` directory structure (5min)
- [ ] **[P1-09]** Implement `auth_controller.ex` (2h)
  - POST /api/v1/auth/register
  - POST /api/v1/auth/login
  - DELETE /api/v1/auth/logout (optional for MVP)
  - GET /api/v1/auth/me
- [ ] **[P1-10]** Create `lib/pidro_server_web/views/api/user_view.ex` for JSON serialization (30min)
- [ ] **[P1-11]** Create `lib/pidro_server_web/controllers/api/fallback_controller.ex` (30min)
  - Translate Ecto.Changeset errors to JSON
  - Format per spec: `{errors: [{code, title, detail}]}`
- [ ] **[P1-12]** Update router with `/api/v1` scope and auth routes (30min)

#### Testing (3-4 hours)
- [ ] **[P1-13]** Create `test/pidro_server/accounts/auth_test.exs` (1h)
  - Test register_user, authenticate, get_user
- [ ] **[P1-14]** Create `test/support/fixtures.ex` with user factory (30min)
- [ ] **[P1-15]** Create `test/pidro_server_web/controllers/api/auth_controller_test.exs` (2h)
  - Test all auth endpoints (register, login, me)
  - Test error cases (invalid credentials, duplicate user, etc)
- [ ] **[P1-16]** Verify auth pipeline with integration test (30min)

**Validation**: Can register, login, get JWT, access protected endpoint

---

### Phase 2: Game Domain & Room Management (Est: 2-3 days)

**Goal**: Create rooms, join rooms, manage game processes

#### Supervision Tree (4-5 hours)
- [ ] **[P2-01]** Create `lib/pidro_server/games/supervisor.ex` (1h)
  - Supervise RoomManager, GameRegistry, GameSupervisor
  - Add to application.ex children
- [ ] **[P2-02]** Create `lib/pidro_server/games/game_registry.ex` (30min)
  - Use `{:via, Registry, {PidroServer.Games.GameRegistry, room_code}}`
  - Registry name configuration
- [ ] **[P2-03]** Create `lib/pidro_server/games/game_supervisor.ex` (1h)
  - Use DynamicSupervisor
  - `start_game/1` - spawn Pidro.Server for room
  - `stop_game/1` - terminate game process
  - `get_game/1` - lookup via Registry

#### RoomManager GenServer (6-8 hours)
- [ ] **[P2-04]** Create `lib/pidro_server/games/room_manager.ex` (4h)
  - State: %{rooms: %{code => %Room{}}, player_rooms: %{player_id => code}}
  - `create_room/2` - generate code, track host
  - `join_room/2` - add player, enforce max 4
  - `leave_room/1` - remove player
  - `list_rooms/0` - filter by status
  - `get_room/1` - lookup room details
- [ ] **[P2-05]** Create room code generator (30min)
  - 4-character alphanumeric codes
  - Ensure uniqueness
- [ ] **[P2-06]** Add room lifecycle logic (2h)
  - Auto-start game when 4 players join
  - Broadcast room updates via PubSub
  - Handle player disconnect/leave

#### GameAdapter (2-3 hours)
- [ ] **[P2-07]** Create `lib/pidro_server/games/game_adapter.ex` (2h)
  - `start_game/2` - start Pidro.Server via GameSupervisor
  - `apply_action/3` - forward to Pidro.Server.apply_action
  - `get_state/1` - get game state
  - `get_legal_actions/2` - query valid moves
  - `subscribe/1` - PubSub subscription helper

#### REST API (3-4 hours)
- [ ] **[P2-08]** Create `lib/pidro_server_web/controllers/api/room_controller.ex` (2h)
  - GET /api/v1/rooms - list available rooms
  - POST /api/v1/rooms - create room (requires auth)
  - GET /api/v1/rooms/:code - room details
  - POST /api/v1/rooms/:code/join - join room (requires auth)
  - DELETE /api/v1/rooms/:code/leave - leave room
- [ ] **[P2-09]** Create `lib/pidro_server_web/views/api/room_view.ex` (1h)
- [ ] **[P2-10]** Add room routes to router (15min)

#### Testing (4-6 hours)
- [ ] **[P2-11]** Create `test/pidro_server/games/room_manager_test.exs` (2h)
  - Test create, join, leave, list, full room handling
- [ ] **[P2-12]** Create `test/pidro_server/games/game_supervisor_test.exs` (1h)
- [ ] **[P2-13]** Create `test/pidro_server_web/controllers/api/room_controller_test.exs` (2h)
- [ ] **[P2-14]** Integration test: create room + 4 players join + game starts (1h)

**Validation**: Can create room via API, 4 players join, game process spawns

---

### Phase 3: Game Integration (Est: 1-2 days)

**Goal**: Wire up Pidro.Server, expose game state

#### Engine Integration (3-4 hours)
- [ ] **[P3-01]** Verify Pidro.Server from engine works standalone (30min)
- [ ] **[P3-02]** Wire GameAdapter to start Pidro.Server via DynamicSupervisor (1h)
- [ ] **[P3-03]** Test game state retrieval via GameAdapter (1h)
- [ ] **[P3-04]** Add PubSub broadcasting on game state changes (1h)
  - Subscribe to Pidro.Server events
  - Broadcast to `game:{code}` topic

#### State API (2-3 hours)
- [ ] **[P3-05]** Add GET /api/v1/rooms/:code/state endpoint (optional) (1h)
- [ ] **[P3-06]** Create game state view for JSON serialization (1h)

#### Testing (2-3 hours)
- [ ] **[P3-07]** Integration test: full game flow via GameAdapter (2h)
  - Start game
  - Apply actions (bid, declare_trump, play_card)
  - Verify state changes

**Validation**: Game starts, state can be queried, actions can be applied

---

### Phase 4: Real-time Gameplay (WebSocket Channels) (Est: 2-3 days)

**Goal**: Play complete games via WebSocket

#### UserSocket & Auth (2-3 hours)
- [ ] **[P4-01]** Create `lib/pidro_server_web/channels/user_socket.ex` (1h)
  - Define `channel "lobby", LobbyChannel`
  - Define `channel "game:*", GameChannel`
  - Implement JWT auth on connect
  - Implement socket ID for presence
- [ ] **[P4-02]** Mount socket in endpoint at "/socket" (15min)
- [ ] **[P4-03]** Add Presence module `lib/pidro_server_web/presence.ex` (30min)
- [ ] **[P4-04]** Add Presence to application supervision tree (15min)

#### GameChannel (6-8 hours)
- [ ] **[P4-05]** Create `lib/pidro_server_web/channels/game_channel.ex` (4h)
  - `join/3` - verify user is in room, return initial state
  - `handle_in("bid", ...)` - forward to GameAdapter
  - `handle_in("declare_trump", ...)` - forward to GameAdapter
  - `handle_in("play_card", ...)` - forward to GameAdapter
  - `handle_in("ready", ...)` - signal ready to start
  - Subscribe to game PubSub topic
  - Broadcast state changes to all players
- [ ] **[P4-06]** Handle game events and broadcast (2h)
  - `game_state` - full state update
  - `turn_changed` - current player changed
  - `game_over` - winner announced

#### LobbyChannel (2-3 hours)
- [ ] **[P4-07]** Create `lib/pidro_server_web/channels/lobby_channel.ex` (2h)
  - `join/3` - subscribe to lobby updates
  - Broadcast room_created, room_updated, room_closed
  - Return current room list on join

#### Testing (4-6 hours)
- [ ] **[P4-08]** Create `test/support/channel_case.ex` (30min)
- [ ] **[P4-09]** Create `test/pidro_server_web/channels/game_channel_test.exs` (3h)
  - Test join with auth
  - Test bid/declare_trump/play_card events
  - Test state broadcasts
- [ ] **[P4-10]** Create `test/pidro_server_web/channels/lobby_channel_test.exs` (1h)
- [ ] **[P4-11]** Integration test: 4 players complete game via channels (2h)

**Validation**: 4 players join via channels, complete full game, receive state updates

---

### Phase 5: Lobby System & Presence (Est: 1-2 days)

**Goal**: Live lobby updates, optional matchmaking

#### Lobby Features (3-4 hours)
- [ ] **[P5-01]** Integrate Presence tracking in LobbyChannel (1h)
- [ ] **[P5-02]** Add player count to room list (30min)
- [ ] **[P5-03]** Real-time room status updates (available, in-progress, closed) (1h)
- [ ] **[P5-04]** Polish error handling and edge cases (1h)

#### Matchmaker (Optional MVP+) (4-6 hours)
- [ ] **[P5-05]** Create `lib/pidro_server/games/matchmaker.ex` GenServer (3h)
  - Queue players waiting for match
  - Auto-create room when 4 players queued
  - POST /api/v1/matchmaking/join endpoint
- [ ] **[P5-06]** Test matchmaker (1h)

#### Testing (2-3 hours)
- [ ] **[P5-07]** Test lobby presence tracking (1h)
- [ ] **[P5-08]** Test matchmaker (if implemented) (1h)

**Validation**: Lobby shows live updates, presence tracking works

---

### Phase 6: Admin Panel (LiveView) (Est: 1-2 days)

**Goal**: Monitor games, server stats (internal tool)

#### LiveView Setup (2-3 hours)
- [ ] **[P6-01]** Create admin auth (basic, optional for MVP) (1h)
- [ ] **[P6-02]** Add admin routes in router (15min)

#### Admin LiveViews (4-6 hours)
- [ ] **[P6-03]** Create `lib/pidro_server_web/live/lobby_live.ex` (2h)
  - List active rooms
  - Show player counts
  - Subscribe to PubSub for updates
- [ ] **[P6-04]** Create `lib/pidro_server_web/live/game_monitor_live.ex` (2h)
  - Watch live game state
  - Subscribe to game events
  - Read-only view
- [ ] **[P6-05]** Create `lib/pidro_server_web/live/stats_live.ex` (optional) (2h)

**Validation**: Admin can view active games, monitor state in real-time

---

### Phase 7: Stats, Polish & Deployment (Est: 2-3 days)

**Goal**: Production-ready MVP

#### Database Stats (4-6 hours)
- [ ] **[P7-01]** Create game_stats migration (30min)
- [ ] **[P7-02]** Create `lib/pidro_server/stats/game_stats.ex` schema (1h)
- [ ] **[P7-03]** Create `lib/pidro_server/stats/stats.ex` context (2h)
  - Save game results on completion
  - Aggregate user stats
- [ ] **[P7-04]** Add GET /api/v1/users/me/stats endpoint (1h)

#### Error Handling & Polish (3-4 hours)
- [ ] **[P7-05]** Handle player disconnections gracefully (2h)
- [ ] **[P7-06]** Cleanup/timeout old rooms (1h)
- [ ] **[P7-07]** Polish error messages for clients (1h)

#### Quality Gates (4-6 hours)
- [ ] **[P7-08]** Add Credo and Dialyxir to mix.exs (15min)
- [ ] **[P7-09]** Create `.credo.exs` config for strict mode (30min)
- [ ] **[P7-10]** Fix all Credo warnings (2h)
- [ ] **[P7-11]** Add typespecs to key modules (2h)
- [ ] **[P7-12]** Fix Dialyzer warnings (1h)

#### Testing & Coverage (4-6 hours)
- [ ] **[P7-13]** Add StreamData for property-based tests (optional) (3h)
- [ ] **[P7-14]** Configure test coverage tracking (30min)
- [ ] **[P7-15]** Achieve >80% test coverage (varies)

#### Deployment (2-3 hours)
- [ ] **[P7-16]** Document deployment guide (1h)
- [ ] **[P7-17]** Add CORS configuration if needed (30min)
- [ ] **[P7-18]** Verify Mix release works (1h)

**Validation**: All quality gates pass, production deployment successful

---

## Detailed Module Status

### Core Infrastructure (lib/pidro_server/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| application.ex | ✅ Stub | Basic Phoenix supervision tree | ✅ N/A | - |
| repo.ex | ✅ Configured | Postgres adapter, no migrations | ✅ N/A | - |
| mailer.ex | ✅ Stub | Swoosh configured | ⚠️ Unused | - |

### Accounts Domain (lib/pidro_server/accounts/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **accounts/** | ❌ Missing | Directory doesn't exist | ❌ None | **P0** |
| user.ex | ❌ Missing | No schema | ❌ None | **P0** |
| auth.ex | ❌ Missing | No context | ❌ None | **P0** |
| token.ex | ❌ Missing | No JWT implementation | ❌ None | **P0** |

### Games Domain (lib/pidro_server/games/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **games/** | ❌ Missing | Directory doesn't exist | ❌ None | **P0** |
| supervisor.ex | ❌ Missing | No supervision tree | ❌ None | **P0** |
| game_supervisor.ex | ❌ Missing | No DynamicSupervisor | ❌ None | **P0** |
| game_registry.ex | ❌ Missing | No Registry setup | ❌ None | **P0** |
| room_manager.ex | ❌ Missing | No GenServer | ❌ None | **P0** |
| matchmaker.ex | ❌ Missing | Optional MVP+ | ❌ None | **P2** |
| game_adapter.ex | ❌ Missing | No engine integration | ❌ None | **P0** |

### Web Layer (lib/pidro_server_web/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| endpoint.ex | ✅ Configured | No /socket mount | ⚠️ Basic | - |
| router.ex | ⚠️ Stub | No API routes | ⚠️ Basic | **P0** |
| telemetry.ex | ✅ Configured | Standard metrics | ✅ N/A | - |

### Controllers (lib/pidro_server_web/controllers/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **api/** | ❌ Missing | Directory doesn't exist | ❌ None | **P0** |
| auth_controller.ex | ❌ Missing | No endpoints | ❌ None | **P0** |
| room_controller.ex | ❌ Missing | No endpoints | ❌ None | **P0** |
| user_controller.ex | ❌ Missing | No endpoints | ❌ None | **P1** |
| fallback_controller.ex | ❌ Missing | No error handling | ❌ None | **P0** |

### Channels (lib/pidro_server_web/channels/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **channels/** | ❌ Missing | Directory doesn't exist | ❌ None | **P0** |
| user_socket.ex | ❌ Missing | No socket definition | ❌ None | **P0** |
| lobby_channel.ex | ❌ Missing | No channel | ❌ None | **P1** |
| game_channel.ex | ❌ Missing | No channel | ❌ None | **P0** |

### LiveView (lib/pidro_server_web/live/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **live/** | ❌ Missing | Directory doesn't exist | ❌ None | **P2** |
| lobby_live.ex | ❌ Missing | No admin panel | ❌ None | **P2** |
| game_monitor_live.ex | ❌ Missing | No monitoring | ❌ None | **P2** |
| stats_live.ex | ❌ Missing | Optional | ❌ None | **P2** |

### Views (lib/pidro_server_web/views/)

| Module | Status | Implementation | Tests | Priority |
|--------|--------|----------------|-------|----------|
| **views/api/** | ❌ Missing | Directory doesn't exist | ❌ None | **P0** |
| room_view.ex | ❌ Missing | No JSON serialization | ❌ None | **P0** |
| user_view.ex | ❌ Missing | No JSON serialization | ❌ None | **P0** |
| error_view.ex | ❌ Missing | ErrorJSON exists instead | ⚠️ Basic | **P0** |

---

## Database Status

### Migrations (priv/repo/migrations/)

| Migration | Status | Priority |
|-----------|--------|----------|
| create_users.exs | ❌ Missing | **P0** |
| create_game_stats.exs | ❌ Missing | **P2** |

**Current migrations**: 0  
**Required migrations**: 2 (users = P0, game_stats = P2)

---

## Configuration Status

### Umbrella Root Config (../../config/)

| File | Status | Notes |
|------|--------|-------|
| **config/** | ✅ **EXISTS** | At umbrella root (correct for umbrella apps) |
| config/config.exs | ✅ Present | Configures pidro_server, Ecto, PubSub, assets |
| config/dev.exs | ✅ Present | Development environment |
| config/test.exs | ✅ Present | Test environment with sandbox |
| config/prod.exs | ✅ Present | Production settings |
| config/runtime.exs | ✅ Present | Runtime environment variables |

**Status**: ✅ Configuration properly set up at umbrella root

---

## Testing Status

### Current Coverage: <5%

| Test Area | Tests | Coverage | Priority |
|-----------|-------|----------|----------|
| **Accounts** | 0 | 0% | **P0** |
| **Games Domain** | 0 | 0% | **P0** |
| **REST Controllers** | 0 | 0% | **P0** |
| **Channels** | 0 | 0% | **P1** |
| **Integration** | 0 | 0% | **P1** |
| **Property-based** | 0 | 0% | **P2** |
| **Phoenix defaults** | 3 | ✅ | - |

### Test Infrastructure

| Component | Status |
|-----------|--------|
| conn_case.ex | ✅ Present |
| channel_case.ex | ❌ Missing |
| data_case.ex | ✅ Present |
| fixtures.ex | ❌ Missing |
| StreamData | ❌ Not installed |

**Target Coverage**: >80%  
**Gap**: ~75% of tests needed

---

## Quality Gates

### Current Status

| Gate | Status | Action |
|------|--------|--------|
| `mix compile` | ✅ Pass | - |
| `mix test` | ✅ Pass (3 tests) | Add business logic tests |
| `mix format --check-formatted` | ✅ Pass | - |
| `mix credo --strict` | ❌ Not configured | Add Credo |
| `mix dialyzer` | ❌ Not configured | Add Dialyxir |
| Test coverage >80% | ❌ <5% | Write tests |

### Recommended Dependencies

Add to mix.exs:
```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
{:stream_data, "~> 1.0", only: :test}
{:bcrypt_elixir, "~> 3.0"}  # or {:argon2_elixir, "~> 4.0"}
```

---

## Critical Dependencies

### Engine Integration

**Status**: ✅ **INTEGRATED**

| Item | Status | Action |
|------|--------|--------|
| pidro_engine app | ✅ Exists at ../pidro_engine | - |
| mix.exs dependency | ✅ Added | `{:pidro_engine, in_umbrella: true}` |
| bcrypt_elixir | ✅ Added | `{:bcrypt_elixir, "~> 3.0"}` |
| Code references | ⚠️ Pending | Import Pidro.Server in Phase 3 |
| GameAdapter | ❌ Missing | Create wrapper module in Phase 3 |

**NEXT ACTION**: Implement Phase 1 - Authentication Foundation

---

## Risks & Blockers

### 🔴 Critical Risks

1. **Engine not integrated** - Cannot start games (IMMEDIATE FIX: add to deps)
2. **No auth system** - Cannot protect endpoints
3. **No games domain** - Core functionality missing
4. **No password hashing** - Security risk

### ⚠️ High Risks

1. **No testing strategy** - Risk of regressions
2. **No deployment plan** - Unknown production readiness
3. **No error handling patterns** - Poor UX

### 💡 Recommendations

1. **Start with Phase 0 immediately** - Fix blocking issues
2. **Follow roadmap sequentially** - Auth → Games → Channels
3. **Write tests alongside implementation** - Maintain >70% coverage
4. **Review spec regularly** - Ensure alignment
5. **Use oracle for complex modules** - Get architectural guidance

---

## Success Criteria (MVP)

### Definition of Done

- [x] Phoenix scaffolding complete
- [ ] Users can register/login (**P0**)
- [ ] Users can create/join rooms via API (**P0**)
- [ ] 4 players start game automatically (**P0**)
- [ ] Complete game playable via WebSocket (**P1**)
- [ ] Game follows Finnish Pidro rules (via engine) (**P0**)
- [ ] Rooms close automatically after game (**P1**)
- [ ] Admin can monitor active games (**P2**)

### Quality Gates

- [ ] `mix test` - all tests pass
- [ ] Test coverage >80%
- [ ] `mix dialyzer` - no warnings
- [ ] `mix credo --strict` - clean
- [ ] Can handle 10 concurrent games
- [ ] Can handle 100 concurrent connections
- [ ] Documentation complete
- [ ] Deployable via Mix release

---

## Next Actions (Top 10)

1. **[URGENT]** Add `{:pidro_engine, in_umbrella: true}` to apps/pidro_server/mix.exs (5min)
2. **[URGENT]** Add password hashing lib (bcrypt_elixir) to mix.exs (5min)
3. **[URGENT]** Run `mix deps.get && mix compile` from umbrella root (5min)
4. Create users migration and schema (1h)
5. Implement auth context (register, login) (2h)
6. Create auth_controller with register/login endpoints (2h)
7. Create games/ directory and RoomManager GenServer (4h)
8. Create game supervision tree (2h)
9. Implement room_controller with CRUD endpoints (2h)
10. Write tests for auth and room management (4h)

**Estimated time to MVP**: 3-4 weeks with 1 developer

---

## Notes

- **No TODO comments found** - Codebase is clean scaffolding
- **Umbrella app structure** - Properly configured
- **Phoenix 1.8.1** - Modern Phoenix practices
- **Ecto configured** - Postgres ready
- **LiveView ready** - For admin panel
- **PubSub configured** - For real-time features

**Last analysis**: 2025-11-02 with 50+ subagent scans
