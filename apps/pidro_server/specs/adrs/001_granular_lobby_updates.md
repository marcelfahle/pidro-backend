# ADR 001: Granular Lobby Updates vs Full State Broadcast

## Status
Accepted

## Context
The Pidro game lobby displays a list of available game rooms. As the user base grows, room state changes (player counts, status changes) occur frequently.

Initially, the server broadcasted a full `lobby_update` event containing the entire list of rooms every time any room changed.
- **Pros**: Client is stateless; simple implementation.
- **Cons**: High bandwidth usage (O(N) where N is room count); potential UI flickering; race conditions; inefficient for mobile clients on poor networks.

## Decision
We have shifted to a **Delta Update** architecture using granular events.

1.  **Initial State**: Delivered once upon successful channel join.
    - Event: `phx_reply` (ok)
    - Payload: `%{rooms: [...]}`
    
2.  **Incremental Updates**: The server broadcasts specific events for state changes.
    - `room_created`: `%{room: RoomData}`
    - `room_updated`: `%{room: RoomData}`
    - `room_closed`: `%{room_code: String}`

3.  **Re-sync**: Relies on Phoenix Channel's robust TCP/WebSocket connection. If a client disconnects, the automatic rejoin logic triggers Step 1 again, fetching a fresh "Single Source of Truth" snapshot.

## Consequences

### Server Side
- Reduced bandwidth usage significantly.
- `RoomManager` no longer serializes the full room list on every operation.
- `LobbyChannel` handles specific push events.

### Client Side
- **Complexity**: Increased. Client must maintain local state (reducer pattern).
- **Performance**: Improved. UI only updates specific rows.
- **Robustness**: Client must ensure it correctly handles the initial payload on *every* (re)connect to handle any events missed during a disconnection.

## Implementation Details
- **LobbyChannel**: 
  - `join/3`: Returns `{:ok, %{rooms: [...]}, socket}`
  - `handle_info/2`: Pushes `room_created`, `room_updated`, `room_closed`
- **RoomManager**:
  - Broadcasts `{:room_*, ...}` to internal PubSub.
  - **Does not** broadcast full `lobby_update` anymore.
  
## Amendment: Payload Enrichment (2025-11-24)

To support rich UI features (avatars, seat selection), the `RoomData` payload in `room_created`, `room_updated`, and the initial join list has been enriched.

**New Payload Structure:**
In addition to basic metadata, the `room` object now contains a `seats` array.

```json
{
  "room": {
    "code": "ABCD",
    "player_count": 2,
    "seats": [
      {
        "seat_index": 0,
        "status": "occupied",
        "player": {
          "id": "user_123",
          "username": "Alice",
          "is_bot": false,
          "avatar_url": null
        }
      },
      { "seat_index": 1, "status": "free", "player": null },
      ...
    ]
  }
}
```

