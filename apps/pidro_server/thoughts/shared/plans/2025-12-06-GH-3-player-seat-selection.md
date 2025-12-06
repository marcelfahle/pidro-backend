# Player Seat Selection Implementation Plan (GitHub Issue #3)

**Date**: 2025-12-06
**GitHub Issue**: https://github.com/marcelfahle/pidro-backend/issues/3
**Related Research**: `thoughts/shared/research/2025-12-06-GH-3-player-seat-selection.md`

## Overview

Implement player seat selection when joining rooms, allowing players to choose their position (North/South/East/West) or team (North-South/East-West) instead of automatic sequential assignment.

## Architecture Philosophy

This implementation follows principles from Rich Hickey and Dave Thomas:

- **Single Source of Truth**: `positions` map is the authoritative state; `player_ids` is derived, not stored
- **Pure Functions over GenServer Logic**: All seating logic lives in a pure `Room.Positions` module
- **Thin GenServer**: RoomManager coordinates state but delegates business logic
- **Data > Functions > Macros**: Position operations are pure data transformations
- **Small, Focused Modules**: Each module has one responsibility

## Current State Analysis

**Existing Behavior**:
- Players join via `POST /api/v1/rooms/:code/join` with no request body
- Positions calculated on-the-fly from `player_ids` list order (never stored)
- Position only revealed when joining WebSocket channel
- Room listing doesn't show seat availability

**Key Files**:
- `lib/pidro_server/games/room_manager.ex` - Room struct, join/leave logic
- `lib/pidro_server_web/controllers/api/room_controller.ex` - HTTP join endpoint
- `lib/pidro_server_web/channels/game_channel.ex` - Position calculation

## Desired End State

**API**:
```bash
# Explicit position
POST /api/v1/rooms/A1B2/join
{"position": "north"}

# Team selection
POST /api/v1/rooms/A1B2/join
{"position": "north_south"}

# Quick join (auto)
POST /api/v1/rooms/A1B2/join
```

**Response**:
```json
{
  "data": {
    "room": {
      "code": "A1B2",
      "positions": {"north": "user123", "east": null, "south": null, "west": null},
      "available_positions": ["east", "south", "west"],
      "player_count": 1
    }
  }
}
```

**Error (seat taken)**:
```json
{
  "errors": [{
    "code": "SEAT_TAKEN",
    "detail": "Position north is already occupied",
    "available_positions": ["south", "west"]
  }]
}
```

## What We're NOT Doing

- No position swapping after joining
- No database persistence (in-memory only)
- No game engine changes
- No spectator positioning

---

## Error Inventory

Complete list of errors from `join_room/3` and their FallbackController status:

### From `Positions.assign/3` (Pure Module)

| Error | HTTP | Code | FallbackController |
|-------|------|------|-------------------|
| `:seat_taken` | 422 | `SEAT_TAKEN` | **New** - add handler |
| `:team_full` | 422 | `TEAM_FULL` | **New** - add handler |
| `:room_full` | 422 | `ROOM_FULL` | ✅ Exists (line 108) |
| `:invalid_position` | 422 | `INVALID_POSITION` | **New** - add handler |

### From GenServer Validation

| Error | HTTP | Code | FallbackController |
|-------|------|------|-------------------|
| `:room_not_found` | 404 | `ROOM_NOT_FOUND` | ✅ Exists (line 94) |
| `:already_in_room` | 422 | `ALREADY_IN_ROOM` | ✅ Exists (line 122) |
| `:already_in_this_room` | 422 | `ALREADY_IN_THIS_ROOM` | ✅ Exists (line 136) |
| `:room_not_available` | 422 | `ROOM_NOT_AVAILABLE` | **New** - add handler |

### New Handlers Required

Add to `lib/pidro_server_web/controllers/api/fallback_controller.ex`:

