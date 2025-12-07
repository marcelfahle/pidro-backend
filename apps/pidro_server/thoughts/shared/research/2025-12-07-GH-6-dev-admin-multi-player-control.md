---
date: 2025-12-07T03:50:21+0000
researcher: Claude Code
git_commit: 366c53748540ab4afa2232c4868a764d12b0266d
branch: main
repository: pidro_backend
topic: "GitHub Issue #6: Dev Admin Multi-Player Session Control for Testing"
tags: [research, codebase, dev-admin, seat-management, testing, github-issue-6]
status: complete
last_updated: 2025-12-07
last_updated_by: Claude Code
---

# Research: GitHub Issue #6 - Dev Admin Multi-Player Session Control for Testing

**Date**: 2025-12-07T03:50:21+0000  
**Researcher**: Claude Code  
**Git Commit**: 366c53748540ab4afa2232c4868a764d12b0266d  
**Branch**: main  
**Repository**: pidro_backend

## Research Question

What does the dev admin panel currently support for room/seat management, and what's needed to add user selection per seat for testing? This supports GitHub Issue #6.

**The actual requirement**: Allow dev admin to populate `room.positions` map with test users from a dropdown. The dev stays authenticated as themselves - they're not "becoming" other users, just setting up test scenarios by directly manipulating which user IDs occupy which seats.

## Summary

This is a simple UI enhancement to the dev admin panel, not a complex authentication/impersonation feature.

### What Exists:
1. **Dev Admin Panel**: LiveView-based UI at `/dev/games` with GameListLive and GameDetailLive
2. **Room.positions Map**: Single source of truth for seat assignments (`%{north: user_id, east: user_id, south: user_id, west: user_id}`)
3. **User Lookup**: `Auth.list_recent_users/1` available for populating dropdowns
4. **Game Engine**: Already position-based - `GameAdapter.apply_action(room_code, :north, action)` doesn't care about authentication
5. **Existing "Play As" Switcher**: GameDetailLive likely already has position selection for actions

### What's Needed:
1. **User picker dropdown per seat** (4 dropdowns: north, east, south, west)
2. **Update room.positions directly** when user selected from dropdown
3. **Use existing position switcher** for playing as different seats

### What's NOT Needed:
- ❌ Multiple JWT tokens or sessions
- ❌ WebSocket connections per "virtual player"
- ❌ Authentication bypass or impersonation
- ❌ New API endpoints
- ❌ Complex session management

## Detailed Findings

### 1. Dev Admin Panel Structure

**GameListLive** (`lib/pidro_server_web/live/dev/game_list_live.ex`):
- Game listing, filtering, creation UI
- Already has host_id selection in create form
- Could be extended with per-seat user selection

**GameDetailLive** (`lib/pidro_server_web/live/dev/game_detail_live.ex`):
- Game state inspection
- **Target location for seat management UI**
- Should add 4 user picker dropdowns (one per compass position)

### 2. Room Position Management

**Room Struct** (`lib/pidro_server/games/room_manager.ex:53-105`):
```elixir
defmodule Room do
  defstruct [
    :code,
    :host_id,
    positions: %{north: nil, east: nil, south: nil, west: nil},
    # ... other fields
  ]
end
```

**The positions map is the single source of truth.** Just populate it:
```elixir
# That's it - no authentication needed
updated_room = %{room | positions: %{
  north: "alice-uuid",
  east: "bob-uuid", 
  south: "carol-uuid",
  west: nil  # or bot ID
}}
```

### 3. User Selection

**Auth.list_recent_users/1** (`lib/pidro_server/accounts/auth.ex`):
```elixir
def list_recent_users(limit \\ 10) do
  Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
end
```

Use this to populate dropdowns with test users.

### 4. Position-Based Game Actions

**GameAdapter** (`lib/pidro_server/games/game_adapter.ex:70-92`):
```elixir
def apply_action(room_code, position, action) do
  # Position is just :north, :east, :south, or :west
  # No authentication check here - that's already done at channel level
  Pidro.Server.apply_action(pid, position, action)
end
```

The game engine doesn't care about JWT tokens - it just receives position atoms. The dev admin (already authenticated) can send actions as any position they choose via the existing UI.

### 5. RoomManager Update Pattern

**To update positions, call RoomManager** (`lib/pidro_server/games/room_manager.ex`):

Add a new GenServer call for dev-only seat assignment:
```elixir
# In RoomManager
def dev_set_position(room_code, position, user_id) do
  GenServer.call(__MODULE__, {:dev_set_position, room_code, position, user_id})
end

# Handler
def handle_call({:dev_set_position, room_code, position, user_id}, _from, state) do
  with {:ok, room} <- fetch_room(state, room_code) do
    updated_positions = Map.put(room.positions, position, user_id)
    updated_room = %{room | positions: updated_positions}
    new_state = %{state | rooms: Map.put(state.rooms, room_code, updated_room)}
    
    broadcast_room(updated_room, state)
    {:reply, {:ok, updated_room}, new_state}
  end
end
```

Or even simpler - just update the map directly in the LiveView if the room isn't started yet.

### 6. Player Count Derivation

