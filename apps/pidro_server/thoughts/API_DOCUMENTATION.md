# Pidro Server - API Documentation

Welcome to the Pidro Server API documentation! This guide will help you get started with building clients for the Pidro multiplayer card game.

**Version**: 1.0.0
**Base URL**: `http://localhost:4000` (development)

---

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Authentication](#authentication)
4. [REST API](#rest-api)
5. [WebSocket API](#websocket-api)
6. [Documentation Resources](#documentation-resources)
7. [Common Workflows](#common-workflows)
8. [Error Handling](#error-handling)
9. [Rate Limiting](#rate-limiting)
10. [Support](#support)

---

## Overview

The Pidro Server API provides a complete backend for building multiplayer Finnish Pidro card game clients. It's built with Phoenix/Elixir and offers both REST and WebSocket interfaces.

### Key Features

- **User Management**: Registration, authentication, and profile management
- **JWT Authentication**: Secure token-based authentication
- **Room System**: Create and join game rooms with up to 4 players
- **Real-time Gameplay**: WebSocket channels for live game updates
- **Statistics Tracking**: Track wins, losses, and game performance
- **Admin Panel**: LiveView-powered monitoring and management tools
- **OpenAPI Documentation**: Interactive API explorer and reference

### Technology Stack

- **Framework**: Phoenix 1.7 (Elixir)
- **Database**: PostgreSQL
- **Real-time**: Phoenix Channels (WebSockets)
- **Authentication**: Guardian (JWT)
- **API Docs**: OpenAPI 3.0 (via OpenApiSpex)

---

## Quick Start

### Prerequisites

- Elixir 1.15+ and Erlang/OTP 26+
- PostgreSQL 14+
- Node.js 18+ (for development)

### Installation

```bash
# Clone the repository (if applicable)
git clone <repository-url>
cd pidro_backend

# Install dependencies
mix deps.get
mix setup

# Start the server
mix phx.server
```

The server will be available at `http://localhost:4000`.

### Your First API Call

Try the health check endpoint:

```bash
curl http://localhost:4000/
```

Register a new user:

```bash
curl -X POST http://localhost:4000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{
    "user": {
      "username": "player1",
      "email": "player1@example.com",
      "password": "securepass123"
    }
  }'
```

---

## Authentication

The Pidro API uses JWT (JSON Web Tokens) for authentication. Most endpoints require a valid token.

### Register a New User

**Endpoint**: `POST /api/v1/auth/register`

**Request Body**:
```json
{
  "user": {
    "username": "john_doe",
    "email": "john@example.com",
    "password": "secure_password_123"
  }
}
```

**Response** (201 Created):
```json
{
  "data": {
    "user": {
      "id": 1,
      "username": "john_doe",
      "email": "john@example.com",
      "guest": false,
      "inserted_at": "2025-11-02T10:30:00Z",
      "updated_at": "2025-11-02T10:30:00Z"
    },
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
  }
}
```

**Validation Rules**:
- Username: Minimum 3 characters, must be unique
- Email: Valid email format, must be unique
- Password: Minimum 8 characters

### Login

**Endpoint**: `POST /api/v1/auth/login`

**Request Body**:
```json
{
  "username": "john_doe",
  "password": "secure_password_123"
}
```

**Response** (200 OK):
```json
{
  "data": {
    "user": {
      "id": 1,
      "username": "john_doe",
      "email": "john@example.com",
      "guest": false
    },
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
  }
}
```

### Using Your Token

Include the JWT token in the `Authorization` header for authenticated requests:

```bash
curl http://localhost:4000/api/v1/auth/me \
  -H "Authorization: Bearer <your-token-here>"
```

### Get Current User

**Endpoint**: `GET /api/v1/auth/me`
**Authentication**: Required

**Response** (200 OK):
```json
{
  "data": {
    "user": {
      "id": 1,
      "username": "john_doe",
      "email": "john@example.com",
      "guest": false
    }
  }
}
```

---

## REST API

The REST API provides endpoints for user management, room operations, and game state queries.

### Base URL

All REST endpoints are prefixed with `/api/v1`:

```
http://localhost:4000/api/v1
```

### Endpoint Categories

#### Authentication (`/auth`)
- `POST /auth/register` - Register new user
- `POST /auth/login` - Login and get token
- `GET /auth/me` - Get current user (requires auth)

#### Users (`/users`)
- `GET /users/me/stats` - Get current user's game statistics (requires auth)

#### Rooms (`/rooms`)
- `GET /rooms` - List all available rooms
- `GET /rooms?filter=waiting` - List rooms waiting for players
- `GET /rooms/:code` - Get specific room details
- `GET /rooms/:code/state` - Get current game state for a room
- `POST /rooms` - Create a new room (requires auth)
- `POST /rooms/:code/join` - Join a room with optional seat selection (requires auth)
- `DELETE /rooms/:code/leave` - Leave a room (requires auth)
- `POST /rooms/:code/watch` - Join as spectator (requires auth)
- `DELETE /rooms/:code/unwatch` - Leave spectating (requires auth)

### Example: Creating and Joining a Room

**Create a Room**:
```bash
curl -X POST http://localhost:4000/api/v1/rooms \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "room": {
      "name": "Friday Night Game"
    }
  }'
```

**Response** (201 Created):
```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "host_id": "user123",
      "positions": { "north": null, "east": null, "south": null, "west": "user123" },
      "available_positions": ["north", "east", "south"],
      "player_count": 1,
      "player_ids": ["user123"],
      "status": "waiting",
      "max_players": 4,
      "created_at": "2025-11-02T10:30:00Z"
    },
    "code": "A1B2"
  }
}
```

**Join a Room** (Auto-assign):
```bash
curl -X POST http://localhost:4000/api/v1/rooms/A1B2/join \
  -H "Authorization: Bearer <token>"
```

**Join a Room** (Specific Seat):
```bash
curl -X POST http://localhost:4000/api/v1/rooms/A1B2/join \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{ "position": "north" }'
```

**Join a Room** (Team Preference):
```bash
curl -X POST http://localhost:4000/api/v1/rooms/A1B2/join \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{ "position": "north_south" }'
```

**Position Values**:
- `null` or omitted - Auto-assign first available (N→E→S→W order)
- `"north"`, `"east"`, `"south"`, `"west"` - Specific seat
- `"north_south"`, `"east_west"` - Team preference

**Response** (200 OK):
```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "host_id": "user123",
      "positions": { "north": "user456", "east": null, "south": null, "west": "user123" },
      "available_positions": ["east", "south"],
      "player_count": 2,
      "player_ids": ["user123", "user456"],
      "status": "waiting",
      "max_players": 4
    },
    "assigned_position": "north"
  }
}
```

**Seat Selection Errors**:

| Error Code | HTTP | Description |
|------------|------|-------------|
| `SEAT_TAKEN` | 422 | Requested seat is already occupied |
| `TEAM_FULL` | 422 | Both seats on requested team are taken |
| `INVALID_POSITION` | 422 | Invalid position value provided |

### User Statistics

**Endpoint**: `GET /api/v1/users/me/stats`
**Authentication**: Required

**Response** (200 OK):
```json
{
  "data": {
    "games_played": 42,
    "wins": 25,
    "losses": 17,
    "win_rate": 0.595,
    "total_duration_seconds": 12600,
    "average_bid": 10.5
  }
}
```

---

## WebSocket API

For real-time gameplay, the Pidro Server uses Phoenix Channels over WebSockets.

### Connection

Connect to the WebSocket endpoint:

```
ws://localhost:4000/socket/websocket
```

### Authentication

Authenticate your socket connection by including the JWT token in the connection params:

```javascript
import { Socket } from "phoenix"

const socket = new Socket("ws://localhost:4000/socket/websocket", {
  params: { token: yourJwtToken }
})

socket.connect()
```

### Available Channels

#### 1. Lobby Channel (`lobby`)

The lobby channel provides real-time updates about available rooms.

**Join the Lobby**:
```javascript
const lobbyChannel = socket.channel("lobby", {})

lobbyChannel.join()
  .receive("ok", ({ rooms }) => {
    console.log("Joined lobby. Current rooms:", rooms)
  })
  .receive("error", (error) => {
    console.error("Failed to join lobby:", error)
  })
```

**Incoming Events**:
- `room_created` - New room was created
- `room_updated` - Room state changed (player joined/left)
- `room_closed` - Room was closed
- `presence_state` - Current lobby presence
- `presence_diff` - Presence changes

**Event Payloads**:
```javascript
// room_created
lobbyChannel.on("room_created", ({ room }) => {
  console.log("New room:", room)
})

// room_updated
lobbyChannel.on("room_updated", ({ room }) => {
  console.log("Room updated:", room)
})

// room_closed
lobbyChannel.on("room_closed", ({ room_code }) => {
  console.log("Room closed:", room_code)
})
```

#### 2. Game Channel (`game:<room_code>`)

The game channel handles real-time gameplay for a specific room.

**Join a Game**:
```javascript
const gameChannel = socket.channel("game:A1B2", {})

gameChannel.join()
  .receive("ok", ({ state, position }) => {
    console.log("Joined game as", position)
    console.log("Game state:", state)
  })
  .receive("error", (error) => {
    console.error("Failed to join game:", error)
  })
```

**Outgoing Events** (Client → Server):

| Event | Payload | Description |
|-------|---------|-------------|
| `bid` | `{ amount: 8 }` or `{ amount: "pass" }` | Make a bid or pass |
| `declare_trump` | `{ suit: "hearts" }` | Declare trump suit (after winning bid) |
| `play_card` | `{ card: { rank: 14, suit: "spades" } }` | Play a card from hand |
| `ready` | `{}` | Signal ready to start |

**Incoming Events** (Server → Client):

| Event | Payload | Description |
|-------|---------|-------------|
| `game_state` | `{ state: {...} }` | Full game state update |
| `player_joined` | `{ player_id, position }` | New player joined |
| `player_left` | `{ player_id }` | Player left the game |
| `turn_changed` | `{ current_player }` | Current turn changed |
| `game_over` | `{ winner, scores }` | Game ended |
| `presence_state` | Presence info | Who's currently online |
| `presence_diff` | Presence changes | Online status changes |

**Example: Playing a Game**:
```javascript
// Listen for state updates
gameChannel.on("game_state", ({ state }) => {
  console.log("Game state updated:", state)
  updateGameUI(state)
})

// Make a bid
gameChannel.push("bid", { amount: 8 })
  .receive("ok", () => console.log("Bid accepted"))
  .receive("error", (error) => console.error("Bid rejected:", error))

// Declare trump (if you won the bid)
gameChannel.push("declare_trump", { suit: "hearts" })
  .receive("ok", () => console.log("Trump declared"))

// Play a card
gameChannel.push("play_card", {
  card: { rank: 14, suit: "spades" }
})
  .receive("ok", () => console.log("Card played"))
  .receive("error", (error) => console.error("Invalid play:", error))

// Listen for game over
gameChannel.on("game_over", ({ winner, scores }) => {
  console.log("Game finished!", winner, scores)
})
```

**Game State Structure**:
```javascript
{
  "phase": "bidding",           // "bidding", "trump_declaration", "playing", "finished"
  "hand_number": 1,
  "current_turn": "north",
  "current_dealer": "west",
  "players": {
    "north": {
      "position": "north",
      "team": "north_south",
      "hand": [[14, "hearts"], [13, "hearts"], ...],
      "tricks_won": 0
    },
    // ... other players
  },
  "bids": [
    {"position": "west", "amount": "pass"},
    {"position": "north", "amount": 8}
  ],
  "tricks": [],
  "cumulative_scores": {
    "north_south": 0,
    "east_west": 0
  }
}
```

For complete WebSocket API documentation, see the [WebSocket API Guide](./WEBSOCKET_API.md) (when available).

---

## Documentation Resources

The Pidro Server provides multiple documentation resources for developers:

### Interactive API Documentation

Access these URLs when the server is running:

#### Swagger UI (Interactive API Explorer)
```
http://localhost:4000/api/swagger
```
- Interactive interface to explore and test all REST endpoints
- Try out API calls directly from your browser
- View request/response schemas
- Test authentication flows

#### Redoc (API Reference)
```
http://localhost:4000/api/redoc
```
- Clean, readable API reference documentation
- Complete endpoint specifications
- Request/response examples
- Schema definitions

#### OpenAPI Specification (JSON)
```
http://localhost:4000/api/openapi
```
- Raw OpenAPI 3.0 specification in JSON format
- Import into tools like Postman, Insomnia, or API clients
- Generate client libraries in various languages

### Module Documentation (ExDoc)

Generate HTML documentation for all Elixir modules:

```bash
mix docs
```

Then open `doc/index.html` in your browser for:
- Complete module documentation
- Function references
- Code examples
- Architecture guides

### Additional Resources

- **README.md** - Basic setup and getting started
- **DEPLOYMENT.md** - Production deployment guide
- **MASTERPLAN.md** - Project architecture and planning
- **This file** - High-level API guide

---

## Common Workflows

### Workflow 1: New User Game Session

A typical flow for a new user starting a game:

1. **Register an account**:
   ```bash
   POST /api/v1/auth/register
   ```

2. **Receive JWT token** from registration response

3. **Connect to WebSocket** with token:
   ```javascript
   socket = new Socket("ws://localhost:4000/socket/websocket", {
     params: { token: jwt_token }
   })
   socket.connect()
   ```

4. **Join the lobby channel**:
   ```javascript
   lobbyChannel = socket.channel("lobby", {})
   lobbyChannel.join()
   ```

5. **Create a new room**:
   ```bash
   POST /api/v1/rooms
   Authorization: Bearer <token>
   ```

6. **Join the game channel**:
   ```javascript
   gameChannel = socket.channel("game:A1B2", {})
   gameChannel.join()
   ```

7. **Wait for players** - Monitor `room_updated` events in lobby

8. **Game starts automatically** when 4 players join

9. **Play the game** - Send `bid`, `declare_trump`, and `play_card` events

10. **View stats** after game:
    ```bash
    GET /api/v1/users/me/stats
    Authorization: Bearer <token>
    ```

### Workflow 2: Joining an Existing Game

1. **Login**:
   ```bash
   POST /api/v1/auth/login
   ```

2. **Connect WebSocket** with token

3. **Join lobby** and view available rooms:
   ```bash
   GET /api/v1/rooms?filter=waiting
   ```

4. **Join a room**:
   ```bash
   POST /api/v1/rooms/A1B2/join
   Authorization: Bearer <token>
   ```

5. **Join game channel**:
   ```javascript
   gameChannel = socket.channel("game:A1B2", {})
   gameChannel.join()
   ```

6. **Start playing** when game begins

### Workflow 3: Spectating a Game

1. **Login** (if authenticated) or **browse public rooms**:
   ```bash
   GET /api/v1/rooms
   ```

2. **View room details**:
   ```bash
   GET /api/v1/rooms/A1B2
   ```

3. **Get current game state**:
   ```bash
   GET /api/v1/rooms/A1B2/state
   ```

4. Optionally **join game channel** to watch real-time updates (if permissions allow)

---

## Error Handling

All API errors follow a consistent JSON format for easy parsing and handling.

### Error Response Format

```json
{
  "errors": [
    {
      "code": "ERROR_CODE",
      "title": "Human-readable title",
      "detail": "Detailed error message with context"
    }
  ]
}
```

### Common HTTP Status Codes

| Status Code | Meaning | Common Scenarios |
|-------------|---------|------------------|
| **200 OK** | Success | Request completed successfully |
| **201 Created** | Resource created | User registered, room created |
| **204 No Content** | Success, no response body | Successfully left room |
| **400 Bad Request** | Invalid request format | Malformed JSON, missing fields |
| **401 Unauthorized** | Authentication required/failed | Missing token, invalid credentials, expired token |
| **404 Not Found** | Resource doesn't exist | Room not found, user not found |
| **422 Unprocessable Entity** | Validation failed | Username taken, invalid email, room full |
| **500 Internal Server Error** | Server error | Unexpected server issue |

### Common Error Codes

#### Authentication Errors

```json
{
  "errors": [
    {
      "code": "INVALID_CREDENTIALS",
      "title": "Invalid credentials",
      "detail": "Username or password is incorrect"
    }
  ]
}
```

```json
{
  "errors": [
    {
      "code": "UNAUTHORIZED",
      "title": "Unauthorized",
      "detail": "Authentication required"
    }
  ]
}
```

#### Validation Errors

```json
{
  "errors": [
    {
      "code": "username",
      "title": "Username",
      "detail": "has already been taken"
    },
    {
      "code": "email",
      "title": "Email",
      "detail": "has invalid format"
    }
  ]
}
```

#### Room Errors

```json
{
  "errors": [
    {
      "code": "ROOM_FULL",
      "title": "Room full",
      "detail": "Room already has 4 players"
    }
  ]
}
```

```json
{
  "errors": [
    {
      "code": "ALREADY_IN_ROOM",
      "title": "Already in room",
      "detail": "User is already in another room"
    }
  ]
}
```

```json
{
  "errors": [
    {
      "code": "NOT_FOUND",
      "title": "Not found",
      "detail": "Resource not found"
    }
  ]
}
```

#### Game Errors

```json
{
  "errors": [
    {
      "code": "GAME_NOT_FOUND",
      "title": "Game not found",
      "detail": "No game is currently active for this room"
    }
  ]
}
```

### Error Handling Best Practices

1. **Always check the HTTP status code** first
2. **Parse the error array** - there may be multiple validation errors
3. **Display user-friendly messages** based on error codes
4. **Log full error details** for debugging
5. **Handle 401 errors** by redirecting to login
6. **Implement retry logic** for 5xx errors with exponential backoff

### Example Error Handling (JavaScript)

```javascript
async function makeRequest(url, options) {
  try {
    const response = await fetch(url, options)
    const data = await response.json()

    if (!response.ok) {
      // Handle error
      if (response.status === 401) {
        // Redirect to login
        redirectToLogin()
      } else if (data.errors) {
        // Display validation errors
        data.errors.forEach(error => {
          showError(`${error.title}: ${error.detail}`)
        })
      }
      throw new Error(`API Error: ${response.status}`)
    }

    return data
  } catch (error) {
    console.error("Request failed:", error)
    throw error
  }
}
```

---

## Rate Limiting

**Current Status**: No rate limiting is currently enforced on the API.

### Client-Side Best Practices

While there's no server-side rate limiting, clients should implement reasonable request throttling:

- **Avoid polling** - Use WebSocket channels for real-time updates instead
- **Debounce user input** - Don't send requests on every keystroke
- **Batch operations** when possible
- **Cache responses** when appropriate
- **Implement exponential backoff** for retries

### Future Considerations

Rate limiting may be added in future versions. Recommended limits:

- **Authentication endpoints**: 5 requests per minute per IP
- **Room operations**: 20 requests per minute per user
- **Game actions**: 60 requests per minute per user

Clients should be designed to handle `429 Too Many Requests` responses gracefully.

---

## Support

### Getting Help

If you need assistance with the Pidro Server API:

#### Documentation

- Review this API documentation thoroughly
- Check the [interactive Swagger UI](http://localhost:4000/api/swagger) for endpoint details
- Consult the [Redoc reference](http://localhost:4000/api/redoc) for schemas
- Read module documentation: `mix docs` and open `doc/index.html`

#### Common Issues

1. **Connection Refused**
   - Ensure server is running: `mix phx.server`
   - Check the port (default: 4000)
   - Verify firewall settings

2. **401 Unauthorized**
   - Check token is included: `Authorization: Bearer <token>`
   - Verify token hasn't expired
   - Ensure token is valid (not corrupted)

3. **WebSocket Connection Failed**
   - Verify WebSocket URL: `ws://localhost:4000/socket/websocket`
   - Check token is in connection params
   - Ensure Phoenix channels are enabled

4. **Room Not Found**
   - Verify room code is correct (case-sensitive)
   - Check room hasn't been closed
   - Ensure room exists: `GET /api/v1/rooms/:code`

#### Development Resources

- **Phoenix Framework**: https://phoenixframework.org
- **Phoenix Channels Guide**: https://hexdocs.pm/phoenix/channels.html
- **OpenAPI Specification**: https://spec.openapis.org/oas/latest.html
- **Elixir Documentation**: https://elixir-lang.org/docs.html

#### Reporting Issues

For bugs or feature requests:
1. Check existing issues in the repository
2. Provide detailed reproduction steps
3. Include API request/response examples
4. Share relevant logs from `iex` or server output

#### Community

- **Phoenix Forum**: https://elixirforum.com/c/phoenix-forum
- **Elixir Slack**: https://elixir-slackin.herokuapp.com
- **Stack Overflow**: Tag questions with `phoenix-framework` and `elixir`

---

## Admin Panel

The Pidro Server includes a LiveView-based admin panel for monitoring and management.

**Access**: `http://localhost:4000/admin`

**Authentication**: Basic auth (configure in `config/` files)
- Default username: `admin`
- Default password: `secret` (change in production!)

**Features**:
- **Lobby Monitor** (`/admin/lobby`) - View all active rooms and players
- **Game Monitor** (`/admin/games/:code`) - Watch live game state
- **Statistics** (`/admin/stats`) - View server-wide statistics

**Note**: The admin panel is protected and should use strong credentials in production.

---

## Appendix

### API Versioning

The current API is versioned as `v1` in the URL path: `/api/v1/...`

Future versions will be released as `/api/v2/` while maintaining backward compatibility for v1.

### Data Formats

- **Dates/Times**: ISO 8601 format in UTC (e.g., `2025-11-02T10:30:00Z`)
- **Request Bodies**: JSON with `Content-Type: application/json`
- **Response Bodies**: JSON with `Content-Type: application/json; charset=utf-8`
- **Card Representation**: Tuples of `[rank, suit]` where rank is 2-14 (Jack=11, Queen=12, King=13, Ace=14)
- **Positions**: `:north`, `:east`, `:south`, `:west`
- **Teams**: `:north_south`, `:east_west`

### Room Codes

- **Format**: 4 alphanumeric characters (e.g., `A1B2`)
- **Case**: Case-insensitive in API calls, normalized to uppercase internally
- **Uniqueness**: Each active room has a unique code
- **Lifetime**: Codes are reused after rooms close

### Player Limits

- **Room Capacity**: Exactly 4 players required to start
- **Teams**: 2 teams of 2 players (North-South vs East-West)
- **Positions**: Assigned in join order (North → East → South → West)

---

**Happy coding!** If you build something cool with the Pidro API, we'd love to hear about it.