```elixir
def call(conn, {:error, :seat_taken}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "SEAT_TAKEN",
      title: "Seat taken",
      detail: "The requested position is already occupied"
    }]
  })
end

def call(conn, {:error, :team_full}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "TEAM_FULL",
      title: "Team full",
      detail: "The requested team has no available positions"
    }]
  })
end

def call(conn, {:error, :invalid_position}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "INVALID_POSITION",
      title: "Invalid position",
      detail: "Position must be: north, east, south, west, north_south, or east_west"
    }]
  })
end

def call(conn, {:error, :room_not_available}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "ROOM_NOT_AVAILABLE",
      title: "Room not available",
      detail: "Room is not accepting new players"
    }]
  })
end
```

---

## Phase 1: Pure Positions Module

### Overview

Create a pure functional module that handles all position logic. No GenServer, no side effects—just data transformations.

### New File: `lib/pidro_server/games/room/positions.ex`

```elixir
defmodule PidroServer.Games.Room.Positions do
  @moduledoc """
  Pure functions for room position management.
  
  Positions map is the single source of truth for player seating.
  Player IDs are derived from positions, never stored separately.
  """

  alias PidroServer.Games.RoomManager.Room

  @type position :: :north | :east | :south | :west
  @type team :: :north_south | :east_west
  @type choice :: position() | team() | :auto | nil

  @positions [:north, :east, :south, :west]
  @teams %{
    north_south: [:north, :south],
    east_west: [:east, :west]
  }

  @doc "Returns empty positions map."
  @spec empty() :: %{position() => nil}
  def empty, do: %{north: nil, east: nil, south: nil, west: nil}

  @doc "Returns list of available positions in canonical order."
  @spec available(Room.t()) :: [position()]
  def available(%Room{positions: positions}) do
    for pos <- @positions,
        is_nil(Map.get(positions, pos)),
        do: pos
  end

  @doc "Returns available positions for a team."
  @spec team_available(Room.t(), team()) :: [position()]
  def team_available(%Room{positions: positions}, team) do
    @teams
    |> Map.fetch!(team)
    |> Enum.filter(&is_nil(positions[&1]))
  end

  @doc "Derives player IDs from positions in canonical order."
  @spec player_ids(Room.t()) :: [String.t()]
  def player_ids(%Room{positions: positions}) do
    @positions
    |> Enum.map(&positions[&1])
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns player count."
  @spec count(Room.t()) :: non_neg_integer()
  def count(room), do: room |> player_ids() |> length()

  @doc "Checks if player is in room."
  @spec has_player?(Room.t(), String.t()) :: boolean()
  def has_player?(%Room{positions: positions}, player_id) do
    positions
    |> Map.values()
    |> Enum.member?(player_id)
  end

  @doc "Gets player's position, or nil if not in room."
  @spec get_position(Room.t(), String.t()) :: position() | nil
  def get_position(%Room{positions: positions}, player_id) do
    Enum.find_value(positions, fn {pos, id} ->
      if id == player_id, do: pos, else: nil
    end)
  end

  @doc """
  Assigns a player to a position.
  
  Choice can be:
  - `:north`, `:east`, `:south`, `:west` - explicit position
  - `:north_south`, `:east_west` - team (first available on team)
  - `:auto` or `nil` - first available position
  """
  @spec assign(Room.t(), String.t(), choice()) ::
          {:ok, Room.t(), position()}
          | {:error, :seat_taken | :team_full | :room_full | :invalid_position}
  def assign(%Room{max_players: max} = room, player_id, choice) do
    if count(room) >= max do
      {:error, :room_full}
    else
      do_assign(room, player_id, normalize_choice(choice))
    end
  end

  @doc "Removes a player from their position."
  @spec remove(Room.t(), String.t()) :: Room.t()
  def remove(%Room{positions: positions} = room, player_id) do
    case get_position(room, player_id) do
      nil -> room
      pos -> %Room{room | positions: Map.put(positions, pos, nil)}
    end
  end

  # Private

  defp normalize_choice(nil), do: :auto
  defp normalize_choice(:auto), do: :auto
  defp normalize_choice(team) when team in [:north_south, :east_west], do: {:team, team}
  defp normalize_choice(pos) when pos in @positions, do: {:seat, pos}
  defp normalize_choice(_), do: :invalid

  defp do_assign(_room, _player_id, :invalid), do: {:error, :invalid_position}

  defp do_assign(%Room{} = room, player_id, :auto) do
    case available(room) do
      [pos | _] -> place(room, player_id, pos)
      [] -> {:error, :room_full}
    end
  end

  defp do_assign(%Room{} = room, player_id, {:team, team}) do
    case team_available(room, team) do
      [pos | _] -> place(room, player_id, pos)
      [] -> {:error, :team_full}
    end
  end

  defp do_assign(%Room{positions: positions} = room, player_id, {:seat, pos}) do
    if is_nil(positions[pos]) do
      place(room, player_id, pos)
    else
      {:error, :seat_taken}
    end
  end

  defp place(%Room{positions: positions} = room, player_id, pos) do
    {:ok, %Room{room | positions: Map.put(positions, pos, player_id)}, pos}
  end
end
```

