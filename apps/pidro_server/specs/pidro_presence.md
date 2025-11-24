# Pidro Presence Strategy Specification

**Version**: 1.0  
**Date**: November 23, 2025  
**Author**: Claude  
**Status**: Ready for Implementation

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Server Implementation](#server-implementation)
4. [Mobile Client Implementation](#mobile-client-implementation)
5. [User Scenarios](#user-scenarios)
6. [Implementation Checklist](#implementation-checklist)
7. [Design Principles](#design-principles)

---

## Executive Summary

This document specifies a Phoenix Presence-based strategy for real-time player tracking, reconnection handling, and room lifecycle management in the Pidro multiplayer card game.

### Goals

- **Real-time player tracking** across lobby and games
- **Automatic reconnection** with 2-minute grace period
- **Live room updates** (player counts, status changes)
- **Graceful disconnection handling** without game disruption
- **Automatic cleanup** of abandoned rooms

### Key Design Decisions

- Use Phoenix Presence (CRDT-based, distributed by default)
- Track presence in 3 scopes: lobby, game rooms, RoomManager state
- 2-minute grace period for reconnections
- Client auto-rejoins last game on reconnect
- Server ~80% of complexity, client ~20%

---

## Architecture Overview

### User Journey Flow

```
User Opens App
    ↓
Connect Socket → Join "lobby" channel
    ↓
    ├─→ Browse rooms (tracked in lobby presence)
    ↓
Create/Join Game
    ↓
Join "game:{code}" channel → Track in room presence
    ↓
    ├─→ Play game (4 players present)
    ├─→ Disconnect → Grace period (2 min) → Rejoin
    └─→ Leave intentionally → Remove from presence
    ↓
Game Ends → Return to lobby
```

### Presence Tracking Scopes

```
┌─────────────────────────────────────────────────────────┐
│                     Phoenix Presence                    │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Topic: "lobby"                                         │
│  ├─ All connected users                                │
│  ├─ Metadata: {status, last_game_code}                 │
│  └─ Purpose: Track online users, show stats            │
│                                                         │
│  Topic: "game:{room_code}"                             │
│  ├─ Players in specific game room                      │
│  ├─ Metadata: {position, connection_id, online_at}    │
│  └─ Purpose: Track game participants, detect leaves    │
│                                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                     RoomManager State                    │
├─────────────────────────────────────────────────────────┤
│  Persistent room data:                                   │
│  ├─ player_ids: [user_id]                               │
│  ├─ disconnected_players: %{user_id => timestamp}       │
│  ├─ last_activity: DateTime                             │
│  └─ Purpose: Grace period tracking, room lifecycle      │
└─────────────────────────────────────────────────────────┘
```

### Data Flow

```
Player Action          Server Response               Client Update
─────────────────────────────────────────────────────────────────
Create Game       →    RoomManager.create_room
                       Broadcast "room_created"   → Lobby updates

Join Game         →    RoomManager.join_room
                       GameChannel.join
                       Presence.track             → "player_joined"

Disconnect        →    Presence.leave
                       Mark as disconnected       → "player_left"
                       Start grace period timer

Reconnect         →    GameChannel.join (rejoin)
                       Clear disconnected status  → "player_reconnected"
                       Presence.track (new pid)

Leave Game        →    RoomManager.leave_room
                       Presence.untrack           → "player_left"
                       Check if room empty        → Maybe delete room
```

---

## Server Implementation

### 1. Presence Module Setup

**File**: `lib/pidro_server_web/presence.ex` (already exists)

```elixir
defmodule PidroServerWeb.Presence do
  use Phoenix.Presence,
    otp_app: :pidro_server,
    pubsub_server: PidroServer.PubSub
end
```

**Metadata Structure**:

```elixir
# Lobby presence metadata
%{
  online_at: ~U[2025-11-23 10:30:00Z],
  status: :browsing | :in_game | :playing,
  last_game_code: "A3F9" | nil,
  connection_id: "phx-xyz123"
}

# Game room presence metadata
%{
  online_at: ~U[2025-11-23 10:30:00Z],
  position: :north | :south | :east | :west,
  status: :in_game,
  connection_id: "phx-xyz123"
}
```

---

### 2. LobbyChannel Implementation

**File**: `lib/pidro_server_web/channels/lobby_channel.ex`

```elixir
defmodule PidroServerWeb.LobbyChannel do
  use PidroServerWeb, :channel
  alias PidroServerWeb.Presence
  alias PidroServer.Games.RoomManager

  @impl true
  def join("lobby", _params, socket) do
    send(self(), :after_join)

    # Send current room list
    rooms = RoomManager.list_rooms()
    {:ok, %{rooms: rooms}, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track user in lobby presence
    {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{
      online_at: DateTime.utc_now(),
      status: :browsing,
      last_game_code: get_last_game_code(socket.assigns.user_id),
      connection_id: socket.id
    })

    # Push initial presence state
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    # Calculate and broadcast online user count
    online_count = Presence.list(socket) |> map_size()

    broadcast(socket, "lobby_stats", %{
      online_users: online_count,
      joins: map_size(diff.joins),
      leaves: map_size(diff.leaves)
    })

    {:noreply, socket}
  end

  # Helper to get last game code (could use Ecto or ETS)
  defp get_last_game_code(_user_id), do: nil
end
```

**Events Emitted**:

- `presence_state` - Initial presence list on join
- `lobby_stats` - Online user count and changes
- `room_created` - New room available (from RoomManager)
- `room_updated` - Room player count changed
- `room_closed` - Room deleted

---

### 3. GameChannel Implementation

**File**: `lib/pidro_server_web/channels/game_channel.ex`

```elixir
defmodule PidroServerWeb.GameChannel do
  use PidroServerWeb, :channel
  alias PidroServerWeb.Presence
  alias PidroServer.Games.{RoomManager, GameAdapter}

  @impl true
  def join("game:" <> room_code, _params, socket) do
    user_id = socket.assigns.user_id

    with {:ok, room} <- RoomManager.get_room(room_code),
         true <- user_id in room.player_ids,
         {:ok, _pid} <- GameAdapter.get_game(room_code) do

      # Get player position
      position = get_player_position(room, user_id)

      # Assign to socket
      socket = socket
        |> assign(:room_code, room_code)
        |> assign(:position, position)

      # Track presence after successful join
      send(self(), :after_join)

      # Subscribe to game state updates
      :ok = GameAdapter.subscribe(room_code)

      # Detect reconnection
      was_disconnected = Map.has_key?(room.disconnected_players, user_id)

      if was_disconnected do
        # Clear disconnected status
        :ok = RoomManager.player_reconnected(room_code, user_id)

        # Notify others of reconnection
        broadcast_from(socket, "player_reconnected", %{
          user_id: user_id,
          position: position,
          reconnected_at: DateTime.utc_now()
        })
      end

      # Get current game state
      state = GameAdapter.get_state(room_code)

      {:ok, %{state: state, position: position, reconnected: was_disconnected}, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    room_code = socket.assigns.room_code
    user_id = socket.assigns.user_id
    position = socket.assigns.position

    # Track presence with metadata
    {:ok, _} = Presence.track(socket, user_id, %{
      online_at: DateTime.utc_now(),
      position: position,
      status: :in_game,
      connection_id: socket.id
    })

    # Broadcast updated player list
    broadcast_player_presence(socket)

    # Check if room is now ready to start
    check_room_ready(room_code)

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    room_code = socket.assigns.room_code
    user_id = socket.assigns.user_id

    # Mark player as disconnected (with grace period)
    :ok = RoomManager.player_disconnected(room_code, user_id)

    # Note: Presence.untrack is automatic on process termination
    # Presence diff will trigger and broadcast "player_left"

    :ok
  end

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    # Handle joins
    for {user_id, %{metas: [meta | _]}} <- diff.joins do
      broadcast(socket, "player_joined", %{
        user_id: user_id,
        position: meta.position,
        online_at: meta.online_at
      })
    end

    # Handle leaves
    for {user_id, _meta} <- diff.leaves do
      broadcast(socket, "player_left", %{
        user_id: user_id,
        left_at: DateTime.utc_now()
      })
    end

    # Update room status based on presence
    update_room_status(socket.assigns.room_code)

    {:noreply, socket}
  end

  # Existing game action handlers (bid, play_card, etc.)
  # ... (already implemented)

  # Private helpers

  defp broadcast_player_presence(socket) do
    room_code = socket.assigns.room_code
    presences = Presence.list("game:#{room_code}")

    players = Enum.map(presences, fn {user_id, %{metas: [meta | _]}} ->
      %{
        user_id: user_id,
        position: meta.position,
        online: true,
        online_at: meta.online_at
      }
    end)

    broadcast(socket, "players_updated", %{
      players: players,
      count: length(players)
    })
  end

  defp check_room_ready(room_code) do
    presences = Presence.list("game:#{room_code}")

    if map_size(presences) == 4 do
      # All 4 players present
      :ok = RoomManager.update_room_status(room_code, :ready)

      # Broadcast ready status
      PidroServerWeb.Endpoint.broadcast("game:#{room_code}", "room_ready", %{
        room_code: room_code
      })
    end
  end

  defp update_room_status(room_code) do
    presences = Presence.list("game:#{room_code}")
    player_count = map_size(presences)

    status = cond do
      player_count == 0 -> :abandoned
      player_count < 4 -> :waiting
      player_count == 4 -> :ready
      true -> :waiting
    end

    :ok = RoomManager.update_room_status(room_code, status)
  end

  defp get_player_position(room, user_id) do
    positions = [:north, :south, :east, :west]
    index = Enum.find_index(room.player_ids, &(&1 == user_id))
    Enum.at(positions, index || 0)
  end
end
```

**Events Emitted**:

- `presence_state` - Initial player list
- `presence_diff` - Player joins/leaves (automatic)
- `players_updated` - Full player list with positions
- `player_joined` - Individual player join
- `player_left` - Individual player leave
- `player_reconnected` - Player rejoined after disconnect
- `room_ready` - All 4 players present

---

### 4. RoomManager Enhancements

**File**: `lib/pidro_server/games/room_manager.ex`

**Updates to Room struct**:

```elixir
defmodule Room do
  use TypedStruct

  typedstruct do
    # Existing fields...
    field :code, String.t(), enforce: true
    field :host_id, String.t(), enforce: true
    field :player_ids, [String.t()], default: []
    field :status, atom(), default: :waiting

    # New fields for presence tracking
    field :disconnected_players, %{String.t() => DateTime.t()}, default: %{}
    field :last_activity, DateTime.t()
  end
end
```

**New public API functions**:

```elixir
@spec player_disconnected(String.t(), String.t()) :: :ok | {:error, atom()}
def player_disconnected(room_code, user_id) do
  GenServer.call(__MODULE__, {:player_disconnected, room_code, user_id})
end

@spec player_reconnected(String.t(), String.t()) :: :ok | {:error, atom()}
def player_reconnected(room_code, user_id) do
  GenServer.call(__MODULE__, {:player_reconnected, room_code, user_id})
end

@spec update_room_status(String.t(), atom()) :: :ok | {:error, atom()}
def update_room_status(room_code, status) do
  GenServer.call(__MODULE__, {:update_room_status, room_code, status})
end
```

**GenServer callbacks**:

```elixir
@impl true
def handle_call({:player_disconnected, room_code, user_id}, _from, state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, {:error, :room_not_found}, state}

    room ->
      # Mark player as disconnected with timestamp
      disconnected_players = Map.put(
        room.disconnected_players,
        user_id,
        DateTime.utc_now()
      )

      updated_room = %{room |
        disconnected_players: disconnected_players,
        last_activity: DateTime.utc_now()
      }

      updated_state = put_in(state.rooms[room_code], updated_room)

      # Broadcast room update
      broadcast_room_update(updated_room)

      # Schedule cleanup after grace period (2 minutes)
      Process.send_after(
        self(),
        {:cleanup_disconnected_player, room_code, user_id},
        :timer.minutes(2)
      )

      {:reply, :ok, updated_state}
  end
end

@impl true
def handle_call({:player_reconnected, room_code, user_id}, _from, state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, {:error, :room_not_found}, state}

    room ->
      # Remove from disconnected list
      disconnected_players = Map.delete(room.disconnected_players, user_id)

      updated_room = %{room |
        disconnected_players: disconnected_players,
        last_activity: DateTime.utc_now()
      }

      updated_state = put_in(state.rooms[room_code], updated_room)

      # Broadcast room update
      broadcast_room_update(updated_room)

      {:reply, :ok, updated_state}
  end
end

@impl true
def handle_call({:update_room_status, room_code, status}, _from, state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:reply, {:error, :room_not_found}, state}

    room ->
      updated_room = %{room |
        status: status,
        last_activity: DateTime.utc_now()
      }

      updated_state = put_in(state.rooms[room_code], updated_room)

      # Broadcast room update
      broadcast_room_update(updated_room)

      {:reply, :ok, updated_state}
  end
end

@impl true
def handle_info({:cleanup_disconnected_player, room_code, user_id}, state) do
  case Map.get(state.rooms, room_code) do
    nil ->
      {:noreply, state}

    room ->
      # Check if player is still disconnected
      disconnect_time = Map.get(room.disconnected_players, user_id)

      if disconnect_time do
        now = DateTime.utc_now()
        grace_period_seconds = 120  # 2 minutes

        if DateTime.diff(now, disconnect_time) >= grace_period_seconds do
          # Grace period expired, remove player
          updated_room = remove_player_from_room(room, user_id)
          updated_state = put_in(state.rooms[room_code], updated_room)

          # Broadcast player removal
          broadcast_room_update(updated_room)

          # Check if room is now empty
          if Enum.empty?(updated_room.player_ids) do
            delete_room_internal(room_code, updated_state)
          else
            {:noreply, updated_state}
          end
        else
          # Still within grace period, player might have reconnected
          {:noreply, state}
        end
      else
        # Player already reconnected
        {:noreply, state}
      end
  end
end

# Periodic cleanup of abandoned rooms
@impl true
def handle_info(:cleanup_abandoned_rooms, state) do
  now = DateTime.utc_now()
  grace_period_minutes = 5

  # Find abandoned rooms (no presence, no activity)
  abandoned_rooms = state.rooms
  |> Enum.filter(fn {code, room} ->
    room.status == :waiting &&
    DateTime.diff(now, room.last_activity, :minute) > grace_period_minutes &&
    map_size(Presence.list("game:#{code}")) == 0
  end)
  |> Enum.map(fn {code, _room} -> code end)

  # Delete abandoned rooms
  updated_state = Enum.reduce(abandoned_rooms, state, fn code, acc_state ->
    delete_room_internal(code, acc_state)
  end)

  # Schedule next cleanup
  Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))

  {:noreply, updated_state}
end

# Private helpers

defp remove_player_from_room(room, user_id) do
  %{room |
    player_ids: List.delete(room.player_ids, user_id),
    disconnected_players: Map.delete(room.disconnected_players, user_id)
  }
end

defp delete_room_internal(room_code, state) do
  # Remove from state
  updated_rooms = Map.delete(state.rooms, room_code)

  # Broadcast room closed
  PidroServerWeb.Endpoint.broadcast("lobby:updates", "room_closed", %{
    room_code: room_code
  })

  %{state | rooms: updated_rooms}
end

defp broadcast_room_update(room) do
  # Broadcast to lobby
  PidroServerWeb.Endpoint.broadcast("lobby:updates", "room_updated", %{
    room: serialize_room(room)
  })
end

defp serialize_room(room) do
  %{
    code: room.code,
    host_id: room.host_id,
    player_count: length(room.player_ids),
    status: room.status,
    disconnected_count: map_size(room.disconnected_players)
  }
end
```

**Initialize cleanup task in init**:

```elixir
@impl true
def init(_arg) do
  # Start periodic cleanup
  Process.send_after(self(), :cleanup_abandoned_rooms, :timer.minutes(1))

  {:ok, %{
    rooms: %{},
    player_rooms: %{}
  }}
end
```

---

## Mobile Client Implementation

### 1. Socket Connection Management

**File**: `src/channels/socket.ts`

```typescript
import { Socket } from "phoenix";
import { Platform } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useAuthStore } from "@/stores/auth";
import { router } from "expo-router";

const SOCKET_URL = __DEV__
  ? Platform.select({
      ios: "ws://localhost:4000/socket",
      android: "ws://10.0.2.2:4000/socket",
      default: "ws://localhost:4000/socket",
    })
  : "wss://api.pidro.app/socket";

class PhoenixSocket {
  private socket: Socket | null = null;
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 10;

  connect() {
    if (this.socket) return this.socket;

    const token = useAuthStore.getState().token;

    this.socket = new Socket(SOCKET_URL, {
      params: { token },
      logger: __DEV__ ? console.log : undefined,
      reconnectAfterMs: (tries) => {
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, max 30s
        return Math.min(1000 * Math.pow(2, tries), 30000);
      },
    });

    // Connection event handlers
    this.socket.onOpen(() => {
      console.log("📌 Socket connected");
      this.reconnectAttempts = 0;

      // Attempt to rejoin last game
      this.rejoinLastGame();
    });

    this.socket.onError((error) => {
      console.error("❌ Socket error:", error);
      this.reconnectAttempts++;

      if (this.reconnectAttempts >= this.maxReconnectAttempts) {
        // Show error to user
        console.error("Max reconnection attempts reached");
        // Could trigger a toast/alert here
      }
    });

    this.socket.onClose(() => {
      console.log("📌 Socket closed");
    });

    this.socket.connect();

    return this.socket;
  }

  disconnect() {
    if (this.socket) {
      this.socket.disconnect();
      this.socket = null;
    }
  }

  getSocket() {
    return this.socket || this.connect();
  }

  private async rejoinLastGame() {
    try {
      // Check if user was in a game when disconnected
      const lastGameCode = await AsyncStorage.getItem("last_game_code");
      const lastPosition = await AsyncStorage.getItem("last_position");

      if (lastGameCode && lastPosition) {
        console.log(`🔄 Attempting to rejoin game: ${lastGameCode}`);

        // Navigate back to game screen
        router.replace(`/game/${lastGameCode}`);
      }
    } catch (error) {
      console.error("Error rejoining last game:", error);
    }
  }
}

export const phoenixSocket = new PhoenixSocket();
```

---

### 2. Game Channel Hook

**File**: `src/channels/hooks/useGameChannel.ts`

```typescript
import { useEffect, useState, useCallback } from "react";
import { Channel } from "phoenix";
import { phoenixSocket } from "../socket";
import AsyncStorage from "@react-native-async-storage/async-storage";
import type { GameState, GameAction, Player } from "@/types/game";

export function useGameChannel(roomCode: string) {
  const [channel, setChannel] = useState<Channel | null>(null);
  const [gameState, setGameState] = useState<GameState | null>(null);
  const [players, setPlayers] = useState<Player[]>([]);
  const [isConnected, setIsConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [wasReconnected, setWasReconnected] = useState(false);

  useEffect(() => {
    const socket = phoenixSocket.getSocket();
    const gameChannel = socket.channel(`game:${roomCode}`);

    // Join channel
    gameChannel
      .join()
      .receive("ok", (response) => {
        console.log("✅ Joined game channel", response);
        setGameState(response.state);
        setIsConnected(true);
        setWasReconnected(response.reconnected || false);

        // Save current game for reconnection
        AsyncStorage.setItem("last_game_code", roomCode);
        AsyncStorage.setItem("last_position", response.position);
      })
      .receive("error", (err) => {
        console.error("❌ Failed to join channel", err);
        setError(err.reason || "Failed to join game");
        setIsConnected(false);
      });

    // Game state updates
    gameChannel.on("game_state", (payload) => {
      setGameState(payload.state);
    });

    // Player presence events
    gameChannel.on("players_updated", (payload) => {
      setPlayers(payload.players);
    });

    gameChannel.on("player_joined", (payload) => {
      console.log("Player joined:", payload);
      // Could show toast notification
    });

    gameChannel.on("player_left", (payload) => {
      console.log("Player left:", payload);
      setPlayers((prev) =>
        prev.map((p) =>
          p.user_id === payload.user_id ? { ...p, online: false } : p
        )
      );
    });

    gameChannel.on("player_reconnected", (payload) => {
      console.log("Player reconnected:", payload);
      setPlayers((prev) =>
        prev.map((p) =>
          p.user_id === payload.user_id ? { ...p, online: true } : p
        )
      );
    });

    // Room ready event
    gameChannel.on("room_ready", (payload) => {
      console.log("Room ready:", payload);
      // Could trigger UI update or sound
    });

    // Turn changed
    gameChannel.on("turn_changed", (payload) => {
      console.log("Turn changed:", payload);
    });

    // Game over
    gameChannel.on("game_over", (payload) => {
      console.log("Game over:", payload);
      // Clear saved game
      AsyncStorage.removeItem("last_game_code");
      AsyncStorage.removeItem("last_position");
    });

    setChannel(gameChannel);

    // Cleanup on unmount
    return () => {
      gameChannel.leave();
      setChannel(null);
      setIsConnected(false);
    };
  }, [roomCode]);

  // Send game action
  const sendAction = useCallback(
    (action: GameAction) => {
      if (!channel) {
        console.error("Channel not connected");
        return Promise.reject("Not connected");
      }

      return new Promise((resolve, reject) => {
        channel
          .push(action.type, action.payload)
          .receive("ok", (response) => resolve(response))
          .receive("error", (err) => reject(err));
      });
    },
    [channel]
  );

  return {
    gameState,
    players,
    isConnected,
    error,
    wasReconnected,
    sendAction,
  };
}
```

---

### 3. Lobby Channel Hook

**File**: `src/channels/hooks/useLobbyChannel.ts`

```typescript
import { useEffect, useState } from "react";
import { Channel } from "phoenix";
import { phoenixSocket } from "../socket";
import type { Room } from "@/types/game";

export function useLobbyChannel() {
  const [channel, setChannel] = useState<Channel | null>(null);
  const [rooms, setRooms] = useState<Room[]>([]);
  const [onlineCount, setOnlineCount] = useState(0);
  const [isConnected, setIsConnected] = useState(false);

  useEffect(() => {
    const socket = phoenixSocket.getSocket();
    const lobbyChannel = socket.channel("lobby");

    lobbyChannel
      .join()
      .receive("ok", (response) => {
        console.log("✅ Joined lobby", response);
        setRooms(response.rooms || []);
        setIsConnected(true);
      })
      .receive("error", (err) => {
        console.error("❌ Failed to join lobby", err);
        setIsConnected(false);
      });

    // Listen for lobby stats
    lobbyChannel.on("lobby_stats", (payload) => {
      setOnlineCount(payload.online_users);
    });

    // Room events
    lobbyChannel.on("room_created", (payload) => {
      setRooms((prev) => [...prev, payload.room]);
    });

    lobbyChannel.on("room_updated", (payload) => {
      setRooms((prev) =>
        prev.map((r) => (r.code === payload.room.code ? payload.room : r))
      );
    });

    lobbyChannel.on("room_closed", (payload) => {
      setRooms((prev) => prev.filter((r) => r.code !== payload.room_code));
    });

    setChannel(lobbyChannel);

    return () => {
      lobbyChannel.leave();
      setChannel(null);
      setIsConnected(false);
    };
  }, []);

  return {
    rooms,
    onlineCount,
    isConnected,
  };
}
```

---

### 4. Game Screen UI

**File**: `app/game/[code].tsx`

```typescript
import { useEffect, useState } from "react";
import { View, Text } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { useGameChannel } from "@/channels/hooks/useGameChannel";
import { CardTable } from "@/components/game/CardTable";
import { PlayerList } from "@/components/game/PlayerList";

export default function GameScreen() {
  const { code } = useLocalSearchParams<{ code: string }>();
  const { gameState, players, isConnected, wasReconnected, sendAction } =
    useGameChannel(code);

  return (
    <View className="flex-1 bg-green-800">
      {/* Connection status banner */}
      {!isConnected && (
        <View className="bg-yellow-500 p-2">
          <Text className="text-center text-white font-semibold">
            🔄 Reconnecting...
          </Text>
        </View>
      )}

      {wasReconnected && (
        <View className="bg-green-500 p-2">
          <Text className="text-center text-white font-semibold">
            ✅ Reconnected successfully
          </Text>
        </View>
      )}

      {/* Player status list */}
      <PlayerList players={players} />

      {/* Game table */}
      {gameState && (
        <CardTable
          gameState={gameState}
          onCardPlay={(card) =>
            sendAction({ type: "play_card", payload: { card } })
          }
        />
      )}
    </View>
  );
}
```

---

### 5. Lobby Screen UI

**File**: `app/(tabs)/index.tsx`

```typescript
import { View, Text, FlatList } from "react-native";
import { useLobbyChannel } from "@/channels/hooks/useLobbyChannel";
import { RoomCard } from "@/components/lobby/RoomCard";

export default function LobbyScreen() {
  const { rooms, onlineCount, isConnected } = useLobbyChannel();

  return (
    <View className="flex-1 bg-white p-4">
      {/* Header with online count */}
      <View className="flex-row justify-between items-center mb-4">
        <Text className="text-2xl font-bold">Games</Text>
        <View className="flex-row items-center">
          <View className="w-2 h-2 rounded-full bg-green-500 mr-2" />
          <Text className="text-gray-600">{onlineCount} online</Text>
        </View>
      </View>

      {/* Room list */}
      <FlatList
        data={rooms}
        keyExtractor={(room) => room.code}
        renderItem={({ item }) => (
          <RoomCard
            room={item}
            onlineCount={item.player_count - item.disconnected_count}
          />
        )}
        ListEmptyComponent={
          <Text className="text-center text-gray-500 mt-8">
            No games available. Create one!
          </Text>
        }
      />
    </View>
  );
}
```

---

## User Scenarios

### Scenario 1: User Creates Game

```
User Action                Server Response                   Client Update
───────────────────────────────────────────────────────────────────────────
1. Tap "Create Game"   →   POST /api/v1/rooms
                           RoomManager.create_room
                           Broadcast "room_created"      →  Lobby list updates

2. Navigate to game    →   Join "game:{code}" channel
                           Presence.track               →  Track in presence
                           Send initial state

3. Wait for players    →   (Socket idle, presence tracked)  "Waiting for players (1/4)"
```

### Scenario 2: Players Join

```
User Action                Server Response                   Client Update
───────────────────────────────────────────────────────────────────────────
1. Tap "Join Game"     →   POST /api/v1/rooms/{code}/join
                           RoomManager.join_room

2. Navigate to game    →   Join "game:{code}" channel
                           Presence.track               →  "player_joined" broadcast

3. All clients update  ←   Presence diff triggered      →  "Marcel's Game (2/4)"

4. 4th player joins    →   Presence: 4 players
                           Check room ready             →  "room_ready" broadcast
                           Status: waiting → ready      →  All clients: "Ready to start!"
```

### Scenario 3: Player Disconnects (Network Drop)

```
Event                      Server Response                   Client Update
───────────────────────────────────────────────────────────────────────────
1. Connection lost         GameChannel.terminate/2
                           RoomManager.player_disconnected
                           Presence.untrack (automatic)

2. Presence diff       →   "player_left" broadcast      →  "Player 3 (South) disconnected"
                           Mark in disconnected_players     Show gray/offline indicator

3. Grace period starts     Schedule cleanup (2 minutes)

4. Within 2 min:
   - Reconnect         →   GameChannel.join (detected)
                           Clear disconnected status    →  "player_reconnected" broadcast
                           Presence.track (new pid)        "Player 3 reconnected!"

5. After 2 min:
   - Still offline     →   Remove from player_ids       →  "Player 3 removed from game"
                           Game may end or continue        Potentially end game
```

### Scenario 4: Player Reconnects

```
User Action                Server Response                   Client Update
───────────────────────────────────────────────────────────────────────────
1. Reopen app          →   Socket.onOpen()
                           Check AsyncStorage
                           last_game_code found         →  Auto-navigate to /game/{code}

2. Join game channel   →   GameChannel.join
                           Detect: user in disconnected_players
                           Clear disconnected status    →  Response: reconnected: true
                           Presence.track

3. Others notified     ←   "player_reconnected"         →  All clients: "Player 3 back!"

4. Game state sent     ←   Current game state           →  Restore UI, continue playing
```

### Scenario 5: Empty Room Cleanup

```
Event                      Server Response                   Client Update
───────────────────────────────────────────────────────────────────────────
1. Last player leaves      Presence.list("game:{code}") → empty
                           Last activity timestamp recorded

2. Cleanup task runs       Every 1 minute, check:
   (1 min later)           - status == :waiting
                           - last_activity > 5 min ago
                           - Presence count == 0

3. Delete room         →   RoomManager.delete_room
                           Broadcast "room_closed"      →  Lobby: Room disappears
```

---

## Implementation Checklist

### Server (Phoenix) - ~80% of work

#### Phase 1: Presence Foundation

- [ ] **LobbyChannel presence tracking**
  - [ ] Add `:after_join` handler to track presence
  - [ ] Handle `presence_diff` events
  - [ ] Broadcast `lobby_stats` with online count
  - [ ] Test: Join lobby, see online count

#### Phase 2: GameChannel presence (CRITICAL)

- [ ] **Track players in game rooms**
  - [ ] Add `:after_join` handler in GameChannel
  - [ ] Track with position metadata
  - [ ] Broadcast `players_updated` on presence changes
  - [ ] Test: Join game, see player list
- [ ] **Detect disconnections**
  - [ ] Implement `terminate/2` callback
  - [ ] Call `RoomManager.player_disconnected/2`
  - [ ] Handle `presence_diff` for leaves
  - [ ] Test: Close app, see "player left"
- [ ] **Detect reconnections**
  - [ ] Check `room.disconnected_players` in join/3
  - [ ] Call `RoomManager.player_reconnected/2`
  - [ ] Broadcast `player_reconnected`
  - [ ] Test: Reopen app, see "reconnected"

#### Phase 3: RoomManager enhancements

- [ ] **Add presence-related fields**
  - [ ] Add `disconnected_players` to Room struct
  - [ ] Add `last_activity` timestamp
  - [ ] Migrate existing code
- [ ] **Implement disconnection tracking**
  - [ ] `player_disconnected/2` function
  - [ ] Schedule cleanup after 2 minutes
  - [ ] `player_reconnected/2` function
  - [ ] Test: Disconnect → wait → auto-remove
- [ ] **Periodic cleanup task**
  - [ ] Add `cleanup_abandoned_rooms` handler
  - [ ] Check for empty rooms with no activity
  - [ ] Delete and broadcast "room_closed"
  - [ ] Test: Leave room, wait 5 min, room deleted
- [ ] **Room status updates**
  - [ ] `update_room_status/2` function
  - [ ] Check presence count for :ready status
  - [ ] Broadcast status changes
  - [ ] Test: 4 players join → status :ready

#### Phase 4: Testing

- [ ] **Unit tests**
  - [ ] RoomManager presence functions
  - [ ] Room cleanup logic
  - [ ] Disconnection grace period
- [ ] **Integration tests**
  - [ ] GameChannel join with presence
  - [ ] LobbyChannel presence tracking
  - [ ] Reconnection flow
  - [ ] Room deletion on empty

---

### Mobile Client - ~20% of work

#### Phase 1: Socket management

- [ ] **Connection handling**
  - [ ] Implement exponential backoff
  - [ ] Add `onOpen` handler
  - [ ] Add `onError` handler with retry logic
  - [ ] Test: Start app, see connection
- [ ] **Reconnection logic**
  - [ ] Save `last_game_code` to AsyncStorage
  - [ ] Implement `rejoinLastGame()` method
  - [ ] Call on `socket.onOpen()`
  - [ ] Test: Close app, reopen, auto-rejoin

#### Phase 2: Game screen

- [ ] **Listen for presence events**
  - [ ] `players_updated` event
  - [ ] `player_joined` event
  - [ ] `player_left` event
  - [ ] `player_reconnected` event
  - [ ] Test: See live player list
- [ ] **UI indicators**
  - [ ] Show online/offline status per player
  - [ ] Display "Reconnecting..." banner
  - [ ] Display "Reconnected!" banner
  - [ ] Show player count (X/4)
  - [ ] Test: Visual feedback on disconnect/reconnect
- [ ] **Save/restore state**
  - [ ] Save `last_game_code` on join
  - [ ] Save `last_position` on join
  - [ ] Clear on intentional leave
  - [ ] Test: Rejoin after app close

#### Phase 3: Lobby screen

- [ ] **Display presence data**
  - [ ] Show online user count
  - [ ] Show player count per room
  - [ ] Show disconnected player count
  - [ ] Update live on room changes
  - [ ] Test: See live room updates

#### Phase 4: Testing

- [ ] **Manual testing**
  - [ ] Create game → see in lobby
  - [ ] Join game → see player list
  - [ ] Close app → see disconnect
  - [ ] Reopen app → auto-rejoin
  - [ ] Wait 2 min → removed from game
- [ ] **Edge cases**
  - [ ] All 4 players disconnect → room deleted
  - [ ] Disconnect during bidding
  - [ ] Disconnect during playing
  - [ ] Multiple reconnects

---

## Design Principles

### Why This Makes Dave Thomas Proud

1. **Leverage OTP primitives**

   - Phoenix.Presence built on CRDT (conflict-free replicated data types)
   - Fully distributed, no single point of failure
   - Built-in eventual consistency

2. **Let it crash**

   - Channel process crashes? Presence automatically untracks
   - GameServer crashes? Room lifecycle handles it
   - Network drops? Grace period and reconnection

3. **Immutable state**

   - Presence metadata is immutable maps
   - Room struct updates via pattern matching
   - No hidden mutations, easy to reason about

4. **Small, focused functions**

   - Each callback does one thing
   - Pure functions where possible
   - Clear separation of concerns

5. **Pattern matching**

   - Presence diff handling via pattern matching
   - Room status transitions
   - Player position assignment

6. **Supervised processes**

   - Everything supervised
   - Self-healing architecture
   - Fault isolation (game crash ≠ server crash)

7. **No clever hacks**
   - Straightforward, idiomatic Elixir
   - Standard Phoenix patterns
   - Simple mobile client (just listen and react)

---

## Benefits of This Architecture

### Reliability

- ✅ Handles network drops gracefully
- ✅ Automatic reconnection with exponential backoff
- ✅ Grace period prevents accidental game disruption
- ✅ Eventual consistency via Presence CRDT

### Performance

- ✅ Minimal server state (Presence handles tracking)
- ✅ Efficient PubSub broadcasts (only to relevant subscribers)
- ✅ Client-side caching (gameState, players)
- ✅ Fast reconnection (just rejoin channel)

### User Experience

- ✅ Live player updates (no polling)
- ✅ Clear connection status indicators
- ✅ Seamless reconnection (auto-rejoin last game)
- ✅ No lost games due to temporary disconnects

### Developer Experience

- ✅ Server handles complexity (where it belongs)
- ✅ Client just listens and reacts (simple hooks)
- ✅ Testable (mocked channels, unit tests)
- ✅ Observable (presence lists, PubSub broadcasts)

### Scalability

- ✅ Horizontal scaling ready (Presence is distributed)
- ✅ No shared state bottlenecks
- ✅ Per-game process isolation
- ✅ Automatic cleanup (no memory leaks)

---

## Next Steps

1. **Implement Phase 1** (LobbyChannel presence)

   - Estimated: 2-3 hours
   - Test with multiple clients

2. **Implement Phase 2** (GameChannel presence - CRITICAL)

   - Estimated: 4-6 hours
   - Test disconnect/reconnect scenarios

3. **Implement Phase 3** (RoomManager enhancements)

   - Estimated: 3-4 hours
   - Test grace period and cleanup

4. **Implement Client** (Mobile hooks and UI)

   - Estimated: 4-6 hours
   - Test end-to-end user flows

5. **Testing & Polish**
   - Estimated: 4-6 hours
   - Edge cases, error handling, UX polish

**Total Estimated Effort**: 17-25 hours

---

## Appendix

### Useful Commands

```bash
# Server: Inspect Presence
iex> Presence.list("lobby") |> Map.keys()
["user-123", "user-456"]

iex> Presence.list("game:A3F9")
%{
  "user-123" => %{
    metas: [%{position: :north, online_at: ~U[...]}]
  }
}

# Server: Inspect RoomManager
iex> RoomManager.get_room("A3F9")
{:ok, %Room{
  code: "A3F9",
  disconnected_players: %{"user-789" => ~U[...]},
  ...
}}

# Client: Check AsyncStorage
await AsyncStorage.getItem('last_game_code')
// "A3F9"
```

### References

- [Phoenix Presence Guide](https://hexdocs.pm/phoenix/presence.html)
- [Phoenix Channels Documentation](https://hexdocs.pm/phoenix/channels.html)
- [Phoenix.js Client](https://hexdocs.pm/phoenix/js/)
- [React Native AsyncStorage](https://react-native-async-storage.github.io/async-storage/)

---

**End of Specification**

Ready to build a bulletproof presence system! 🚀🎮🃏
