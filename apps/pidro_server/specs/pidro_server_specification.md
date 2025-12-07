# Pidro Server Specification

## Multiplayer Game Server - MVP Architecture

> "Simple made easy, concurrent by default, fault-tolerant by design"  
> Phoenix + OTP for a world-class multiplayer card game server

**Version**: 1.0.0  
**Phoenix**: 1.8.1  
**Target**: MVP - production-ready multiplayer server  
**Mobile Client**: React Native / Expo

---

## Table of Contents

1. [Architecture Philosophy](#architecture-philosophy)
2. [System Architecture](#system-architecture)
3. [API Design](#api-design)
4. [Module Structure](#module-structure)
5. [Database Schema](#database-schema)
6. [Authentication & Authorization](#authentication--authorization)
7. [Real-time Communication](#real-time-communication)
8. [Game Lifecycle](#game-lifecycle)
9. [Testing Strategy](#testing-strategy)
10. [Deployment & Operations](#deployment--operations)
11. [Implementation Roadmap](#implementation-roadmap)

---

## Architecture Philosophy

### Core Principles

1. **Boundary Separation**: Phoenix handles delivery, `pidro_engine` handles game logic
2. **Process Per Game**: Each game room is an isolated, supervised process
3. **Stateless API**: REST endpoints are stateless; state lives in game processes
4. **Real-time First**: WebSocket channels for gameplay, REST for room management
5. **Mobile-Native**: API designed for mobile apps (React Native), admin panel uses LiveView
6. **Minimal Database**: Store only what needs to persist (users, stats)
7. **Fail Independently**: Game crash ≠ server crash; room crash ≠ other rooms crash

### Design Influences

- **Lichess**: Stateful game servers, WebSocket communication
- **Discord**: Registry pattern for channel/server management
- **Phoenix Channels**: Built-in PubSub, Presence, scalability
- **OTP Patterns**: Supervision trees, Registry, DynamicSupervisor

---

## System Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Pidro Server (Phoenix)                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐      ┌──────────────┐                   │
│  │   REST API   │      │  WebSockets  │                   │
│  │ (Room CRUD)  │      │  (Gameplay)  │                   │
│  └──────┬───────┘      └──────┬───────┘                   │
│         │                     │                            │
│         └────────┬────────────┘                            │
│                  │                                          │
│         ┌────────▼─────────┐                               │
│         │  Room Manager    │  (GenServer)                  │
│         │  - Create rooms  │                               │
│         │  - Track players │                               │
│         └────────┬─────────┘                               │
│                  │                                          │
│         ┌────────▼─────────────────────┐                   │
│         │   Game Supervisor (Dynamic)  │                   │
│         │   - Supervise game processes │                   │
│         └────────┬─────────────────────┘                   │
│                  │                                          │
│         ┌────────▼─────────┐   ┌──────────┐               │
│         │  Game Process 1  ├───┤ Registry │               │
│         │ (Pidro.Server)   │   └──────────┘               │
│         └──────────────────┘                               │
│         │  Game Process 2  │   ┌──────────┐               │
│         │ (Pidro.Server)   ├───┤ Presence │               │
│         └──────────────────┘   └──────────┘               │
│         │  Game Process N  │                               │
│         │ (Pidro.Server)   │                               │
│         └──────────────────┘                               │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                   Pidro Engine (Pure Logic)                 │
│            (Stateless game rules & validation)              │
└─────────────────────────────────────────────────────────────┘
```

### Process Architecture

```
Application
├── PidroServer.Endpoint (Phoenix HTTP/WebSocket)
├── PidroServer.PubSub
├── PidroServer.Presence
├── PidroServer.Games.Supervisor
│   ├── PidroServer.Games.RoomManager (GenServer)
│   ├── PidroServer.Games.Matchmaker (GenServer)
│   ├── PidroServer.Games.GameRegistry (Registry)
│   └── PidroServer.Games.GameSupervisor (DynamicSupervisor)
│       ├── Game Process 1 (Pidro.Server via Registry)
│       ├── Game Process 2
│       └── Game Process N
└── PidroServer.Repo (if using Ecto)
```

---

## API Design

### REST API (Mobile Client)

**Base URL**: `/api/v1`

#### Authentication

```
POST   /api/v1/auth/register        # Create account
POST   /api/v1/auth/login           # Get JWT token
POST   /api/v1/auth/guest           # Guest token (optional MVP+)
DELETE /api/v1/auth/logout          # Invalidate token
GET    /api/v1/auth/me              # Current user info
```

#### Rooms

```
GET    /api/v1/rooms                # List available rooms
POST   /api/v1/rooms                # Create room
GET    /api/v1/rooms/:code          # Room details
POST   /api/v1/rooms/:code/join     # Join room (with optional position selection)
DELETE /api/v1/rooms/:code/leave    # Leave room
POST   /api/v1/rooms/:code/watch    # Join as spectator
DELETE /api/v1/rooms/:code/unwatch  # Leave spectating
```

#### Seat Selection (Join Room)

Players can optionally specify a seat preference when joining:

```
POST /api/v1/rooms/:code/join
Body: { "position": "<position>" }
```

**Position Values**:
- `null` or omitted - Auto-assign first available (N→E→S→W order)
- `"north"`, `"east"`, `"south"`, `"west"` - Specific seat
- `"north_south"`, `"east_west"` - Team preference (first available on team)

#### User

```
GET    /api/v1/users/me             # Current user profile
GET    /api/v1/users/me/stats       # User stats (wins, losses, etc.)
PATCH  /api/v1/users/me             # Update profile
```

#### Response Format

**Success (200, 201)**:

```json
{
  "data": {
    "id": "uuid",
    "type": "room",
    "attributes": { ... }
  }
}
```

**Error (4xx, 5xx)**:

```json
{
  "errors": [
    {
      "code": "ROOM_FULL",
      "title": "Room is full",
      "detail": "This room already has 4 players"
    }
  ]
}
```

#### Room Response Schema

Room responses now include position-related fields:

```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "host_id": "user123",
      "positions": {
        "north": "user456",
        "east": null,
        "south": null,
        "west": "user123"
      },
      "available_positions": ["east", "south"],
      "player_count": 2,
      "player_ids": ["user123", "user456"],
      "status": "waiting",
      "max_players": 4,
      "created_at": "2024-11-02T10:30:00Z"
    },
    "assigned_position": "north"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `positions` | Object | Map of position → player_id (null if empty) |
| `available_positions` | Array | Unoccupied positions list |
| `player_count` | Number | Count of seated players (0-4) |
| `assigned_position` | String | (Join response only) Assigned seat |
| `player_ids` | Array | Legacy field - derived from positions |

#### Seat Selection Error Codes

| Error Code | HTTP | Description |
|------------|------|-------------|
| `SEAT_TAKEN` | 422 | Requested seat is occupied |
| `TEAM_FULL` | 422 | Both team seats are taken |
| `INVALID_POSITION` | 422 | Invalid position value |

### WebSocket API (Channels)

#### Lobby Channel

```
Topic: "lobby"
Join params: %{token: jwt}

Outgoing events:
  - room_created: %{room: room_data}
  - room_updated: %{room: room_data}
  - room_closed: %{room_code: code}

Incoming events:
  - (none - lobby is read-only via channel)
```

#### Game Channel

```
Topic: "game:{room_code}"
Join params: %{token: jwt}

Outgoing events:
  - game_state: %{state: game_state, position: your_position}
  - player_joined: %{player: player_data}
  - player_left: %{player_id: id}
  - turn_changed: %{current_player: position}
  - game_over: %{winner: team, scores: scores}

Incoming events:
  - bid: %{amount: 6..14} | "pass"
  - declare_trump: %{suit: "hearts" | "diamonds" | "clubs" | "spades"}
  - play_card: %{card: %{rank: 2..14, suit: suit}}
  - ready: %{} (signal ready to start)
```

---

## Module Structure

```
lib/
├── pidro_server.ex                     # Application entry point
├── pidro_server/
│   ├── application.ex                  # OTP application
│   │
│   ├── games/                          # Game domain
│   │   ├── supervisor.ex               # Games supervision tree
│   │   ├── game_supervisor.ex          # DynamicSupervisor for games
│   │   ├── game_registry.ex            # Registry (via Registry)
│   │   ├── room_manager.ex             # Room CRUD, state tracking
│   │   ├── room/
│   │   │   └── positions.ex            # Pure seat assignment logic
│   │   ├── matchmaker.ex               # Queue-based matchmaking
│   │   └── game_adapter.ex             # Adapter for Pidro.Server
│   │
│   ├── accounts/                       # User management
│   │   ├── user.ex                     # User schema
│   │   ├── auth.ex                     # Authentication logic
│   │   └── token.ex                    # JWT token generation
│   │
│   └── stats/                          # Game statistics (optional MVP+)
│       ├── game_stats.ex               # Game history schema
│       └── stats.ex                    # Stats aggregation
│
├── pidro_server_web/
│   ├── endpoint.ex                     # Phoenix endpoint
│   ├── router.ex                       # Routes
│   ├── telemetry.ex                    # Telemetry
│   │
│   ├── controllers/                    # REST API
│   │   └── api/
│   │       ├── auth_controller.ex      # Auth endpoints
│   │       ├── room_controller.ex      # Room endpoints
│   │       ├── user_controller.ex      # User endpoints
│   │       └── fallback_controller.ex  # Error handling
│   │
│   ├── channels/                       # WebSocket channels
│   │   ├── user_socket.ex              # Socket connection
│   │   ├── lobby_channel.ex            # Lobby updates
│   │   └── game_channel.ex             # Real-time gameplay
│   │
│   ├── live/                           # LiveView (admin only)
│   │   ├── lobby_live.ex               # Lobby overview
│   │   ├── game_monitor_live.ex        # Watch games
│   │   └── stats_live.ex               # Server stats
│   │
│   ├── components/                     # Shared components
│   │   ├── core_components.ex          # Phoenix default
│   │   └── layouts.ex                  # Layouts
│   │
│   ├── serializers/                    # Data serialization
│   │   └── game_state_serializer.ex    # GameState → JSON-safe maps
│   │
│   └── views/                          # JSON views
│       └── api/
│           ├── room_view.ex            # Room serialization
│           ├── user_view.ex            # User serialization
│           └── error_view.ex           # Error serialization
│
└── test/
    ├── pidro_server/
    │   ├── games/                      # Game domain tests
    │   └── accounts/                   # Auth tests
    └── pidro_server_web/
        ├── controllers/                # API tests
        └── channels/                   # Channel tests
```

### Key Modules

#### `PidroServer.Games.RoomManager`

Manages room lifecycle, tracks players, enforces room rules.

```elixir
defmodule PidroServer.Games.RoomManager do
  use GenServer

  # Holds state of all rooms (not games - games are in Pidro.Server)
  # Room state: code, host, players, status, settings

  def create_room(host_id, opts \\ [])
  def join_room(room_code, player_id)
  def leave_room(player_id)
  def list_rooms(filter \\ :available)
  def get_room(room_code)
end
```

#### `PidroServer.Games.GameSupervisor`

Supervises game processes via DynamicSupervisor + Registry.

```elixir
defmodule PidroServer.Games.GameSupervisor do
  use DynamicSupervisor

  def start_game(room_code)
  def stop_game(room_code)
  def get_game(room_code)
  def list_games()
end
```

#### `PidroServer.Games.GameAdapter`

Helper functions to interact with `Pidro.Server` processes.

```elixir
defmodule PidroServer.Games.GameAdapter do
  # Convenience wrappers around Pidro.Server calls

  def apply_action(room_code, position, action)
  def get_state(room_code)
  def get_legal_actions(room_code, position)
  def subscribe(room_code)
end
```

---

## Database Schema

### Minimal MVP Schema

```elixir
# Postgres tables

# users
create table(:users) do
  add :username, :string, null: false
  add :email, :string
  add :password_hash, :string
  add :guest, :boolean, default: false

  timestamps()
end

create unique_index(:users, [:username])
create unique_index(:users, [:email])

# game_stats (optional - for leaderboards, analytics)
create table(:game_stats) do
  add :room_code, :string, null: false
  add :winner, :string  # :north_south | :east_west
  add :final_scores, :map  # %{north_south: 62, east_west: 45}
  add :bid_amount, :integer
  add :bid_team, :string
  add :duration_seconds, :integer
  add :completed_at, :utc_datetime

  # Denormalized player data for quick queries
  add :player_ids, {:array, :uuid}

  timestamps()
end

create index(:game_stats, [:completed_at])
create index(:game_stats, [:player_ids], using: "GIN")
```

**Why minimal?**

- Game state lives in `Pidro.Server` processes (in-memory)
- Only persist what's needed for long-term: users, historical stats
- No need to store active games in DB (they're in memory)

---

## Authentication & Authorization

### Token-Based Auth (JWT)

**Flow**:

1. User logs in → Server returns JWT
2. Mobile app stores JWT securely
3. All API requests include: `Authorization: Bearer <token>`
4. WebSocket connection uses: `%{token: jwt}` in join params

**Implementation**:

```elixir
# Option 1: Phoenix.Token (simpler, built-in)
defmodule PidroServer.Accounts.Token do
  @signing_salt "pidro_auth"
  @token_age_secs 86400 * 30  # 30 days

  def generate(user) do
    Phoenix.Token.sign(PidroServerWeb.Endpoint, @signing_salt, user.id)
  end

  def verify(token) do
    Phoenix.Token.verify(
      PidroServerWeb.Endpoint,
      @signing_salt,
      token,
      max_age: @token_age_secs
    )
  end
end

# Option 2: Guardian library (more features)
# Use if you need token refresh, permissions, etc.
```

**Plugs**:

```elixir
# lib/pidro_server_web/plugs/authenticate.ex
defmodule PidroServerWeb.Plugs.Authenticate do
  import Plug.Conn
  alias PidroServer.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- Accounts.Token.verify(token),
         user when not is_nil(user) <- Accounts.get_user(user_id) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.put_view(PidroServerWeb.ErrorView)
        |> Phoenix.Controller.render("401.json")
        |> halt()
    end
  end
end
```

### Authorization

**Rules**:

- Must be authenticated to create/join rooms
- Can only play in games you're part of
- Room host can kick players (optional MVP+)
- Admin panel requires `:admin` role (optional MVP+)

---

## Real-time Communication

### Phoenix Channels Architecture

#### `PidroServerWeb.UserSocket`

```elixir
defmodule PidroServerWeb.UserSocket do
  use Phoenix.Socket

  channel "lobby", PidroServerWeb.LobbyChannel
  channel "game:*", PidroServerWeb.GameChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case PidroServer.Accounts.Token.verify(token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}
      {:error, _} ->
        :error
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
```

#### `PidroServerWeb.LobbyChannel`

Broadcasts room list updates to all connected users.

```elixir
defmodule PidroServerWeb.LobbyChannel do
  use PidroServerWeb, :channel

  @impl true
  def join("lobby", _params, socket) do
    # Subscribe to lobby updates
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby_updates")

    # Send current room list
    rooms = PidroServer.Games.RoomManager.list_rooms()
    {:ok, %{rooms: rooms}, socket}
  end

  @impl true
  def handle_info({:room_created, room}, socket) do
    push(socket, "room_created", %{room: room})
    {:noreply, socket}
  end

  # Similar handlers for room_updated, room_closed
end
```

#### `PidroServerWeb.GameChannel`

Real-time gameplay channel.

```elixir
defmodule PidroServerWeb.GameChannel do
  use PidroServerWeb, :channel
  alias PidroServer.Games.{RoomManager, GameAdapter}

  @impl true
  def join("game:" <> room_code, _params, socket) do
    user_id = socket.assigns.user_id

    with {:ok, room} <- RoomManager.get_room(room_code),
         true <- user_id in room.player_ids,
         {:ok, _pid} <- GameAdapter.get_game(room_code),
         :ok <- GameAdapter.subscribe(room_code) do

      # Determine player position
      position = get_player_position(room, user_id)

      # Send initial state
      state = GameAdapter.get_state(room_code)

      socket =
        socket
        |> assign(:room_code, room_code)
        |> assign(:position, position)

      {:ok, %{state: state, position: position}, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("bid", %{"amount" => amount}, socket) do
    action = if amount == "pass", do: :pass, else: {:bid, amount}

    case GameAdapter.apply_action(
      socket.assigns.room_code,
      socket.assigns.position,
      action
    ) do
      {:ok, _new_state} ->
        {:reply, :ok, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("play_card", %{"card" => card_params}, socket) do
    card = parse_card(card_params)

    case GameAdapter.apply_action(
      socket.assigns.room_code,
      socket.assigns.position,
      {:play_card, card}
    ) do
      {:ok, _new_state} ->
        {:reply, :ok, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle game state updates from Pidro.Server
  @impl true
  def handle_info({:state_update, new_state}, socket) do
    broadcast(socket, "game_state", %{state: new_state})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:game_over, winner, scores}, socket) do
    broadcast(socket, "game_over", %{winner: winner, scores: scores})
    {:noreply, socket}
  end

  defp parse_card(%{"rank" => rank, "suit" => suit}) do
    {rank, String.to_atom(suit)}
  end
end
```

### Presence

Track online players in rooms.

```elixir
defmodule PidroServerWeb.Presence do
  use Phoenix.Presence,
    otp_app: :pidro_server,
    pubsub_server: PidroServer.PubSub
end

# In GameChannel
def handle_info(:after_join, socket) do
  push(socket, "presence_state", Presence.list(socket))

  {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{
    online_at: DateTime.utc_now(),
    position: socket.assigns.position
  })

  {:noreply, socket}
end
```

---

## Game Lifecycle

### State Machine

```
1. Room Created (waiting)
   ↓ (4 players joined)
2. Game Starting (all players ready)
   ↓ (game started via RoomManager)
3. Game Active (Pidro.Server process spawned)
   ↓ (game completes)
4. Game Over (save stats, close room)
   ↓
5. Room Closed (cleanup)
```

### Detailed Flow

**1. Room Creation**

```elixir
# Mobile app → POST /api/v1/rooms
# RoomManager creates room entry
# Broadcasts to lobby channel
# Returns room_code
```

**2. Players Join**

```elixir
# Mobile app → POST /api/v1/rooms/:code/join
# RoomManager adds player to room
# Broadcasts player_joined
# If 4 players → status = :ready
```

**3. Game Start**

```elixir
# All players signal ready (optional)
# RoomManager → GameSupervisor.start_game(room_code)
# Pidro.Server process spawned with room_code as Registry name
# Room status → :playing
```

**4. Gameplay**

```elixir
# Players connect to game:{room_code} channel
# Actions sent via handle_in("bid", ...), handle_in("play_card", ...)
# GameChannel → GameAdapter → Pidro.Server.apply_action()
# Pidro.Server broadcasts state updates
# GameChannel pushes updates to all players
```

**5. Game End**

```elixir
# Pidro.Server detects game over
# Broadcasts {:game_over, winner, scores}
# GameChannel receives, saves stats (optional)
# RoomManager marks room as :finished
# Room auto-closes after timeout (e.g., 5 min)
```

**6. Cleanup**

```elixir
# GameSupervisor terminates Pidro.Server
# RoomManager removes room entry
# Players disconnected from channel
```

---

## Testing Strategy

### Test Pyramid

```
        ╱ ╲
       ╱ E2E╲ (5%) - Channel integration tests
      ╱───────╲
     ╱  API   ╲ (15%) - Controller tests
    ╱──────────╲
   ╱  Domain   ╲ (30%) - RoomManager, GameAdapter
  ╱─────────────╲
 ╱     Engine   ╲ (50%) - Already done in pidro_engine
╱───────────────╲
```

### Test Files

```
test/
├── pidro_server/
│   ├── games/
│   │   ├── room_manager_test.exs
│   │   ├── game_supervisor_test.exs
│   │   └── game_adapter_test.exs
│   └── accounts/
│       ├── user_test.exs
│       └── auth_test.exs
│
├── pidro_server_web/
│   ├── controllers/
│   │   └── api/
│   │       ├── auth_controller_test.exs
│   │       ├── room_controller_test.exs
│   │       └── user_controller_test.exs
│   │
│   └── channels/
│       ├── lobby_channel_test.exs
│       └── game_channel_test.exs
│
└── support/
    ├── conn_case.ex
    ├── channel_case.ex
    └── fixtures.ex
```

### Example Tests

```elixir
# test/pidro_server/games/room_manager_test.exs
defmodule PidroServer.Games.RoomManagerTest do
  use ExUnit.Case, async: true
  alias PidroServer.Games.RoomManager

  setup do
    {:ok, _pid} = start_supervised(RoomManager)
    :ok
  end

  test "create_room generates unique code" do
    {:ok, code1, _room} = RoomManager.create_room("user1")
    {:ok, code2, _room} = RoomManager.create_room("user2")

    assert code1 != code2
  end

  test "join_room adds player to room" do
    {:ok, code, _room} = RoomManager.create_room("host")
    {:ok, room} = RoomManager.join_room(code, "player2")

    assert length(room.player_ids) == 2
    assert "player2" in room.player_ids
  end

  test "join_room fails when room full" do
    {:ok, code, _room} = RoomManager.create_room("host")
    RoomManager.join_room(code, "p2")
    RoomManager.join_room(code, "p3")
    RoomManager.join_room(code, "p4")

    assert {:error, :room_full} = RoomManager.join_room(code, "p5")
  end
end
```

```elixir
# test/pidro_server_web/channels/game_channel_test.exs
defmodule PidroServerWeb.GameChannelTest do
  use PidroServerWeb.ChannelCase
  alias PidroServerWeb.{UserSocket, GameChannel}
  alias PidroServer.Games.{RoomManager, GameSupervisor}

  setup do
    # Create room and start game
    {:ok, room_code, _room} = RoomManager.create_room("user1")
    RoomManager.join_room(room_code, "user2")
    RoomManager.join_room(room_code, "user3")
    RoomManager.join_room(room_code, "user4")
    {:ok, _pid} = GameSupervisor.start_game(room_code)

    # Connect socket
    token = PidroServer.Accounts.Token.generate(%{id: "user1"})
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, socket: socket, room_code: room_code}
  end

  test "join game channel returns initial state", %{socket: socket, room_code: code} do
    {:ok, reply, _socket} = subscribe_and_join(socket, GameChannel, "game:#{code}")

    assert %{state: state, position: position} = reply
    assert state.phase == :dealer_selection
    assert position in [:north, :east, :south, :west]
  end

  test "bid action updates game state", %{socket: socket, room_code: code} do
    {:ok, _reply, socket} = subscribe_and_join(socket, GameChannel, "game:#{code}")

    ref = push(socket, "bid", %{"amount" => 8})
    assert_reply ref, :ok

    assert_broadcast "game_state", %{state: new_state}
  end
end
```

---

## Deployment & Operations

### Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")

  config :pidro_server, PidroServer.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :pidro_server, PidroServerWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4000")
    ],
    secret_key_base: secret_key_base,
    url: [host: System.get_env("HOST"), port: 443, scheme: "https"]
end
```

### Release Configuration

```elixir
# mix.exs
def project do
  [
    # ...
    releases: [
      pidro_server: [
        include_executables_for: [:unix],
        applications: [
          pidro_engine: :permanent,
          pidro_server: :permanent
        ]
      ]
    ]
  ]
end
```

### Monitoring

```elixir
# Telemetry metrics for dashboard
def metrics do
  [
    # Game metrics
    last_value("pidro_server.games.active_count"),
    counter("pidro_server.games.started.count"),
    counter("pidro_server.games.completed.count"),
    distribution("pidro_server.games.duration", unit: {:native, :second}),

    # Channel metrics
    last_value("pidro_server.channels.connected_count"),
    counter("pidro_server.channels.joins.count"),

    # Phoenix metrics
    summary("phoenix.endpoint.stop.duration",
      unit: {:native, :millisecond}
    ),
    summary("phoenix.router_dispatch.stop.duration",
      tags: [:route],
      unit: {:native, :millisecond}
    )
  ]
end
```

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1)

**Goal**: Runnable Phoenix app with basic structure

- [x] Generate Phoenix app
- [x] Configure umbrella deps (`pidro_engine`)
- [x] Setup database (if using Ecto)
- [x] Basic auth: registration, login, JWT
- [x] Health check endpoint
- [x] Basic test setup

**Validation**: `mix test` passes, can register/login

---

### Phase 2: Room Management (Week 1-2)

**Goal**: Create and join rooms

**Backend**:

- [x] `RoomManager` GenServer
- [x] `GameRegistry` (Registry setup)
- [x] `GameSupervisor` (DynamicSupervisor)
- [x] Room REST endpoints (CRUD)
- [x] Room tests

**Validation**: Can create/join rooms via API, see room list

---

### Phase 3: Game Integration (Week 2)

**Goal**: Start games with engine

- [x] `GameAdapter` module
- [x] Integrate `Pidro.Server` (Phase 11 of engine)
- [x] Start game when room full
- [x] Basic game state API endpoint
- [x] Integration tests

**Validation**: 4 players join → game process starts, can query state

---

### Phase 4: Real-time Gameplay (Week 2-3)

**Goal**: Play complete games via WebSocket

**Channels**:

- [x] `UserSocket` with auth
- [x] `GameChannel` (join, actions, broadcasts)
- [x] State synchronization
- [x] Channel tests

**API**:

- [x] Wire up bid, declare_trump, play_card events
- [x] Handle errors gracefully
- [x] Broadcast to all players

**Validation**: 4 players can complete full game via channels

---

### Phase 5: Lobby System (Week 3)

**Goal**: See available games, matchmaking

- [x] `LobbyChannel` for room list updates
- [ ] `Matchmaker` (optional queue system) - **Deferred to Post-MVP**
- [x] Presence tracking
- [x] Polish error handling

**Validation**: See live room list, get matched automatically

---

### Phase 6: Admin Panel (Week 3-4)

**Goal**: Monitor games (internal tool)

- [x] LiveView: lobby overview
- [x] LiveView: game monitor (watch live)
- [x] LiveView: server stats
- [x] Basic admin auth

**Validation**: Admin can see active games, monitor state

---

### Phase 7: Stats & Polish (Week 4)

**Goal**: MVP complete

- [x] Save game stats to DB
- [x] User stats endpoint
- [x] Handle disconnections gracefully
- [x] Cleanup/timeout old rooms
- [x] Documentation
- [x] Deployment guide

**Validation**: Production-ready multiplayer server

---

### Phase 8: Mobile Client (Week 5+)

**Goal**: React Native app

- [ ] API client library
- [ ] WebSocket connection
- [ ] UI screens: login, lobby, game
- [ ] Connect to staging server

---

## File Checklist

### Required Files

```
apps/pidro_server/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   ├── runtime.exs
│   └── test.exs
│
├── lib/
│   ├── pidro_server.ex
│   ├── pidro_server/
│   │   ├── application.ex ✓
│   │   ├── games/
│   │   │   ├── supervisor.ex
│   │   │   ├── game_supervisor.ex
│   │   │   ├── game_registry.ex
│   │   │   ├── room_manager.ex
│   │   │   ├── matchmaker.ex (optional MVP)
│   │   │   └── game_adapter.ex
│   │   ├── accounts/
│   │   │   ├── user.ex (schema if using Ecto)
│   │   │   ├── auth.ex
│   │   │   └── token.ex
│   │   └── repo.ex (if using Ecto)
│   │
│   └── pidro_server_web/
│       ├── endpoint.ex ✓
│       ├── router.ex ✓
│       ├── telemetry.ex ✓
│       ├── controllers/
│       │   └── api/
│       │       ├── auth_controller.ex
│       │       ├── room_controller.ex
│       │       ├── user_controller.ex
│       │       └── fallback_controller.ex
│       ├── channels/
│       │   ├── user_socket.ex
│       │   ├── lobby_channel.ex
│       │   └── game_channel.ex
│       ├── live/ (admin panel)
│       │   ├── lobby_live.ex
│       │   └── game_monitor_live.ex
│       ├── components/
│       │   ├── core_components.ex ✓
│       │   └── layouts.ex ✓
│       └── views/
│           └── api/
│               ├── room_view.ex
│               ├── user_view.ex
│               └── error_view.ex
│
├── test/
│   ├── pidro_server/
│   │   ├── games/
│   │   └── accounts/
│   ├── pidro_server_web/
│   │   ├── controllers/
│   │   └── channels/
│   └── support/
│       ├── conn_case.ex
│       ├── channel_case.ex
│       └── fixtures.ex
│
├── priv/
│   └── repo/migrations/ (if using Ecto)
│
└── mix.exs
```

---

## Success Criteria

### MVP Definition of Done

**Core Features**:

- ✅ Users can register/login
- ✅ Users can create/join rooms via API
- ✅ 4 players start game automatically
- ✅ Complete game playable via WebSocket
- ✅ Game follows Finnish Pidro rules (via `pidro_engine`)
- ✅ Rooms close automatically after game
- ✅ Admin can monitor active games

**Quality Gates**:

- ✅ `mix test` - all tests pass
- ✅ `mix dialyzer` - no warnings
- ✅ `mix credo --strict` - clean
- ✅ Test coverage > 80%
- ✅ Can handle 10 concurrent games
- ✅ Can handle 100 concurrent connections
- ✅ Documentation complete

**Non-Functional**:

- ✅ Crashes isolated (one game crash ≠ server crash)
- ✅ Graceful error handling
- ✅ Clear error messages to clients
- ✅ Mobile-ready API
- ✅ Deployable via Mix release

---

## Future Enhancements (Post-MVP)

- [ ] Matchmaking with ELO/ranking
- [ ] Reconnection handling (rejoin game after disconnect) - **Completed in MVP**
- [ ] Spectator mode - **Completed in MVP**
- [ ] Chat system
- [ ] Friends list
- [ ] Tournaments
- [ ] **Replay System / Historical Game View** (using event sourcing)
  - Requires schema update to persist full event log
  - Enables "Watch Replay" feature
- [ ] Leaderboards (UI implementation - backend ready)
- [ ] Push notifications (mobile)
- [ ] Horizontal scaling (distributed Elixir)

---

## Architecture Decisions

### ADR-001: Use Registry for Game Lookup

**Decision**: Use Elixir's built-in `Registry` instead of custom ETS table  
**Rationale**: Registry is supervised, provides conflict-free names, integrates with DynamicSupervisor  
**Trade-offs**: None for MVP scale

### ADR-002: Minimal Database Usage

**Decision**: Keep game state in memory (Pidro.Server processes), only persist users + stats  
**Rationale**: Stateful games are OTP's strength, DB writes are bottleneck  
**Trade-offs**: Lost games on server restart (acceptable for MVP)

### ADR-003: REST + WebSocket Hybrid

**Decision**: REST for room management, WebSocket for gameplay  
**Rationale**: REST is stateless (easier for mobile), WebSocket for low-latency gameplay  
**Trade-offs**: Two protocols to maintain

### ADR-004: Token-Based Auth

**Decision**: JWT tokens instead of session cookies  
**Rationale**: Stateless auth works with mobile apps, easy to scale  
**Trade-offs**: Cannot revoke tokens (acceptable for MVP with short expiry)

### ADR-005: No Game State Persistence

**Decision**: Don't save game state to DB during play  
**Rationale**: State is in Pidro.Server (pure functional), can replay from events if needed  
**Trade-offs**: Games lost on crash (add in post-MVP if needed)

---

## Appendix

### Sample cURL Commands

```bash
# Register
curl -X POST http://localhost:4000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username": "alice", "password": "secret123"}'

# Login
curl -X POST http://localhost:4000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "alice", "password": "secret123"}'
# Returns: {"data": {"token": "eyJhbG..."}}

# Create room
curl -X POST http://localhost:4000/api/v1/rooms \
  -H "Authorization: Bearer eyJhbG..." \
  -H "Content-Type: application/json"
# Returns: {"data": {"code": "A3F9", ...}}

# Join room
curl -X POST http://localhost:4000/api/v1/rooms/A3F9/join \
  -H "Authorization: Bearer eyJhbG..."
```

### Sample WebSocket Messages

```javascript
// Connect
const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: userToken },
});
socket.connect();

// Join game
const channel = socket.channel("game:A3F9");
channel.join().receive("ok", ({ state, position }) => {
  console.log("Joined as", position);
  console.log("Game state:", state);
});

// Make bid
channel
  .push("bid", { amount: 8 })
  .receive("ok", () => console.log("Bid accepted"))
  .receive("error", (err) => console.log("Bid failed:", err));

// Listen for updates
channel.on("game_state", ({ state }) => {
  console.log("State update:", state);
});
```

---

**End of Specification**

---

## Quick Start

```bash
# 1. Generate Phoenix app
cd apps
mix phx.new pidro_server --umbrella --no-ecto  # or with ecto

# 2. Configure deps
# In apps/pidro_server/mix.exs, add:
{:pidro_engine, in_umbrella: true}

# 3. Generate authentication
cd pidro_server
mix phx.gen.auth Accounts User users

# 4. Follow implementation roadmap phases

# 5. Run server
cd ../..  # back to umbrella root
mix phx.server
```

Ready to ship! 🚀
