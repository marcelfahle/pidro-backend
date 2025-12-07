# Seat Selection - Frontend Implementation Spec

**Commit**: `7af7099f807bd218539f2e757022b47df4bde6ec`  
**Date**: December 6, 2025  
**Status**: Implemented in backend, ready for frontend integration

---

## Summary

Players can now choose their seat position when joining a room instead of being auto-assigned.

---

## What Changed

### Before (Auto-Assignment Only)

```http
POST /api/v1/rooms/:code/join
Authorization: Bearer <token>
```

Response:
```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "host_id": "user123",
      "player_ids": ["user123", "user456"],
      "status": "waiting",
      ...
    }
  }
}
```

### After (Optional Position Selection)

```http
POST /api/v1/rooms/:code/join
Authorization: Bearer <token>
Content-Type: application/json

{
  "position": "north"  // Optional - can be omitted for auto-assignment
}
```

Response:
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
      "player_ids": ["user123", "user456"],  // Still included for backward compatibility
      "status": "waiting",
      ...
    },
    "assigned_position": "north"  // New field - confirms which seat was assigned
  }
}
```

---

## API Changes

### Join Room Endpoint

**Endpoint**: `POST /api/v1/rooms/:code/join`

**New Request Body** (optional):
```json
{
  "position": "<position_value>"
}
```

**Position Values**:

| Value | Type | Behavior |
|-------|------|----------|
| `null` / omitted | Auto | First available seat (N→E→S→W order) |
| `"north"` | Specific Seat | Assigns to North if available |
| `"east"` | Specific Seat | Assigns to East if available |
| `"south"` | Specific Seat | Assigns to South if available |
| `"west"` | Specific Seat | Assigns to West if available |
| `"north_south"` | Team Preference | Assigns to first available North or South |
| `"east_west"` | Team Preference | Assigns to first available East or West |

### New Response Fields

All room responses now include:

| Field | Type | Description |
|-------|------|-------------|
| `positions` | Object | Map of position → player_id (or null if empty) |
| `available_positions` | Array | List of unoccupied positions: `["north", "east", ...]` |
| `player_count` | Number | Count of seated players (0-4) |
| `assigned_position` | String | (Join only) The position that was assigned |

The `player_ids` array is still included for **backward compatibility** but is now derived from `positions`.

---

## New Error Codes

| Error Code | HTTP Status | Description |
|------------|-------------|-------------|
| `SEAT_TAKEN` | 422 | Requested specific seat is already occupied |
| `TEAM_FULL` | 422 | Both seats on requested team are taken |
| `INVALID_POSITION` | 422 | Invalid position value provided |

**Error Response Example**:
```json
{
  "errors": [
    {
      "code": "SEAT_TAKEN",
      "title": "Seat taken",
      "detail": "The north seat is already occupied"
    }
  ]
}
```

---

## Frontend Implementation Guide

### 1. Room Lobby View

Display available seats when showing room details:

```javascript
// Fetch room details
const response = await fetch(`/api/v1/rooms/${code}`)
const { data: { room } } = await response.json()

// room.positions = { north: "user1", east: null, south: null, west: "user2" }
// room.available_positions = ["east", "south"]
// room.player_count = 2
```

**UI Suggestions**:
- Show a 4-seat table/layout with player names or "Empty" labels
- Highlight available seats as clickable
- Show team groupings (North+South vs East+West)

### 2. Join Room Flow

**Option A: Quick Join (Auto-assign)**
```javascript
// No body needed - auto-assigns first available seat
await fetch(`/api/v1/rooms/${code}/join`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${token}` }
})
```

**Option B: Seat Selection**
```javascript
// User picks a specific seat
await fetch(`/api/v1/rooms/${code}/join`, {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ position: 'north' })
})
```

**Option C: Team Preference**
```javascript
// User picks a team, server assigns first available seat on that team
await fetch(`/api/v1/rooms/${code}/join`, {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({ position: 'north_south' })
})
```

### 3. Handle Join Response

```javascript
const response = await fetch(`/api/v1/rooms/${code}/join`, { ... })
const { data } = await response.json()

// data.assigned_position tells you where the player was seated
console.log(`You are seated at: ${data.assigned_position}`)  // "north"

// data.room.positions shows the full seating arrangement
console.log(data.room.positions)  // { north: "me", east: null, south: "friend", west: null }
```

### 4. Error Handling

```javascript
const response = await fetch(`/api/v1/rooms/${code}/join`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ position: 'north' })
})

if (!response.ok) {
  const { errors } = await response.json()
  
  switch (errors[0]?.code) {
    case 'SEAT_TAKEN':
      // Show "This seat is already taken, please choose another"
      break
    case 'TEAM_FULL':
      // Show "Both seats on this team are taken"
      break
    case 'ROOM_FULL':
      // Show "Room is full"
      break
    case 'ALREADY_IN_ROOM':
      // Show "You're already in another room"
      break
  }
}
```

---

## WebSocket Updates

Room updates via `LobbyChannel` and `GameChannel` now include the new position fields:

```javascript
// Lobby channel subscription
channel.on("room_updated", ({ room }) => {
  // room.positions, room.available_positions, room.player_count now included
})

// Game channel subscription  
channel.on("player_joined", ({ player }) => {
  // player.position now indicates their seat
})
```

---

## Backward Compatibility

- The `player_ids` array is still returned in all room responses
- Omitting `position` in join request still works (auto-assignment)
- Existing frontend code will continue to work without changes
- New features are additive, not breaking

---

## Recommended UX Flow

1. **Room List**: Show rooms with `player_count`/4 indicator
2. **Room Details**: Show visual seat layout with occupied/available seats
3. **Join Options**:
   - "Quick Join" button → auto-assign
   - Click on specific empty seat → join that seat
   - "Join Team A/B" buttons → team preference
4. **After Join**: Show confirmation with assigned seat highlighted

---

## Testing Checklist

- [ ] Join with no position (auto-assign)
- [ ] Join with specific seat (north/east/south/west)
- [ ] Join with team preference (north_south/east_west)
- [ ] Handle SEAT_TAKEN error
- [ ] Handle TEAM_FULL error
- [ ] Display positions map correctly
- [ ] Display available_positions list
- [ ] Real-time updates via WebSocket show positions
