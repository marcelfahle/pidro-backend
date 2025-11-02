# Pidro WebSocket API Documentation

This document provides a comprehensive guide to integrating with the Pidro game server's WebSocket API. The API uses Phoenix Channels to provide real-time communication for lobby updates and gameplay.

## Table of Contents

- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Connection Setup](#connection-setup)
  - [Authentication](#authentication)
- [Lobby Channel](#lobby-channel)
  - [Joining the Lobby](#joining-the-lobby)
  - [Lobby Events](#lobby-events)
  - [Presence Tracking](#presence-tracking)
- [Game Channel](#game-channel)
  - [Joining a Game](#joining-a-game)
  - [Game Actions](#game-actions)
  - [Game Events](#game-events)
  - [Game State](#game-state)
- [Error Handling](#error-handling)
- [Code Examples](#code-examples)
  - [JavaScript/TypeScript Client](#javascripttypescript-client)
  - [Complete Game Flow](#complete-game-flow)
- [Event Reference](#event-reference)

---

## Getting Started

### Prerequisites

- A valid JWT authentication token (obtained from the REST API after login/signup)
- Phoenix JavaScript client library (recommended) or any WebSocket client
- WebSocket endpoint: `ws://localhost:4000/socket` (development) or `wss://your-domain.com/socket` (production)

### Connection Setup

Install the Phoenix JavaScript client:

```bash
npm install phoenix
```

Create a socket connection:

```javascript
import { Socket } from "phoenix";

const token = "your_jwt_token"; // Obtained from login/signup
const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: token }
});

socket.connect();

socket.onOpen(() => console.log("Connected to server"));
socket.onError((error) => console.error("Connection error:", error));
socket.onClose(() => console.log("Disconnected from server"));
```

### Authentication

The WebSocket connection requires a valid JWT token passed in the connection parameters. The token:

- Must be provided when establishing the WebSocket connection
- Is verified using `PidroServer.Accounts.Token.verify/1`
- Has a 30-day expiration period
- Contains the user's ID for authorization

**Authentication Flow:**

1. User logs in via REST API (`POST /api/auth/login`)
2. Server returns a JWT token
3. Client includes token in WebSocket connection params
4. Server verifies token and associates user_id with the socket
5. Connection is established and channels can be joined

**Authentication Errors:**

- Missing token: Connection rejected with `:error`
- Invalid token: Connection rejected with `:error`
- Expired token: Connection rejected with `:error`

---

## Lobby Channel

The lobby channel provides real-time updates about available game rooms. All authenticated users can join the lobby to see room listings and presence information.

### Joining the Lobby

**Topic:** `"lobby"`

**Join Parameters:** None required (authentication is handled at the socket level)

**Join Response:**

```javascript
{
  rooms: [
    {
      code: "A3F9",
      host_id: "user123",
      player_count: 2,
      max_players: 4,
      status: "waiting", // "waiting" | "ready" | "playing" | "finished"
      created_at: "2025-01-15T10:30:00Z",
      metadata: {
        name: "Friday Night Game" // Optional room name
      }
    },
    // ... more rooms
  ]
}
```

**Example:**

```javascript
const lobbyChannel = socket.channel("lobby", {});

lobbyChannel
  .join()
  .receive("ok", (response) => {
    console.log("Joined lobby successfully");
    console.log("Available rooms:", response.rooms);
  })
  .receive("error", (error) => {
    console.error("Failed to join lobby:", error);
  });
```

### Lobby Events

The lobby channel broadcasts the following events to keep clients synchronized:

#### `lobby_update`

Sent when the room list changes (room created, updated, or closed).

**Payload:**

```javascript
{
  rooms: [/* array of room objects */]
}
```

**Example Handler:**

```javascript
lobbyChannel.on("lobby_update", (payload) => {
  console.log("Room list updated:", payload.rooms);
  updateRoomListUI(payload.rooms);
});
```

#### `presence_state`

Sent immediately after joining, contains the current presence information for all users in the lobby.

**Payload:**

```javascript
{
  "user123": {
    metas: [
      {
        online_at: 1705315800,
        phx_ref: "abc123"
      }
    ]
  },
  // ... other users
}
```

#### `presence_diff`

Sent when users join or leave the lobby.

**Payload:**

```javascript
{
  joins: {
    "user456": {
      metas: [
        {
          online_at: 1705315900,
          phx_ref: "def456"
        }
      ]
    }
  },
  leaves: {
    "user789": {
      metas: [
        {
          online_at: 1705315700,
          phx_ref: "ghi789"
        }
      ]
    }
  }
}
```

### Presence Tracking

The lobby uses Phoenix Presence to track which users are currently online. The presence system:

- Automatically tracks users when they join the lobby
- Broadcasts presence changes to all lobby members
- Automatically removes users when they disconnect
- Is conflict-free and works across distributed servers

**Using Phoenix Presence Client:**

```javascript
import { Presence } from "phoenix";

let presences = {};

lobbyChannel.on("presence_state", (state) => {
  presences = Presence.syncState(presences, state);
  renderPresence(presences);
});

lobbyChannel.on("presence_diff", (diff) => {
  presences = Presence.syncDiff(presences, diff);
  renderPresence(presences);
});

function renderPresence(presences) {
  const onlineUsers = Presence.list(presences, (id, { metas }) => {
    return {
      id: id,
      onlineAt: metas[0].online_at
    };
  });
  console.log("Online users:", onlineUsers);
}
```

---

## Game Channel

Game channels handle real-time gameplay for specific rooms. Each game has its own channel identified by the room code.

### Joining a Game

**Topic:** `"game:XXXX"` where `XXXX` is the room code (e.g., `"game:A3F9"`)

**Join Parameters:** None required (user must be a player in the room)

**Authorization Checks:**

1. User is authenticated
2. Room exists
3. User is a player in the room
4. Game process has been started

**Join Response:**

```javascript
{
  state: {
    // Full game state (see Game State section)
    phase: "bidding",
    current_player: "north",
    players: { /* ... */ },
    // ... more state
  },
  position: "north" // Player's position: "north" | "east" | "south" | "west"
}
```

**Position Assignment:**

Players are assigned positions based on the order they joined the room:
- 1st player: `north`
- 2nd player: `east`
- 3rd player: `south`
- 4th player: `west`

**Join Errors:**

- Room not found: `{reason: "Room not found"}`
- Game not started: `{reason: "Game not started yet"}`
- Not authorized: `{reason: "Not a player in this room"}`
- Unknown error: `{reason: "Failed to join game"}`

**Example:**

```javascript
const gameChannel = socket.channel("game:A3F9", {});

gameChannel
  .join()
  .receive("ok", (response) => {
    console.log("Joined game as:", response.position);
    console.log("Initial state:", response.state);
    initializeGameUI(response.state, response.position);
  })
  .receive("error", (error) => {
    console.error("Failed to join game:", error.reason);
  });
```

### Game Actions

Players send actions to the server to participate in the game. All actions are validated and must be made by the current player during the appropriate game phase.

#### `bid`

Make a bid or pass during the bidding phase.

**Payload (Bid):**

```javascript
{
  amount: 8  // Number between 5-14
}
```

**Payload (Pass):**

```javascript
{
  amount: "pass"
}
```

**Example:**

```javascript
// Make a bid
gameChannel
  .push("bid", { amount: 10 })
  .receive("ok", () => console.log("Bid accepted"))
  .receive("error", (error) => console.error("Bid rejected:", error.reason));

// Pass
gameChannel
  .push("bid", { amount: "pass" })
  .receive("ok", () => console.log("Passed"))
  .receive("error", (error) => console.error("Error:", error.reason));
```

**Validation:**
- Must be your turn
- Must be in bidding phase
- Bid must be higher than current bid
- Bid must be between 5-14

#### `declare_trump`

Declare the trump suit after winning the bid.

**Payload:**

```javascript
{
  suit: "hearts"  // "hearts" | "diamonds" | "clubs" | "spades"
}
```

**Example:**

```javascript
gameChannel
  .push("declare_trump", { suit: "hearts" })
  .receive("ok", () => console.log("Trump declared"))
  .receive("error", (error) => console.error("Error:", error.reason));
```

**Validation:**
- Must be the bid winner
- Must be in trump declaration phase

#### `play_card`

Play a card from your hand during the playing phase.

**Payload:**

```javascript
{
  card: {
    rank: 14,      // 2-14 (14 = Ace, 13 = King, etc.)
    suit: "spades" // "hearts" | "diamonds" | "clubs" | "spades"
  }
}
```

**Example:**

```javascript
gameChannel
  .push("play_card", {
    card: { rank: 14, suit: "spades" }
  })
  .receive("ok", () => console.log("Card played"))
  .receive("error", (error) => console.error("Invalid play:", error.reason));
```

**Validation:**
- Must be your turn
- Must have the card in your hand
- Must follow suit if possible (Pidro rules apply)

#### `ready`

Signal that you're ready to start (optional, for UI coordination).

**Payload:** None

**Example:**

```javascript
gameChannel
  .push("ready", {})
  .receive("ok", () => console.log("Ready status sent"));
```

### Game Events

The game channel broadcasts events to keep all players synchronized.

#### `game_state`

Sent whenever the game state changes (after each action).

**Payload:**

```javascript
{
  state: {
    // Complete game state (see Game State section)
  }
}
```

**Example Handler:**

```javascript
gameChannel.on("game_state", (payload) => {
  console.log("Game state updated:", payload.state);
  updateGameUI(payload.state);
});
```

#### `player_ready`

Sent when a player signals ready status.

**Payload:**

```javascript
{
  position: "north"  // Position of the ready player
}
```

**Example Handler:**

```javascript
gameChannel.on("player_ready", (payload) => {
  console.log(`Player ${payload.position} is ready`);
  markPlayerReady(payload.position);
});
```

#### `game_over`

Sent when the game ends.

**Payload:**

```javascript
{
  winner: "north_south",  // "north_south" | "east_west"
  scores: {
    north_south: 21,
    east_west: 14
  }
}
```

**Note:** The room is automatically closed 5 minutes after the game ends.

**Example Handler:**

```javascript
gameChannel.on("game_over", (payload) => {
  console.log("Game over!");
  console.log("Winner:", payload.winner);
  console.log("Final scores:", payload.scores);
  showGameOverScreen(payload);
});
```

#### `presence_state` and `presence_diff`

Same as lobby channel, but tracks players in the game. Includes player position in metadata.

**Payload (presence_state):**

```javascript
{
  "user123": {
    metas: [
      {
        online_at: 1705315800,
        position: "north",
        phx_ref: "abc123"
      }
    ]
  }
}
```

### Game State

The game state object contains all information about the current game:

```javascript
{
  // Current game phase
  phase: "bidding" | "trump_declaration" | "playing" | "game_over",

  // Current player's position (who can act)
  current_player: "north" | "east" | "south" | "west",

  // Player hands (only your hand is visible, others show card count)
  players: {
    north: {
      hand: [
        { rank: 14, suit: "spades" },
        { rank: 13, suit: "hearts" },
        // ... more cards
      ]
    },
    east: {
      card_count: 9  // For opponents
    },
    // ... south, west
  },

  // Bidding information
  bids: {
    north: 8,
    east: "pass",
    south: 10,
    west: "pass"
  },
  current_bid: 10,
  bid_winner: "south",
  bid_team: "north_south",  // Team that won the bid

  // Trump suit (after declaration)
  trump: "hearts" | "diamonds" | "clubs" | "spades" | null,

  // Current trick
  current_trick: [
    { player: "north", card: { rank: 14, suit: "spades" } },
    { player: "east", card: { rank: 10, suit: "spades" } }
  ],

  // Trick history
  tricks: [
    {
      cards: [
        { player: "north", card: { rank: 14, suit: "spades" } },
        { player: "east", card: { rank: 10, suit: "spades" } },
        { player: "south", card: { rank: 13, suit: "spades" } },
        { player: "west", card: { rank: 12, suit: "spades" } }
      ],
      winner: "north"
    }
  ],

  // Scores
  scores: {
    north_south: 15,
    east_west: 8
  },

  // Round information
  dealer: "north",
  round_number: 1
}
```

---

## Error Handling

### Connection Errors

**Invalid or Missing Token:**

```javascript
socket.onError((error) => {
  console.error("Socket error:", error);
  // Redirect to login or refresh token
});

socket.onClose(() => {
  console.log("Connection closed");
  // Attempt reconnection or show disconnected state
});
```

### Channel Join Errors

```javascript
channel
  .join()
  .receive("error", (error) => {
    switch (error.reason) {
      case "Room not found":
        // Room doesn't exist or was closed
        navigateToLobby();
        break;
      case "Game not started yet":
        // Players haven't all joined yet
        showWaitingScreen();
        break;
      case "Not a player in this room":
        // User is not authorized for this game
        navigateToLobby();
        break;
      default:
        showErrorMessage(error.reason);
    }
  });
```

### Action Errors

```javascript
gameChannel
  .push("play_card", { card: { rank: 14, suit: "spades" } })
  .receive("error", (error) => {
    console.error("Action failed:", error.reason);

    // Common error reasons:
    // - "not_your_turn"
    // - "invalid_play"
    // - "card_not_in_hand"
    // - "must_follow_suit"

    showErrorToast(error.reason);
  });
```

### Automatic Reconnection

```javascript
socket.onClose(() => {
  console.log("Connection lost, attempting to reconnect...");
  setTimeout(() => {
    socket.connect();
  }, 1000);
});
```

---

## Code Examples

### JavaScript/TypeScript Client

#### Complete Setup

```typescript
import { Socket, Channel, Presence } from "phoenix";

interface GameState {
  phase: "bidding" | "trump_declaration" | "playing" | "game_over";
  current_player: "north" | "east" | "south" | "west";
  players: Record<string, any>;
  bids?: Record<string, number | "pass">;
  current_bid?: number;
  trump?: "hearts" | "diamonds" | "clubs" | "spades" | null;
  current_trick: Array<any>;
  scores: Record<string, number>;
}

class PidroClient {
  private socket: Socket;
  private lobbyChannel?: Channel;
  private gameChannel?: Channel;
  private presences: any = {};

  constructor(token: string, endpoint: string = "ws://localhost:4000/socket") {
    this.socket = new Socket(endpoint, {
      params: { token }
    });

    this.setupSocketHandlers();
    this.socket.connect();
  }

  private setupSocketHandlers() {
    this.socket.onOpen(() => {
      console.log("Connected to Pidro server");
    });

    this.socket.onError((error) => {
      console.error("Socket error:", error);
    });

    this.socket.onClose(() => {
      console.log("Disconnected from server");
    });
  }

  // Lobby methods
  joinLobby(): Promise<any> {
    return new Promise((resolve, reject) => {
      this.lobbyChannel = this.socket.channel("lobby", {});

      this.setupLobbyHandlers();

      this.lobbyChannel
        .join()
        .receive("ok", (response) => {
          console.log("Joined lobby");
          resolve(response);
        })
        .receive("error", (error) => {
          console.error("Failed to join lobby:", error);
          reject(error);
        });
    });
  }

  private setupLobbyHandlers() {
    if (!this.lobbyChannel) return;

    this.lobbyChannel.on("lobby_update", (payload) => {
      console.log("Lobby updated:", payload.rooms);
      this.onLobbyUpdate?.(payload.rooms);
    });

    this.lobbyChannel.on("presence_state", (state) => {
      this.presences = Presence.syncState(this.presences, state);
      this.onPresenceUpdate?.(this.presences);
    });

    this.lobbyChannel.on("presence_diff", (diff) => {
      this.presences = Presence.syncDiff(this.presences, diff);
      this.onPresenceUpdate?.(this.presences);
    });
  }

  leaveLobby() {
    this.lobbyChannel?.leave();
    this.lobbyChannel = undefined;
  }

  // Game methods
  joinGame(roomCode: string): Promise<{ state: GameState; position: string }> {
    return new Promise((resolve, reject) => {
      this.gameChannel = this.socket.channel(`game:${roomCode}`, {});

      this.setupGameHandlers();

      this.gameChannel
        .join()
        .receive("ok", (response) => {
          console.log("Joined game as:", response.position);
          resolve(response);
        })
        .receive("error", (error) => {
          console.error("Failed to join game:", error);
          reject(error);
        });
    });
  }

  private setupGameHandlers() {
    if (!this.gameChannel) return;

    this.gameChannel.on("game_state", (payload) => {
      this.onGameStateUpdate?.(payload.state);
    });

    this.gameChannel.on("player_ready", (payload) => {
      this.onPlayerReady?.(payload.position);
    });

    this.gameChannel.on("game_over", (payload) => {
      this.onGameOver?.(payload.winner, payload.scores);
    });

    this.gameChannel.on("presence_state", (state) => {
      this.presences = Presence.syncState(this.presences, state);
      this.onPresenceUpdate?.(this.presences);
    });

    this.gameChannel.on("presence_diff", (diff) => {
      this.presences = Presence.syncDiff(this.presences, diff);
      this.onPresenceUpdate?.(this.presences);
    });
  }

  // Game actions
  makeBid(amount: number | "pass"): Promise<void> {
    return this.pushGameAction("bid", { amount });
  }

  declareTrump(suit: "hearts" | "diamonds" | "clubs" | "spades"): Promise<void> {
    return this.pushGameAction("declare_trump", { suit });
  }

  playCard(rank: number, suit: string): Promise<void> {
    return this.pushGameAction("play_card", {
      card: { rank, suit }
    });
  }

  markReady(): Promise<void> {
    return this.pushGameAction("ready", {});
  }

  private pushGameAction(event: string, payload: any): Promise<void> {
    return new Promise((resolve, reject) => {
      if (!this.gameChannel) {
        reject(new Error("Not in a game"));
        return;
      }

      this.gameChannel
        .push(event, payload)
        .receive("ok", () => resolve())
        .receive("error", (error) => reject(error));
    });
  }

  leaveGame() {
    this.gameChannel?.leave();
    this.gameChannel = undefined;
  }

  disconnect() {
    this.leaveLobby();
    this.leaveGame();
    this.socket.disconnect();
  }

  // Event callbacks (set these to handle events)
  onLobbyUpdate?: (rooms: any[]) => void;
  onPresenceUpdate?: (presences: any) => void;
  onGameStateUpdate?: (state: GameState) => void;
  onPlayerReady?: (position: string) => void;
  onGameOver?: (winner: string, scores: any) => void;
}

export default PidroClient;
```

#### Usage Example

```typescript
// Initialize client
const token = localStorage.getItem("auth_token");
const client = new PidroClient(token);

// Set up event handlers
client.onLobbyUpdate = (rooms) => {
  updateRoomList(rooms);
};

client.onGameStateUpdate = (state) => {
  renderGameState(state);
};

client.onGameOver = (winner, scores) => {
  showGameOverScreen(winner, scores);
};

// Join lobby
await client.joinLobby();

// Join a game (after creating/joining via REST API)
const { state, position } = await client.joinGame("A3F9");
console.log("Playing as:", position);

// Make game actions
await client.makeBid(10);
await client.declareTrump("hearts");
await client.playCard(14, "spades"); // Play Ace of Spades

// Clean up
client.disconnect();
```

### Complete Game Flow

```javascript
// 1. User logs in (REST API)
const loginResponse = await fetch("http://localhost:4000/api/auth/login", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ username: "player1", password: "secret" })
});
const { token } = await loginResponse.json();

// 2. Connect WebSocket
const socket = new Socket("ws://localhost:4000/socket", {
  params: { token }
});
socket.connect();

// 3. Join lobby
const lobbyChannel = socket.channel("lobby", {});
await lobbyChannel.join();

lobbyChannel.on("lobby_update", ({ rooms }) => {
  console.log("Available rooms:", rooms);
});

// 4. Create room (REST API)
const createRoomResponse = await fetch("http://localhost:4000/api/rooms", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${token}`
  },
  body: JSON.stringify({ metadata: { name: "Friday Night Game" } })
});
const { room } = await createRoomResponse.json();
console.log("Created room:", room.code);

// 5. Wait for other players to join...
// Other players join via: POST /api/rooms/:code/join

// 6. When room is full, game auto-starts. Join game channel
const gameChannel = socket.channel(`game:${room.code}`, {});
const { state, position } = await new Promise((resolve, reject) => {
  gameChannel
    .join()
    .receive("ok", resolve)
    .receive("error", reject);
});

console.log("Joined game as:", position);
console.log("Initial state:", state);

// 7. Listen for state updates
gameChannel.on("game_state", ({ state }) => {
  console.log("Phase:", state.phase);
  console.log("Current player:", state.current_player);

  if (state.current_player === position) {
    console.log("It's your turn!");

    if (state.phase === "bidding") {
      // Make a bid
      gameChannel.push("bid", { amount: 10 });
    } else if (state.phase === "trump_declaration") {
      // Declare trump
      gameChannel.push("declare_trump", { suit: "hearts" });
    } else if (state.phase === "playing") {
      // Play a card
      const card = state.players[position].hand[0];
      gameChannel.push("play_card", { card });
    }
  }
});

// 8. Handle game over
gameChannel.on("game_over", ({ winner, scores }) => {
  console.log("Game over! Winner:", winner);
  console.log("Scores:", scores);
});
```

---

## Event Reference

### Lobby Channel Events

| Event | Direction | Description | Payload |
|-------|-----------|-------------|---------|
| `join` | Client → Server | Join the lobby | `{}` |
| `lobby_update` | Server → Client | Room list changed | `{rooms: Room[]}` |
| `presence_state` | Server → Client | Current presence state | `{[user_id]: {metas: Meta[]}}` |
| `presence_diff` | Server → Client | Presence changes | `{joins: {...}, leaves: {...}}` |

### Game Channel Events

| Event | Direction | Description | Payload |
|-------|-----------|-------------|---------|
| `join` | Client → Server | Join a game | `{}` |
| `bid` | Client → Server | Make a bid or pass | `{amount: number \| "pass"}` |
| `declare_trump` | Client → Server | Declare trump suit | `{suit: string}` |
| `play_card` | Client → Server | Play a card | `{card: {rank: number, suit: string}}` |
| `ready` | Client → Server | Signal ready status | `{}` |
| `game_state` | Server → Client | Game state update | `{state: GameState}` |
| `player_ready` | Server → Client | Player is ready | `{position: string}` |
| `game_over` | Server → Client | Game ended | `{winner: string, scores: object}` |
| `presence_state` | Server → Client | Current presence state | `{[user_id]: {metas: Meta[]}}` |
| `presence_diff` | Server → Client | Presence changes | `{joins: {...}, leaves: {...}}` |

### Room Object Schema

```typescript
interface Room {
  code: string;              // 4-character alphanumeric code
  host_id: string;           // User ID of room creator
  player_count: number;      // Current number of players (1-4)
  max_players: number;       // Maximum players (always 4)
  status: "waiting" | "ready" | "playing" | "finished";
  created_at: string;        // ISO 8601 timestamp
  metadata: {
    name?: string;           // Optional room name
    [key: string]: any;      // Other custom metadata
  };
}
```

### Game State Schema

```typescript
interface GameState {
  phase: "bidding" | "trump_declaration" | "playing" | "game_over";
  current_player: "north" | "east" | "south" | "west";

  players: {
    [position: string]: {
      hand?: Card[];         // Only visible for your position
      card_count?: number;   // For other players
    };
  };

  bids?: {
    [position: string]: number | "pass";
  };
  current_bid?: number;
  bid_winner?: "north" | "east" | "south" | "west";
  bid_team?: "north_south" | "east_west";

  trump?: "hearts" | "diamonds" | "clubs" | "spades" | null;

  current_trick: Array<{
    player: string;
    card: Card;
  }>;

  tricks: Array<{
    cards: Array<{
      player: string;
      card: Card;
    }>;
    winner: string;
  }>;

  scores: {
    north_south: number;
    east_west: number;
  };

  dealer: "north" | "east" | "south" | "west";
  round_number: number;
}

interface Card {
  rank: number;    // 2-14 (11=Jack, 12=Queen, 13=King, 14=Ace)
  suit: "hearts" | "diamonds" | "clubs" | "spades";
}
```

### Error Response Schema

```typescript
interface ErrorResponse {
  reason: string;  // Human-readable error message
}
```

---

## Best Practices

### 1. Handle Disconnections Gracefully

```javascript
socket.onClose(() => {
  showDisconnectedMessage();
  attemptReconnection();
});

function attemptReconnection() {
  setTimeout(() => {
    socket.connect();
    // Rejoin channels after reconnection
    socket.onOpen(() => {
      lobbyChannel?.join();
      gameChannel?.join();
    });
  }, 1000);
}
```

### 2. Validate Actions Client-Side

Before sending actions to the server, validate them client-side to provide immediate feedback:

```javascript
function playCard(card) {
  if (gameState.current_player !== myPosition) {
    showError("It's not your turn");
    return;
  }

  if (!isValidPlay(card, gameState)) {
    showError("Invalid card play");
    return;
  }

  gameChannel.push("play_card", { card });
}
```

### 3. Use Presence for Online Status

Show which players are currently connected:

```javascript
gameChannel.on("presence_diff", (diff) => {
  presences = Presence.syncDiff(presences, diff);

  const onlinePlayers = Presence.list(presences, (id, { metas }) => {
    return { id, position: metas[0].position };
  });

  updatePlayerOnlineStatus(onlinePlayers);
});
```

### 4. Handle Token Expiration

JWT tokens expire after 30 days. Implement token refresh:

```javascript
socket.onError((error) => {
  if (error.toString().includes("invalid") ||
      error.toString().includes("expired")) {
    refreshToken();
  }
});

async function refreshToken() {
  const newToken = await fetchNewToken();
  localStorage.setItem("auth_token", newToken);

  // Reconnect with new token
  socket.disconnect();
  socket = new Socket(endpoint, { params: { token: newToken } });
  socket.connect();
}
```

### 5. Debounce Rapid Actions

Prevent accidental double-clicks:

```javascript
let isActionPending = false;

async function makeBid(amount) {
  if (isActionPending) return;

  isActionPending = true;

  try {
    await gameChannel.push("bid", { amount });
  } finally {
    setTimeout(() => {
      isActionPending = false;
    }, 1000);
  }
}
```

---

## Troubleshooting

### Connection Issues

**Problem:** WebSocket connection fails or immediately disconnects

**Solutions:**
- Verify token is valid and not expired
- Check WebSocket endpoint URL (ws:// vs wss://)
- Ensure CORS is configured correctly for your domain
- Check browser console for detailed error messages

### Channel Join Failures

**Problem:** Cannot join lobby or game channel

**Solutions:**
- Verify socket is connected before joining channels
- For game channels, ensure you're a player in the room
- Check that the game has been started
- Verify room code is correct and uppercase

### Actions Not Working

**Problem:** Game actions are rejected by the server

**Solutions:**
- Verify it's your turn (`state.current_player === myPosition`)
- Check you're in the correct game phase for the action
- Ensure action payload format is correct
- Check server error message for specific validation failures

### Presence Not Updating

**Problem:** Presence information is stale or incorrect

**Solutions:**
- Use `Presence.syncState()` and `Presence.syncDiff()` correctly
- Ensure you're listening to both `presence_state` and `presence_diff`
- Don't manually manipulate presence data structures

---

## Support

For additional help:
- Review the Phoenix Channels documentation: https://hexdocs.pm/phoenix/channels.html
- Check the Phoenix JavaScript client docs: https://hexdocs.pm/phoenix/js/
- File issues on the project repository

---

**API Version:** 1.0
**Last Updated:** January 2025