### Success Criteria

- [ ] Module compiles: `mix compile --warnings-as-errors`
- [ ] All functions are pure (no side effects)
- [ ] Unit tests cover all cases

---

## Phase 2: Room Struct Changes

### Overview

Update Room struct to use `positions` as single source of truth. Remove `player_ids` as stored field.

### File: `lib/pidro_server/games/room_manager.ex`

**Changes to Room struct** (around line 52-97):

```elixir
defmodule Room do
  @moduledoc """
  Struct representing a game room.
  
  ## Single Source of Truth
  
  The `positions` map is the authoritative state for player seating.
  Use `Room.Positions.player_ids/1` to derive the player list.
  """

  @type position :: :north | :east | :south | :west
  @type positions_map :: %{position() => String.t() | nil}
  @type status :: :waiting | :ready | :playing | :finished | :closed

  @type t :: %__MODULE__{
          code: String.t(),
          host_id: String.t(),
          positions: positions_map(),
          spectator_ids: [String.t()],
          status: status(),
          max_players: non_neg_integer(),
          max_spectators: non_neg_integer(),
          created_at: DateTime.t(),
          metadata: map(),
          disconnected_players: %{String.t() => DateTime.t()},
          last_activity: DateTime.t()
        }

  defstruct [
    :code,
    :host_id,
    :status,
    :max_players,
    :created_at,
    :metadata,
    :last_activity,
    positions: %{north: nil, east: nil, south: nil, west: nil},
    spectator_ids: [],
    max_spectators: 10,
    disconnected_players: %{}
  ]
end
```

**Key change**: No `player_ids` field. It's derived via `Positions.player_ids/1`.

---

## Phase 3: Thin GenServer Handlers

### Overview

Refactor RoomManager handle_call functions to delegate to pure Positions module.

### File: `lib/pidro_server/games/room_manager.ex`

**Add alias at top**:
```elixir
alias PidroServer.Games.Room.Positions
```

**Update join_room/3 spec and function**:

