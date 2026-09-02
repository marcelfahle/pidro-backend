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
- **Token Authentication**: Signed, opaque `Phoenix.Token` bearer tokens with server-side revocation
- **Room System**: Create and join game rooms with up to 4 players
- **Real-time Gameplay**: WebSocket channels for live game updates
- **Statistics Tracking**: Track wins, losses, and game performance
- **Dev Dashboard**: LiveView-powered monitoring tools (development only)
- **OpenAPI Documentation**: Interactive API explorer and reference

### Technology Stack

- **Framework**: Phoenix 1.8 (Elixir)
- **Database**: PostgreSQL
- **Real-time**: Phoenix Channels (WebSockets)
- **Authentication**: `Phoenix.Token` (`PidroServer.Accounts.Token`), not JWT
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

The Pidro API uses signed, opaque `Phoenix.Token` bearer tokens for authentication (see
[Token Lifetime and Revocation](#token-lifetime-and-revocation)). They are **not** JWTs: clients
must treat the token as an opaque string and never parse or validate it locally. Most endpoints
require a valid token.

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

The `username` field accepts **either the account's username or its email address**. An
identifier containing `@` is matched against the email case-insensitively; anything else is
matched against the username exactly. Both paths share the same constant-time failure, so a
wrong identifier and a wrong password are indistinguishable. A guest account has no password
and therefore never authenticates here.

**Request Body**:
```json
{
  "username": "john_doe",
  "password": "secure_password_123"
}
```

or

```json
{
  "username": "john@example.com",
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

Include the token in the `Authorization` header for authenticated requests:

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

### Create a Guest Account

**Endpoint**: `POST /api/v1/auth/guest`
**Authentication**: None (the invite code is the ticket)

A friend who taps an invite link can sit down without registering. The server creates a real
`users` row with `guest: true` and a generated `guest_XXXXXXXX` username, so every game, rating
and achievement the guest earns survives the later upgrade.

**Request Body**:
```json
{
  "display_name": "Anna",
  "invite_code": "7KQ4-M2XB",
  "install_id": "device-1",
  "platform": "ios"
}
```

- `display_name` (required) - the name shown at the table. NFKC-normalized and trimmed, 2-20
  graphemes, no control or format characters, and it must not look like the name of a player
  **connected** at the invite's table (compared casefolded with diacritics and non-alphanumerics
  removed). Held seats are excluded, so a guest who lost her session can return under her own
  name. A violation answers `422` with the field code `display_name`.
- `invite_code` (required) - dashes and lower case are accepted; `I`/`L` read as `1` and `O` as `0`.
- `install_id` (optional, ≤ 64 characters) - an opaque per-install id that keys the
  `guest_create_install` rate-limit bucket. It is **never written to request logs** and never
  appears in a response.
- `platform` (optional) - `ios`, `android` or `web`; recorded on the invite's `guest_created`
  funnel event. An unknown value answers `422`.

**Response** (201 Created):
```json
{
  "data": {
    "user": {
      "id": "0f2b8c1e-...",
      "username": "guest_7Q4M2XBA",
      "email": null,
      "display_name": "Anna",
      "guest": true,
      "inserted_at": "2026-09-02T10:30:00.000000Z",
      "updated_at": "2026-09-02T10:30:00.000000Z"
    },
    "token": "SFMyNTY...",
    "state": "open"
  }
}
```

`state` is the invite's derived state (see [Invites](#invites-invites)), so the client knows
whether to redeem immediately (`open`) or show the table's situation first (`full`, `locked`,
`started`, `closed`, `moved`). Only `revoked` and `expired` refuse the guest: they answer `410`
with `INVITE_REVOKED` / `INVITE_EXPIRED`. An unknown invite code answers `404`.

Limited at policies `guest_create` and `guest_create_daily` (per client IP) and
`guest_create_install` (per `install_id`; skipped when the param is absent or longer than 64
characters).

### Upgrade a Guest to a Registered Account

**Endpoint**: `POST /api/v1/auth/upgrade`
**Authentication**: Required (a guest token)

Sets email, password and an optional username on the **same** user row, so nothing is migrated
and nothing is lost. Every token minted before the upgrade is revoked (`token_version` is
incremented); the response carries a fresh one. Open WebSocket connections are **not**
disconnected.

**Request Body**:
```json
{
  "email": "anna@example.com",
  "password": "secure_password_123",
  "username": "anna"
}
```

`username` is optional; without it the generated `guest_…` username is kept. The fields may also
be nested under a `user` key.

**Response** (200 OK):
```json
{
  "data": {
    "user": {
      "id": "0f2b8c1e-...",
      "username": "anna",
      "email": "anna@example.com",
      "display_name": "Anna",
      "guest": false,
      "inserted_at": "2026-09-02T10:30:00.000000Z",
      "updated_at": "2026-09-02T11:05:00.000000Z"
    },
    "token": "SFMyNTY..."
  }
}
```

**Errors**: a caller who is already registered answers `409 NOT_A_GUEST`; an email already in use
(case-insensitively) `409 EMAIL_TAKEN`; a username already in use `409 USERNAME_TAKEN`; invalid
fields `422`. Limited at policy `auth_upgrade` (per client IP, the same size as `register`, so
upgrade is not an email-existence oracle).

### Delete Your Account

**Endpoint**: `DELETE /api/v1/auth/me`
**Authentication**: Required

Leaves the caller's room, revokes every invite they host and clears those invites' labels, then
deletes their `player_profiles`, `player_achievements`, `invite_redemptions` and `invite_events`
rows together with the `users` row in one transaction, and finally broadcasts the socket
disconnect. `game_stats` and `abandonment_events` rows are untouched: they keep the bare user id,
which afterwards resolves to nobody (a seat's `username` and `display_name` render as `null`).

**Response**: `204 No Content` with an empty body. The token is dead immediately; every
subsequent request answers `401`.

The same recipe backs the idle-guest reaper, which deletes guest accounts that have not been seen
for 30 days (see [`thoughts/DEPLOYMENT.md`](DEPLOYMENT.md) for `GUEST_REAPER_*`).

### Token Lifetime and Revocation

Tokens are signed with `Phoenix.Token` (`PidroServer.Accounts.Token`). The signed payload is
`%{id: user_id, v: token_version}` and a token expires 30 days after it was minted. On every
authenticated request and every WebSocket connect, `v` is compared with `users.token_version`
(`PidroServer.Accounts.Auth.fetch_user_for_token/1`); a mismatch means the token was revoked and
answers `401 Unauthorized` (REST) or refuses the socket connect.

- **Password reset** bumps `token_version` in the same transaction as the password change, so
  every token minted before the reset stops working. The response to
  `POST /api/v1/auth/password-reset/confirm` carries a fresh token minted after the bump.
- After the bump the server broadcasts `"disconnect"` on `user_socket:<user_id>`, which closes
  the user's live WebSocket connections. A client still holding the old token fails every
  reconnect until it logs in again, so clear the cached token on a 401 or a socket `:error`.
- **Legacy tokens** minted before the versioned payload carry a bare user id. They keep
  verifying as version 0 until 30 days after the production deploy of the versioned payload,
  and not before 2026-10-02; after that they are rejected and the user logs in again.
- The payload change is roll-forward only: a release older than the versioned payload cannot
  verify these tokens. The emergency rollback is rotating the signing salt in
  `PidroServer.Accounts.Token`, which invalidates every token at once.

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
- `POST /auth/login` - Login and get token (the `username` field accepts a username **or** an email)
- `POST /auth/guest` - Create a guest account from an invite code
- `POST /auth/upgrade` - Turn the calling guest into a registered account (requires auth)
- `GET /auth/me` - Get current user (requires auth)
- `DELETE /auth/me` - Delete the calling account (requires auth)

#### Users (`/users`)
- `GET /users/me/stats` - Get current user's game statistics (requires auth)

#### Invites (`/invites`)
- `POST /rooms/:code/invites` - Mint or update the room's invite link (host only, requires auth)
- `GET /invites/:code` - Public preview of an invite (no auth)
- `POST /invites/:code/redeem` - Claim a seat at the invite's table (requires auth)
- `DELETE /invites/:code` - Revoke an invite (host only, requires auth)
- `POST /invites/:code/regenerate` - Revoke and mint a replacement (host only, requires auth)

#### Rooms (`/rooms`)
- `GET /rooms` - List all available rooms
- `GET /rooms?filter=waiting` - List rooms waiting for players
- `GET /rooms/:code` - Get specific room details
- `GET /lobby` - Get categorized lobby data (requires auth)
- `GET /rooms/:code/state` - Get current game state for a room (requires auth)
- `POST /rooms` - Create a new room (requires auth)
- `POST /rooms/:code/join` - Join a room with optional seat selection (requires auth)
- `DELETE /rooms/:code/leave` - Leave a room (requires auth)
- `POST /rooms/:code/watch` - Join as spectator (requires auth)
- `DELETE /rooms/:code/unwatch` - Leave spectating (requires auth)
- `POST /rooms/:code/open-seat` - Open a bot seat for substitute (requires auth)
- `POST /rooms/:code/close-seat` - Close a vacant seat back to bot (requires auth)
- `POST /rooms/:code/seat` - Move a player to a vacant seat in a waiting room (requires auth)
- `POST /rooms/:code/lock` - Lock or unlock the table (host only, requires auth)
- `POST /rooms/:code/kick` - Kick a seated player (host only, requires auth)

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
      "spectator_ids": [],
      "status": "waiting",
      "max_players": 4,
      "max_spectators": 10,
      "created_at": "2025-11-02T10:30:00Z",
      "seats": {
        "west": {
          "position": "west",
          "occupant_type": "human",
          "user_id": "user123",
          "status": "connected",
          "is_owner": true,
          "substitute": false,
          "has_reservation": false,
          "joined_at": "2025-11-02T10:30:00Z"
        }
      }
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

### Invites (`/invites`)

An invite is a durable row, separate from the 4-character room code: **one link per table**. The
host mints it, shares it, and friends land on a public preview before they sit down. The link is
`<INVITE_LINK_BASE_URL>/<CODE>` (production default `https://pidro.online/j`).

**Codes** are 8 characters from the Crockford Base32 alphabet, drawn from
`:crypto.strong_rand_bytes/1` and stored upper-cased. Lookups are forgiving: dashes are stripped,
the code is upper-cased, and `I`/`L` are read as `1` and `O` as `0`. So `7kq4-m2xb`, `7KQ4M2XB`
and `7KQ4-M2XB` all reach the same invite. Invites expire **24 hours** after they are minted.

**State** is derived at read time, never stored, in this order:

| State | Meaning |
|-------|---------|
| `revoked` | The host revoked it (`DELETE` or `regenerate`) |
| `moved` | It was superseded and the successor's table is still waiting; `next_code` carries the new code |
| `expired` | Past `expires_at` |
| `closed` | No live room with this invite's room id (the table is gone, or its code was recycled by another room) |
| `started` | The room is `playing` or `finished` |
| `locked` | The host locked the table |
| `full` | All four positions are taken |
| `open` | Anyone with the link can sit down |

#### Mint or Update the Room's Invite

**Endpoint**: `POST /api/v1/rooms/:code/invites`
**Authentication**: Required (the room's host)

The room must be `waiting` or `ready`. A **second mint on the same room updates the active invite
in place**: the same code comes back with the new `seat_hint` and `label`, and the status is `200`
instead of `201`.

**Request Body** (all fields optional):
```json
{
  "seat_hint": "partner",
  "label": "Anna",
  "supersedes": "7KQ4-M2XB"
}
```

- `seat_hint` - `north`, `east`, `south`, `west`, `north_south`, `east_west` or `partner`.
  `partner` resolves against the host's current seat at redeem time.
- `label` - free text, at most 40 characters; a private note for the host ("Anna"). It is deleted
  when the host deletes their account.
- `supersedes` - the code of an earlier invite the **caller hosted**. That invite starts reading
  `moved` with `next_code` pointing here, which is how "play again" forwards last night's link to
  tonight's table.

**Response** (201 Created, or 200 OK when the active invite was updated):
```json
{
  "data": {
    "invite": {
      "code": "7KQ4M2XB",
      "url": "https://pidro.online/j/7KQ4M2XB",
      "share_text": "Come play Pidro with me 🃏 https://pidro.online/j/7KQ4M2XB — code 7KQ4-M2XB",
      "seat_hint": "partner",
      "label": "Anna",
      "expires_at": "2026-09-03T10:30:00.000000Z",
      "state": "open"
    }
  }
}
```

The room code never appears in an invite response.

**Errors**: a non-host answers `403 NOT_OWNER`; a room that is not waiting `409 ROOM_NOT_WAITING`;
more than 20 invites for one room `409 INVITE_LIMIT`; an unknown room `404`; an invalid
`seat_hint` or an over-long `label` `422`. Limited at policy `invite_mint` (per user).

#### Preview an Invite

**Endpoint**: `GET /api/v1/invites/:code`
**Authentication**: None

The landing page's data. It deliberately **never contains the room code**, so a scraped link
cannot be turned into a room join.

**Response** (200 OK):
```json
{
  "data": {
    "invite": {
      "code": "7KQ4M2XB",
      "state": "open",
      "host": "Marcel",
      "seats_taken": 1,
      "seats_total": 4,
      "seat_hint": "partner",
      "label": "Anna",
      "expires_at": "2026-09-03T10:30:00.000000Z"
    }
  }
}
```

- `host` is the host's `display_name`, falling back to their username, and `null` once the
  account is gone.
- `seats_taken` is `0` when the table is closed.
- `next_code` is present **only** when `state` is `moved`.

An unknown code answers `404`. Limited at policy `invite_preview` (per client IP).

#### Redeem an Invite

**Endpoint**: `POST /api/v1/invites/:code/redeem`
**Authentication**: Required (a registered user or a guest created via `POST /auth/guest`)

**Request Body** (all fields optional):
```json
{
  "position": "south",
  "platform": "ios",
  "source": "imessage"
}
```

- Without `position` the server tries the invite's seat hint and falls back to any open seat in
  N/E/S/W order. `hint_honored` reports whether the hint was met (it is `true` when there was no
  hint).
- With `position` the seat is taken exactly or the request fails.
- `platform` and `source` are recorded on the redemption row for the funnel; they never affect
  seating.

**Response** (200 OK):
```json
{
  "data": {
    "room": { "code": "A3F9", "locked": false, "seats": { "...": {} } },
    "position": "south",
    "hint_honored": true
  }
}
```

`room` is the full room object (see [Room Object Schema](WEBSOCKET_API.md#room-object-schema)),
so this single call is enough to render the table and then join `game:<room_code>`.

A caller **already seated at this table** gets `200` with their current seat and no second
redemption is recorded, so a double tap on the link is harmless.

**Errors**:

| Status | Code | When |
|--------|------|------|
| `403` | `KICKED` | The host kicked this account from the room |
| `404` | `NOT_FOUND` | Unknown invite code |
| `409` | `SEAT_TAKEN` | An explicit `position` is occupied; the body carries `next_open` |
| `409` | `TABLE_FULL` | All four seats are taken |
| `410` | `TABLE_STARTED` | The game already started |
| `410` | `TABLE_CLOSED` | The table no longer exists |
| `410` | `INVITE_EXPIRED` | Past `expires_at` |
| `410` | `INVITE_REVOKED` | The host revoked the invite |
| `410` | `INVITE_MOVED` | Superseded; the body carries `next_code` |
| `422` | `INVALID_POSITION` | `position` is not one of `north`/`east`/`south`/`west` |
| `422` | `ALREADY_IN_ROOM` | The caller is connected in another room |
| `423` | `TABLE_LOCKED` | The host locked the table |

A caller whose seat in another room is only **held** (or bot-substituted) is evicted from that
room automatically and seated here; only a live connection elsewhere answers `ALREADY_IN_ROOM`.

Limited at policy `invite_redeem` (per user).

#### Revoke an Invite

**Endpoint**: `DELETE /api/v1/invites/:code`
**Authentication**: Required (the invite's host)

Marks the invite revoked. The row is **never deleted** and the code is never reissued, so an old
link keeps answering `410 INVITE_REVOKED` instead of falling through to a stranger's table.

**Response**: `204 No Content`. A non-host answers `403 NOT_OWNER`; an unknown code `404`.

#### Regenerate an Invite

**Endpoint**: `POST /api/v1/invites/:code/regenerate`
**Authentication**: Required (the invite's host)

Revokes the invite and mints a replacement for the same table with the same seat hint and label.
This is the answer to a leaked link: the old code reads `revoked`, **not** `moved`, so it does not
forward anybody to the new one.

**Response** (201 Created): the same shape as a mint, carrying the new code.

Limited at policy `invite_mint` (per user).

### Host Controls in a Waiting Room

The three endpoints below all require authentication, work only while the room is `waiting` or
`ready` (`409 ROOM_NOT_WAITING` otherwise), and answer `200` with the full room object.

#### Move a Seat

**Endpoint**: `POST /api/v1/rooms/:code/seat`

```json
{ "position": "west", "user_id": "0f2b8c1e-..." }
```

The host may move any seated player; a seated non-host may move **only themselves**, which they do
by omitting `user_id`. The target position must be vacant.

**Response** (200 OK):
```json
{
  "data": {
    "room": {
      "code": "A3F9",
      "locked": false,
      "positions": { "north": "…host id…", "east": null, "south": null, "west": "0f2b8c1e-..." },
      "seats": {
        "west": { "position": "west", "user_id": "0f2b8c1e-...", "username": "guest_7Q4M2XBA", "display_name": "Ben", "status": "connected" }
      }
    }
  }
}
```

**Errors**: a non-host moving somebody else `403 NOT_OWNER`; an occupied target `422 SEAT_TAKEN`
(the same 422 contract as `POST /rooms/:code/join`); an unknown position `422 INVALID_POSITION`.

#### Lock or Unlock the Table

**Endpoint**: `POST /api/v1/rooms/:code/lock`

```json
{ "locked": true }
```

A locked table refuses `POST /rooms/:code/join` and invite redemptions with `423 TABLE_LOCKED`.
Reclaiming a **held** seat still works, so locking never strands a player who stepped out. The
room object carries the flag as `locked`.

**Errors**: a non-host `403 NOT_OWNER`; a non-boolean `locked` `422`.

#### Kick a Player

**Endpoint**: `POST /api/v1/rooms/:code/kick`

```json
{ "position": "east" }
```

Vacates the seat, adds the account to the room's kick list, and closes that player's game channel
with a `kicked` event. They cannot join, redeem or substitute into this room again: every later
attempt answers `403 KICKED`. The kick list is **per account**, so a stranger who still holds the
link can come back as a fresh guest — the host's answer to that is
`POST /invites/:code/regenerate`.

**Errors**: a non-host `403 NOT_OWNER`; the host's own seat, a bot seat or a vacant seat
`422 SEAT_NOT_KICKABLE`.

---

## WebSocket API

For real-time gameplay, the Pidro Server uses Phoenix Channels over WebSockets.

### Connection

Connect to the WebSocket endpoint:

```
ws://localhost:4000/socket/websocket
```

### Authentication

Authenticate your socket connection by including the token in the connection params:

```javascript
import { Socket } from "phoenix"

const socket = new Socket("ws://localhost:4000/socket/websocket", {
  params: { token: yourToken }
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
  .receive("ok", (response) => {
    // response contains:
    // {
    //   role: "player",        // "player" or "spectator"
    //   reconnected: false,     // true if this was a reconnection
    //   legal_actions: [],      // available actions for this player
    //   state: { /* ... */ },   // game state (if game has started)
    //   position: "north"       // player's position (players only)
    // }
    console.log("Joined game as", response.role)
    console.log("Position:", response.position)
    console.log("Game state:", response.state)
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
| `invite_redeemed` | `{ position, user_id, display_name }` | Somebody claimed a seat through the invite link |
| `seat_moved` | `{ user_id, from, to }` | The host (or the player themselves) moved a seat |
| `player_kicked` | `{ position, user_id }` | The host kicked a seat; sent to everybody else |
| `kicked` | `{ reason: "kicked" }` | Sent to the kicked player only, then the channel closes |
| `presence_state` | Presence info | Who's currently online |
| `presence_diff` | Presence changes | Online status changes |

The full event list, including the waiting-room held-seat semantics of `player_reconnecting`,
lives in [`thoughts/WEBSOCKET_API.md`](WEBSOCKET_API.md).

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
  "trump_suit": null,           // null during bidding, e.g. "hearts" after declaration
  "highest_bid": {              // null if no bids yet
    "position": "north",
    "amount": 8
  },
  "bidding_team": null,         // e.g. "north_south" after bid is won
  "players": {
    "north": {
      "position": "north",
      "team": "north_south",
      "hand": [{"rank": 14, "suit": "hearts"}, {"rank": 13, "suit": "hearts"}],
      "tricks_won": 0
    }
    // ... other players
  },
  "bids": [
    {"position": "west", "amount": "pass"},
    {"position": "north", "amount": 8}
  ],
  "tricks": [],
  "hand_points": {
    "north_south": 0,
    "east_west": 0
  },
  "scores": {
    "north_south": 0,
    "east_west": 0
  },
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

2. **Receive the token** from the registration response

3. **Connect to WebSocket** with token:
   ```javascript
   socket = new Socket("ws://localhost:4000/socket/websocket", {
     params: { token: token }
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

1. **Login** and **browse rooms**:
   ```bash
   GET /api/v1/rooms
   ```

2. **View room details**:
   ```bash
   GET /api/v1/rooms/A1B2
   ```

3. **Get current game state** (requires auth):
   ```bash
   GET /api/v1/rooms/A1B2/state
   Authorization: Bearer <token>
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
| **403 Forbidden** | Not allowed for this caller | Not the host of a room or invite (`NOT_OWNER`), kicked from the table (`KICKED`) |
| **404 Not Found** | Resource doesn't exist | Room not found, user not found, unknown invite code |
| **409 Conflict** | The request is valid but the current state refuses it | Seat taken on redeem, table full, room no longer waiting, invite limit, caller is not a guest, email or username already in use |
| **410 Gone** | The table or invite is permanently past accepting this request | Game started, table closed, invite expired, revoked or moved |
| **422 Unprocessable Entity** | Validation failed | Missing or malformed fields, invalid email, room full on direct room join |
| **423 Locked** | The host locked the table | `POST /rooms/:code/join` and invite redeem while `locked` |
| **429 Too Many Requests** | Rate limit exceeded | Too many logins, registrations, password resets, room creations or lookups, room joins, invite mints, previews or redeems, guest creations or upgrades from one client; see [Rate Limiting](#rate-limiting) |
| 503 | Service Unavailable | No free room code could be allocated (`ROOM_CODE_EXHAUSTED`); retry shortly |
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

#### Rate Limit Errors

`429 Too Many Requests` with a `Retry-After` header in whole seconds:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 42
Content-Type: application/json; charset=utf-8
```

```json
{
  "errors": [
    {
      "code": "RATE_LIMITED",
      "title": "Too Many Requests",
      "detail": "Rate limit exceeded, retry after 42 seconds"
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

#### Invite, Seat and Account Errors

These arrive from the invite endpoints, the host controls and the guest/upgrade routes. Every one
uses the standard envelope; two of them carry an extra field the client should act on.

**409 Conflict**

| Code | Field | Meaning |
|------|-------|---------|
| `SEAT_TAKEN` | `next_open` | The explicitly requested seat is occupied. `next_open` lists the still-open positions in N/E/S/W order, so the client can offer one immediately. Only `POST /invites/:code/redeem` answers 409 here; `POST /rooms/:code/join` keeps its historical `422 SEAT_TAKEN` |
| `TABLE_FULL` | - | All four positions are taken |
| `ROOM_NOT_WAITING` | - | The room is no longer `waiting`/`ready`, so it cannot be minted for, locked, kicked in or reseated |
| `INVITE_LIMIT` | - | This room has already minted 20 invites |
| `NOT_A_GUEST` | - | `POST /auth/upgrade` was called with a registered account's token |
| `EMAIL_TAKEN` | - | Another account already uses that email (compared case-insensitively) |
| `USERNAME_TAKEN` | - | Another account already uses that username |

```json
{
  "errors": [
    {
      "code": "SEAT_TAKEN",
      "title": "Seat taken",
      "detail": "The requested seat is already occupied",
      "next_open": ["east", "west"]
    }
  ]
}
```

**410 Gone**

| Code | Field | Meaning |
|------|-------|---------|
| `TABLE_STARTED` | - | The game at this table has already started |
| `TABLE_CLOSED` | - | The table this invite opened no longer exists |
| `INVITE_EXPIRED` | - | The invite is past its 24-hour lifetime |
| `INVITE_REVOKED` | - | The host revoked the invite (or regenerated it) |
| `INVITE_MOVED` | `next_code` | The host is at a new table; redeem `next_code` instead |

```json
{
  "errors": [
    {
      "code": "INVITE_MOVED",
      "title": "Invite moved",
      "detail": "The host is at a new table; use the next code",
      "next_code": "M2XB7KQ4"
    }
  ]
}
```

**423 Locked**

```json
{
  "errors": [
    {
      "code": "TABLE_LOCKED",
      "title": "Table locked",
      "detail": "The host has locked this table"
    }
  ]
}
```

**403 Forbidden**

```json
{
  "errors": [
    {
      "code": "KICKED",
      "title": "Kicked",
      "detail": "The host removed you from this table"
    }
  ]
}
```

`KICKED` is permanent for that account and that room: joining, redeeming and substituting all
answer it. `NOT_OWNER` (also 403) means the caller does not host the room or the invite.

**422 Unprocessable Entity** adds `SEAT_NOT_KICKABLE` (the host's own seat, a bot seat or a vacant
seat) and `INVALID_POSITION` (a position outside `north`/`east`/`south`/`west`).

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

`PidroServerWeb.Plugs.RateLimit` throttles the routes below, backed by a node-local Hammer ETS
counter (`PidroServer.RateLimit`). Routes not listed are not limited.

### Policies

Production defaults from `config/config.exs`. `config/dev.exs` restates every limit at 10x for
the frontend end-to-end harness; `config/test.exs` sets 1,000,000.

| Policy | Route | Limit (production) | Keyed by |
|--------|-------|--------------------|----------|
| `login` | `POST /api/v1/auth/login` | 10 per 60 s | client IP |
| `register` | `POST /api/v1/auth/register` | 10 per 600 s | client IP |
| `password_reset` | `POST /api/v1/auth/password-reset` | 3 per 900 s | client IP |
| `password_reset_identifier` | `POST /api/v1/auth/password-reset` | 3 per 3600 s | SHA-256 of the trimmed, lower-cased `identifier` (or `email`) param |
| `password_reset_confirm` | `POST /api/v1/auth/password-reset/confirm` | 5 per 900 s | client IP |
| `room_create` | `POST /api/v1/rooms` | 10 per 60 s | authenticated user |
| `room_lookup` | `GET /api/v1/rooms/:code` | 120 per 60 s | client IP |
| `room_join` | `POST /api/v1/rooms/:code/join` | 30 per 60 s | authenticated user |
| `invite_mint` | `POST /api/v1/rooms/:code/invites` and `POST /api/v1/invites/:code/regenerate` | 10 per 60 s | authenticated user |
| `invite_preview` | `GET /api/v1/invites/:code` | 60 per 60 s | client IP |
| `invite_redeem` | `POST /api/v1/invites/:code/redeem` | 10 per 60 s | authenticated user |
| `guest_create` | `POST /api/v1/auth/guest` | 10 per 3600 s | client IP |
| `guest_create_daily` | `POST /api/v1/auth/guest` | 40 per 86400 s | client IP |
| `guest_create_install` | `POST /api/v1/auth/guest` | 3 per 3600 s | SHA-256 of the trimmed `install_id` param (case preserved: it is an opaque device id) |
| `auth_upgrade` | `POST /api/v1/auth/upgrade` | 10 per 600 s | client IP |

- A route may carry several policies (`/auth/password-reset` carries two, `/auth/guest` carries
  three); each counts in its own bucket and the first one over its limit answers.
- **Client IP** is the address kamal-proxy forwards in `X-Forwarded-For`
  (`PidroServerWeb.Plugs.TrustedProxy`). An IPv4-mapped IPv6 peer collapses to IPv4 and a native
  IPv6 peer keys on its /64 prefix, so one household shares a bucket.
- A `:user` policy with no authenticated user falls back to the IP key.
- A missing or empty `identifier`/`email` param skips only the identifier policy.
- A missing `install_id`, or one longer than 64 characters, skips only the `guest_create_install`
  policy; the two IP-keyed guest policies still apply. The `guest_create` sizes assume a QR party
  behind one NAT, which is the designed case rather than an abuse signal.
- `auth_upgrade` is deliberately the same size as `register` so upgrade cannot be used as an
  email-existence oracle.

### 429 Contract

The first denied policy halts the request with `429 Too Many Requests`, a `Retry-After` header
(whole seconds until the window resets, rounded up, at least 1) and the standard error body:

```json
{
  "errors": [
    {
      "code": "RATE_LIMITED",
      "title": "Too Many Requests",
      "detail": "Rate limit exceeded, retry after 42 seconds"
    }
  ]
}
```

Wait for `Retry-After` seconds before retrying; do not retry in a tight loop.

### Semantics and Operation

- Limits are **per node** and **per fixed window**: counters live in ETS on the node that served
  the request and reset when it restarts, and up to twice the limit can pass across a window
  boundary.
- If the limiter backend itself fails, the request is allowed and an error is logged; the API
  never goes down because of the limiter.
- Every 429 is logged at `info` with its bucket key.
- Operators tune limits at runtime with `RATE_LIMIT_<POLICY>_LIMIT` and
  `RATE_LIMIT_<POLICY>_SCALE_MS` (for example `RATE_LIMIT_LOGIN_LIMIT=20`), where `<POLICY>` is
  the upper-cased policy name. Limits are numeric only; there is no off switch. See
  `thoughts/DEPLOYMENT.md` and `docs/deployment/kamal_hetzner.md`.

### Client-Side Best Practices

- **Avoid polling** - Use WebSocket channels for real-time updates instead
- **Debounce user input** - Don't send requests on every keystroke
- **Cache responses** when appropriate
- **Honour `Retry-After`** and use exponential backoff for other retries

---

## Support

### Getting Help

If you need assistance with the Pidro Server API:

#### Documentation

- Review this API documentation thoroughly
- Check the [interactive Swagger UI](http://localhost:4000/api/swagger) for endpoint details
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

## Dev Dashboard (Development Only)

In development mode, the Pidro Server includes monitoring tools:

**Access**: `http://localhost:4000/dev`

**Features**:
- **Game List** (`/dev/games`) - View all active rooms and games
- **Game Detail** (`/dev/games/:code`) - Watch live game state
- **Analytics** (`/dev/analytics`) - View server-wide analytics
- **LiveDashboard** (`/dev/dashboard`) - Phoenix telemetry and metrics

**Note**: These routes are only available in development mode.

---

## Appendix

### API Versioning

The current API is versioned as `v1` in the URL path: `/api/v1/...`

Future versions will be released as `/api/v2/` while maintaining backward compatibility for v1.

### Data Formats

- **Dates/Times**: ISO 8601 format in UTC (e.g., `2025-11-02T10:30:00Z`)
- **Request Bodies**: JSON with `Content-Type: application/json`
- **Response Bodies**: JSON with `Content-Type: application/json; charset=utf-8`
- **Card Representation**: `{rank: number, suit: string}` where rank is 2-14 (Jack=11, Queen=12, King=13, Ace=14)
- **Positions**: `"north"`, `"east"`, `"south"`, `"west"` (strings in JSON)
- **Teams**: `"north_south"`, `"east_west"` (strings in JSON)

### Game State Serialization

All game state sent through the API or WebSocket channels is serialized by `PidroServerWeb.Serializers.GameStateSerializer`. This converts internal Elixir structs (e.g., `Pidro.Core.Types.GameState`) into JSON-safe maps.

**Card format**:
```json
{"rank": 14, "suit": "spades"}
```

**Game state fields** (example):
```json
{
  "phase": "playing",
  "current_turn": "north",
  "trump_suit": "hearts",
  "players": {
    "north": {"position": "north", "team": "north_south", "hand": [...], "tricks_won": 2},
    ...
  },
  "current_trick": {"number": 3, "leader": "south", "plays": [...], "winner": null},
  "cumulative_scores": {"north_south": 24, "east_west": 18}
}
```

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