**Player count is always derived** (`lib/pidro_server/games/room/positions.ex:49-51`):
```elixir
def count(room) do
  room |> player_ids() |> length()
end
```

This means setting `positions.north = "user123"` automatically increases player count by 1 when serialized. No manual count tracking needed.

## Implementation Approach (Trivial)

### Option A: Game Creation Form (GameListLive)

Extend the existing create form with 4 user dropdowns:

```elixir
# In GameListLive
def render(assigns) do
  ~H"""
  <.form for={@form} phx-submit="create_game">
    <.input field={@form[:game_name]} label="Game Name" />
    
    <!-- Per-seat user selection -->
    <.input 
      field={@form[:north_user]} 
      type="select" 
      label="North Seat"
      options={[{"Empty", nil} | Enum.map(@users, &{&1.username, &1.id})]}
    />
    
    <.input field={@form[:east_user]} type="select" label="East Seat" options={...} />
    <.input field={@form[:south_user]} type="select" label="South Seat" options={...} />
    <.input field={@form[:west_user]} type="select" label="West Seat" options={...} />
    
    <.button>Create Game</.button>
  </.form>
  """
end

def mount(_params, _session, socket) do
  users = Auth.list_recent_users(20)  # Get test users
  {:ok, assign(socket, users: users)}
end

def handle_event("create_game", params, socket) do
  positions = %{
    north: params["north_user"],
    east: params["east_user"],
    south: params["south_user"],
    west: params["west_user"]
  }
  
  RoomManager.create_room_with_positions(code, positions, metadata)
  # ...
end
```

### Option B: GameDetailLive Post-Creation

Add seat management UI to the detail view:

```elixir
# In GameDetailLive
~H"""
<div class="seat-grid">
  <div class="seat north">
    <.user_picker position={:north} current={@room.positions.north} users={@users} />
  </div>
  <div class="seat east">
    <.user_picker position={:east} current={@room.positions.east} users={@users} />
  </div>
  <!-- ... south, west -->
</div>
"""

def handle_event("assign_seat", %{"position" => pos, "user_id" => user_id}, socket) do
  position = String.to_existing_atom(pos)
  RoomManager.dev_set_position(socket.assigns.room.code, position, user_id)
  {:noreply, socket}
end
```

### Backend Addition (Minimal)

Add one new function to RoomManager:

```elixir
# lib/pidro_server/games/room_manager.ex

@doc """
Dev-only function to directly set a position without join validation.
Used by dev UI to populate test scenarios.
"""
def dev_set_position(room_code, position, user_id) 
    when position in [:north, :east, :south, :west] do
  GenServer.call(__MODULE__, {:dev_set_position, room_code, position, user_id})
end

def handle_call({:dev_set_position, room_code, position, user_id}, _from, state) do
  with {:ok, room} <- fetch_room(state, room_code) do
    updated_positions = Map.put(room.positions, position, user_id)
    updated_room = %{room | positions: updated_positions}
                   |> maybe_set_ready()
                   |> touch_last_activity()
    
    new_state = %{state | rooms: Map.put(state.rooms, room_code, updated_room)}
    broadcast_room(updated_room, state)
    
    {:reply, {:ok, updated_room}, new_state}
  end
end
```

That's it. ~30 lines of code.

## Code References

### Files to Modify

1. **`lib/pidro_server_web/live/dev/game_list_live.ex`** - Add user pickers to create form
2. **`lib/pidro_server_web/live/dev/game_detail_live.ex`** - Add seat management UI (optional)
3. **`lib/pidro_server/games/room_manager.ex`** - Add `dev_set_position/3` function

### Files to Reference

- `lib/pidro_server/accounts/auth.ex` - `list_recent_users/1` for dropdown data
- `lib/pidro_server/games/room/positions.ex` - Position constants and utilities
- `lib/pidro_server/games/room_manager.ex:979-985` - `maybe_set_ready/1` auto-ready check
- `lib/pidro_server_web/controllers/api/room_json.ex:102` - Player count serialization

## Known Issue: "2/4 Players" Bug

The issue mentions a bug where games show "2/4 players" when 4 are assigned.

**Diagnosis**: Since player count is derived via `Positions.count(room)` which literally counts non-nil values in the positions map, this bug means:
- Either the positions map only has 2 entries when it should have 4
- Or the frontend is displaying stale/incorrect data

**Not a count calculation bug** - the backend always derives count correctly.

**Likely causes**:
1. Frontend not receiving/processing broadcast updates correctly
2. Race condition in broadcast timing
3. Position assignment failing silently for some players

**Investigation needed**:
- Check browser console for WebSocket errors
- Verify all 4 players in positions map on backend during "2/4" state
- Check if broadcast happens before state update completes

## Conclusion

Issue #6 is **not about authentication or impersonation**. It's about:

1. Adding 4 dropdowns to select users for each compass position
2. Updating `room.positions` map when selections change
3. Using the existing position-based game action system

**Estimated implementation**: 50-100 lines of code across 2-3 files.

**Key insight**: The game engine is already position-based and doesn't care about JWT tokens. The dev admin (already authenticated) just needs a UI to:
- Pick which user IDs go in which positions
- Select which position to "play as" for actions (likely already exists)

No complex session management, no authentication bypass, no WebSocket multiplexing needed.