```elixir
@doc """
Joins a player to a room with optional position selection.

## Examples

    # Explicit position
    {:ok, room, :east} = RoomManager.join_room("A1B2", "user456", :east)
    
    # Team selection
    {:ok, room, :south} = RoomManager.join_room("A1B2", "user456", :north_south)
    
    # Auto assignment
    {:ok, room, :east} = RoomManager.join_room("A1B2", "user456", nil)
"""
@spec join_room(String.t(), String.t(), Positions.choice()) ::
        {:ok, Room.t(), Positions.position()}
        | {:error, :room_not_found | :room_full | :already_in_room | :already_in_this_room 
           | :seat_taken | :team_full | :invalid_position | :room_not_available}
def join_room(room_code, player_id, position \\ nil) do
  GenServer.call(__MODULE__, {:join_room, String.upcase(room_code), player_id, position})
end

@impl true
def handle_call({:join_room, room_code, player_id, position}, _from, %State{} = state) do
  with {:ok, room} <- fetch_room(state, room_code),
       :ok <- ensure_not_in_other_room(state, player_id, room_code),
       :ok <- ensure_room_joinable(room),
       {:ok, updated_room, assigned_pos} <- Positions.assign(room, player_id, position) do
    
    final_room = 
      updated_room
      |> maybe_set_ready()
      |> touch_last_activity()

    new_state = put_room_and_player(state, final_room, player_id)

    Logger.info("Player #{player_id} joined room #{room_code} at #{assigned_pos}")
    broadcast_room(room_code, final_room)
    broadcast_lobby_event({:room_updated, final_room})

    final_state =
      if final_room.status == :ready do
        start_game_for_room(final_room, new_state)
      else
        new_state
      end

    {:reply, {:ok, final_room, assigned_pos}, final_state}
  else
    {:error, reason} -> {:reply, {:error, reason}, state}
  end
end

# Helper functions for thin GenServer

defp fetch_room(%State{rooms: rooms}, code) do
  case Map.get(rooms, code) do
    nil -> {:error, :room_not_found}
    room -> {:ok, room}
  end
end

defp ensure_not_in_other_room(%State{player_rooms: pr}, player_id, room_code) do
  case Map.get(pr, player_id) do
    nil -> :ok
    ^room_code -> {:error, :already_in_this_room}
    _other -> {:error, :already_in_room}
  end
end

defp ensure_room_joinable(%Room{status: status}) when status in [:waiting, :ready], do: :ok
defp ensure_room_joinable(_), do: {:error, :room_not_available}

defp maybe_set_ready(%Room{} = room) do
  if Positions.count(room) == @max_players do
    %Room{room | status: :ready}
  else
    room
  end
end

defp touch_last_activity(%Room{} = room) do
  %Room{room | last_activity: DateTime.utc_now()}
end

defp put_room_and_player(%State{} = state, %Room{code: code} = room, player_id) do
  %State{
    state
    | rooms: Map.put(state.rooms, code, room),
      player_rooms: Map.put(state.player_rooms, player_id, code)
  }
end
```

**Update create_room**:

```elixir
@impl true
def handle_call({:create_room, host_id, metadata}, _from, %State{} = state) do
  if Map.has_key?(state.player_rooms, host_id) do
    {:reply, {:error, :already_in_room}, state}
  else
    room_code = generate_room_code()
    now = DateTime.utc_now()

    room = %Room{
      code: room_code,
      host_id: host_id,
      positions: %{north: host_id, east: nil, south: nil, west: nil},
      status: :waiting,
      max_players: @max_players,
      created_at: now,
      last_activity: now,
      metadata: metadata
    }

    new_state = %State{
      state
      | rooms: Map.put(state.rooms, room_code, room),
        player_rooms: Map.put(state.player_rooms, host_id, room_code)
    }

    Logger.info("Room created: #{room_code} by host: #{host_id} at :north")
    broadcast_lobby_event({:room_created, room})

    {:reply, {:ok, room}, new_state}
  end
end
```

**Update leave_room**:

```elixir
@impl true
def handle_call({:leave_room, player_id}, _from, %State{} = state) do
  case Map.get(state.player_rooms, player_id) do
    nil ->
      {:reply, {:error, :not_in_room}, state}

    room_code ->
      room = state.rooms[room_code]

      if room.host_id == player_id do
        Logger.info("Host #{player_id} left room #{room_code}, closing room")
        {:reply, :ok, remove_room(state, room_code)}
      else
        updated_room = 
          room
          |> Positions.remove(player_id)
          |> Map.put(:status, :waiting)
          |> touch_last_activity()

        if Positions.count(updated_room) == 0 do
          Logger.info("Room #{room_code} is now empty, deleting")
          {:reply, :ok, remove_room(state, room_code)}
        else
          new_state = %State{
            state
            | rooms: Map.put(state.rooms, room_code, updated_room),
              player_rooms: Map.delete(state.player_rooms, player_id)
          }

          Logger.info("Player #{player_id} left room #{room_code}")
          broadcast_room(room_code, updated_room)
          broadcast_lobby_event({:room_updated, updated_room})

          {:reply, :ok, new_state}
        end
      end
  end
end
```

