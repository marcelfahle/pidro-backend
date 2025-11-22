# Spectator Mode: Quick Reference

## Files to Modify (In Order)

### 1. `lib/pidro_server/games/room_manager.ex` (Primary)
**Time: 3 hours**

**Changes:**
- Add fields to Room struct:
  ```elixir
  spectator_ids: [],           # List of spectator user IDs
  max_spectators: 10           # Max spectators allowed
  ```

- Add 3 new functions:
  1. `join_spectator_room(room_code, spectator_id)` - Adds spectator to room
  2. `leave_spectator(room_code, spectator_id)` - Removes spectator from room
  3. `is_spectator?(room_code, spectator_id)` - Checks if user is spectator

**Key Logic:**
- Prevent spectators from counting toward 4-player limit
- Prevent players from being spectators in same room
- Update PubSub broadcasts to include spectator info

---

### 2. `lib/pidro_server_web/channels/game_channel.ex` (Core)
**Time: 2-3 hours**

**Changes:**
- Modify `join/3` to detect and handle spectators:
  ```elixir
  def determine_user_role(user_id, room) do
    cond do
      user_id in room.player_ids -> :player
      user_id in room.spectator_ids -> :spectator
      room.status in [:playing, :finished] -> :spectator  # Allow watch
      true -> :not_allowed
    end
  end
  ```

- Add `proceed_with_spectator_join/3` function for spectator-specific logic

- Guard `apply_game_action/1` to prevent spectator actions:
  ```elixir
  defp apply_game_action(socket, _action) when socket.assigns.role == :spectator do
    {:reply, {:error, %{reason: "Spectators cannot perform actions"}}, socket}
  end
  ```

- Update presence tracking to include `:role` field:
  ```elixir
  Presence.track(socket, user_id, %{
    role: :spectator,
    online_at: DateTime.utc_now() |> DateTime.to_unix()
  })
  ```

**Socket Assigns to Add:**
- `:role` - either `:player` or `:spectator`
- `:position` - nil for spectators

---

### 3. `lib/pidro_server_web/controllers/api/room_controller.ex` (Secondary)
**Time: 1 hour**

**Changes:**
- Add `join_as_spectator/2` action:
  ```elixir
  def join_as_spectator(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]
    with {:ok, room} <- RoomManager.join_spectator_room(code, user.id) do
      conn |> put_view(RoomJSON) |> render(:show, %{room: room})
    end
  end
  ```

- Add `leave_as_spectator/2` action:
  ```elixir
  def leave_as_spectator(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]
    with :ok <- RoomManager.leave_spectator(code, user.id) do
      conn |> put_status(:no_content) |> send_resp(:no_content, "")
    end
  end
  ```

- Update `show/2` serialization to include spectator info

---

### 4. `lib/pidro_server_web/router.ex` (Quick)
**Time: 15 minutes**

**Changes:**
- Add authenticated routes:
  ```elixir
  post "/rooms/:code/watch", RoomController, :join_as_spectator
  delete "/rooms/:code/unwatch", RoomController, :leave_as_spectator
  ```

---

### 5. `lib/pidro_server_web/channels/lobby_channel.ex` (Optional)
**Time: 30 minutes**

**Changes:**
- Update `serialize_room/1` to include spectator count:
  ```elixir
  %{
    code: room.code,
    host_id: room.host_id,
    player_count: length(room.player_ids),
    spectator_count: length(room.spectator_ids),  # NEW
    status: room.status,
    ...
  }
  ```

---

## Implementation Checklist

### Phase 1: MVP (Minimal Viable Product)
- [ ] Modify Room struct in RoomManager
- [ ] Add `join_spectator_room/2` to RoomManager
- [ ] Add `leave_spectator/2` to RoomManager
- [ ] Update RoomManager broadcasts for spectators
- [ ] Modify GameChannel.join/3 to handle spectators
- [ ] Add role check in `apply_game_action/1`
- [ ] Update presence tracking with role field
- [ ] Add controller actions for spectator join/leave
- [ ] Add router endpoints
- [ ] Write unit tests for RoomManager
- [ ] Write channel tests for spectator join/action prevention

**Estimated Total Time: 6-8 hours**

### Phase 2: Polish (Optional)
- [ ] Update LobbyChannel serialization
- [ ] Add spectator presence filtering
- [ ] Write integration tests
- [ ] Document API changes
- [ ] Add OpenAPI specs for new endpoints

**Estimated Time: 2-3 hours**

### Phase 3: Advanced (Future)
- [ ] Spectator disconnect/reconnect grace period
- [ ] Filtered state for spectators (hide hands)
- [ ] Host controls (mute/kick spectators)
- [ ] Spectator chat/comments
- [ ] Spectator analytics