**Update remove_room**:

```elixir
defp remove_room(%State{} = state, room_code) do
  case Map.get(state.rooms, room_code) do
    nil -> state
    room ->
      updated_player_rooms =
        room
        |> Positions.player_ids()
        |> Enum.reduce(state.player_rooms, &Map.delete(&2, &1))

      broadcast_lobby_event({:room_closed, room})

      %State{
        state
        | rooms: Map.delete(state.rooms, room_code),
          player_rooms: updated_player_rooms
      }
  end
end
```

**Update disconnect timeout handler**:

```elixir
@impl true
def handle_info({:check_disconnect_timeout, room_code, user_id}, %State{} = state) do
  with {:ok, room} <- fetch_room(state, room_code),
       {:ok, disconnect_time} <- Map.fetch(room.disconnected_players, user_id),
       true <- grace_period_expired?(disconnect_time) do
    
    Logger.info("Player #{user_id} grace period expired, removing from #{room_code}")

    updated_room =
      room
      |> Positions.remove(user_id)
      |> Map.update!(:disconnected_players, &Map.delete(&1, user_id))

    new_state = %State{
      state
      | rooms: Map.put(state.rooms, room_code, updated_room),
        player_rooms: Map.delete(state.player_rooms, user_id)
    }

    broadcast_room(room_code, updated_room)
    broadcast_lobby_event({:room_updated, updated_room})

    {:noreply, new_state}
  else
    _ -> {:noreply, state}
  end
end

defp grace_period_expired?(disconnect_time) do
  DateTime.diff(DateTime.utc_now(), disconnect_time, :millisecond) >= get_grace_period_ms()
end
```

---

## Phase 4: Controller & Response Updates

### File: `lib/pidro_server_web/controllers/api/room_controller.ex`

**Update join action**:

```elixir
@spec join(Plug.Conn.t(), map()) :: Plug.Conn.t()
def join(conn, %{"code" => code} = params) do
  user = conn.assigns[:current_user]
  position = parse_position(params["position"])

  case RoomManager.join_room(code, user.id, position) do
    {:ok, room, assigned_position} ->
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room, assigned_position: assigned_position})

    {:error, reason} ->
      {:error, reason}
  end
end

defp parse_position(nil), do: nil
defp parse_position("north"), do: :north
defp parse_position("east"), do: :east
defp parse_position("south"), do: :south
defp parse_position("west"), do: :west
defp parse_position("north_south"), do: :north_south
defp parse_position("east_west"), do: :east_west
defp parse_position(_), do: nil
```

### File: `lib/pidro_server_web/controllers/api/room_json.ex`

**Update room serialization**:

```elixir
alias PidroServer.Games.Room.Positions

def room(%{room: room} = assigns) do
  %{
    code: room.code,
    host_id: room.host_id,
    positions: serialize_positions(room.positions),
    available_positions: Positions.available(room) |> Enum.map(&Atom.to_string/1),
    player_count: Positions.count(room),
    spectator_count: length(room.spectator_ids),
    status: room.status,
    max_players: room.max_players,
    max_spectators: room.max_spectators,
    created_at: room.created_at,
    metadata: room.metadata
  }
  |> maybe_add_assigned_position(assigns)
end

defp serialize_positions(positions) do
  positions
  |> Enum.map(fn {pos, id} -> {Atom.to_string(pos), id} end)
  |> Map.new()
end

defp maybe_add_assigned_position(data, %{assigned_position: pos}) when not is_nil(pos) do
  Map.put(data, :assigned_position, Atom.to_string(pos))
end
defp maybe_add_assigned_position(data, _), do: data
```

### File: `lib/pidro_server_web/controllers/api/fallback_controller.ex`

**Add error handlers with rich data**:

```elixir
def call(conn, {:error, :seat_taken}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "SEAT_TAKEN",
      title: "Seat taken",
      detail: "The requested position is already occupied"
    }]
  })
end

def call(conn, {:error, :team_full}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "TEAM_FULL",
      title: "Team full",
      detail: "The requested team has no available positions"
    }]
  })
end

def call(conn, {:error, :invalid_position}) do
  conn
  |> put_status(:unprocessable_entity)
  |> json(%{
    errors: [%{
      code: "INVALID_POSITION",
      title: "Invalid position",
      detail: "Position must be: north, east, south, west, north_south, or east_west"
    }]
  })
end
```

---

## Phase 5: GameChannel Integration

### File: `lib/pidro_server_web/channels/game_channel.ex`

**Update position lookup**:

```elixir
alias PidroServer.Games.Room.Positions

@spec get_player_position(Room.t(), String.t()) :: Positions.position()
defp get_player_position(room, user_id) do
  Positions.get_position(room, user_id) || :north
end
```

---

## Phase 6: Tests

### File: `test/pidro_server/games/room/positions_test.exs`

```elixir
defmodule PidroServer.Games.Room.PositionsTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.RoomManager.Room

  defp room_with_positions(positions) do
    %Room{
      code: "TEST",
      host_id: "host",
      positions: positions,
      status: :waiting,
      max_players: 4,
      created_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      metadata: %{}
    }
  end

  describe "available/1" do
    test "returns all positions when empty" do
      room = room_with_positions(Positions.empty())
      assert Positions.available(room) == [:north, :east, :south, :west]
    end

    test "excludes occupied positions" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert Positions.available(room) == [:east, :west]
    end
  end

  describe "assign/3" do
    test "assigns explicit position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      {:ok, updated, pos} = Positions.assign(room, "p2", :east)
      
      assert pos == :east
      assert updated.positions[:east] == "p2"
    end

    test "returns :seat_taken for occupied position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:error, :seat_taken} = Positions.assign(room, "p2", :north)
    end

    test "assigns team position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      {:ok, updated, pos} = Positions.assign(room, "p2", :north_south)
      
      assert pos == :south
      assert updated.positions[:south] == "p2"
    end

    test "returns :team_full when team occupied" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert {:error, :team_full} = Positions.assign(room, "p3", :north_south)
    end

    test "auto-assigns first available" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      {:ok, updated, pos} = Positions.assign(room, "p2", nil)
      
      assert pos == :east
      assert updated.positions[:east] == "p2"
    end

    test "returns :room_full when no positions available" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})
      assert {:error, :room_full} = Positions.assign(room, "p5", nil)
    end
  end

  describe "player_ids/1" do
    test "derives player list in canonical order" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p3", west: "p4"})
      assert Positions.player_ids(room) == ["p1", "p3", "p4"]
    end
  end

  describe "remove/2" do
    test "clears player position" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})
      updated = Positions.remove(room, "p2")
      
      assert updated.positions[:east] == nil
      assert updated.positions[:north] == "p1"
    end
  end
end
```

---

## Migration Notes

**No Database Migration Required**: Rooms exist only in GenServer memory.

**Call Site Updates**: Replace all `room.player_ids` with `Positions.player_ids(room)`.

**Backward Compatibility**: Clients sending no position parameter get auto-assignment.

---

## Verification Checklist

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix format --check-formatted`
- [ ] `mix dialyzer`
- [ ] `mix credo --strict`
- [ ] `mix test`
- [ ] Manual: Create room, verify host at :north
- [ ] Manual: Join with explicit position
- [ ] Manual: Join with team selection
- [ ] Manual: Quick join (auto)
- [ ] Manual: Concurrent joins handled
- [ ] Manual: WebSocket returns correct position