---

## Error Cases to Handle

### RoomManager

1. **Room Not Found**
   ```elixir
   {:error, :room_not_found}
   ```

2. **Max Spectators Reached**
   ```elixir
   {:error, :max_spectators_reached}
   ```

3. **User Already a Player**
   ```elixir
   {:error, :already_in_room}
   ```

4. **User Already Spectating This Room**
   ```elixir
   {:error, :already_spectating}
   ```

### GameChannel

1. **Spectator Attempts Action**
   ```elixir
   {:reply, {:error, %{reason: "Spectators cannot perform actions"}}, socket}
   ```

2. **Cannot Join as Spectator in Waiting Room**
   - Logic: Only allow spectators in `:playing` or `:finished` rooms (configurable)

---

## Key Design Decisions

### 1. Spectators Don't Count Toward 4-Player Limit
- Keeps game mechanics unchanged
- Spectators join via separate path

### 2. Full State Broadcast (MVP)
- Spectators see complete game state (including hidden cards)
- Client-side filtering for UI
- Can implement server-side filtering in Phase 3

### 3. Spectators Have No Position
- Set `:position` to `nil` for spectators
- No turn order or game actions

### 4. Single Channel for Players & Spectators
- Use same `"game:CODE"` channel
- Role differentiation via `:role` socket assign
- Simpler than separate channels

### 5. Presence Tracking Enhancement
- Add `:role` field to metadata
- No separate presence system needed

---

## Testing Scenarios

### Unit Tests

```elixir
# RoomManager Tests
- test: "allows spectator to join active game"
- test: "prevents exceeding max spectators"
- test: "prevents player from joining as spectator"
- test: "spectator can rejoin same room"
- test: "spectator leave removes from room"

# GameChannel Tests
- test: "spectator can join via channel"
- test: "spectator cannot perform game actions"
- test: "spectator receives game state updates"
- test: "spectator presence tracked with role"
```

### Integration Tests

```elixir
- test: "spectator can watch multiple games"
- test: "spectator disconnect and reconnect"
- test: "spectator presence shown to players"
```

---

## API Examples

### Join as Spectator
```bash
POST /api/v1/rooms/A3F9/watch
Authorization: Bearer <token>

Response (200):
{
  "data": {
    "room": {
      "code": "A3F9",
      "status": "playing",
      "player_ids": ["user1", "user2", "user3", "user4"],
      "spectator_ids": ["spectator1"],
      "spectator_count": 1,
      "max_spectators": 10
    }
  }
}
```

### Leave as Spectator
```bash
DELETE /api/v1/rooms/A3F9/unwatch
Authorization: Bearer <token>

Response (204): (empty)
```

### Get Room with Spectator Info
```bash
GET /api/v1/rooms/A3F9

Response (200):
{
  "data": {
    "room": {
      "code": "A3F9",
      "player_count": 4,
      "spectator_count": 2,
      "spectator_ids": ["spectator1", "spectator2"],
      "max_spectators": 10
    }
  }
}
```

---

## Channel Events

### New Events (No Changes to Existing)

**Client Receives (No new outbound events needed)**
- Same `"game_state"` updates
- Same `"presence_diff"` updates
- Same `"game_over"` event

**Client Sends (Spectators cannot send)**
- Spectators can't send: `"bid"`, `"declare_trump"`, `"play_card"`, `"ready"`
- Error returned if attempted

---

## Open Questions for Refinement

1. **Should spectators be allowed in `:waiting` rooms?**
   - Current recommendation: No, only join `:playing` or `:finished`
   - Alternative: Allow anytime

2. **Should spectators see hidden player hands?**
   - Current recommendation: Yes (Option A: Full State)
   - Alternative: No (Option B: Filtered State) - more complex

3. **Should spectators have a grace period on disconnect?**
   - Current recommendation: No (keep simple)
   - Alternative: Yes (like players) - adds complexity

4. **Max spectators per room - should it be configurable?**
   - Current recommendation: Yes, configurable in config
   - Default: 10

5. **Should host be able to control spectators?**
   - Current recommendation: Not in MVP
   - Future enhancement: Mute, kick, hide spectators

---

## Success Criteria (MVP)

- [ ] Spectators can join active games
- [ ] Spectators cannot perform game actions
- [ ] Spectators receive game state updates in real-time
- [ ] Spectators appear in presence tracking with `:role` field
- [ ] API endpoints work correctly with proper error handling
- [ ] No impact on existing player functionality
- [ ] Unit tests pass
- [ ] Channel joins/disconnects work smoothly

