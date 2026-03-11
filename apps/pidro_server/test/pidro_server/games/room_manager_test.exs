defmodule PidroServer.Games.RoomManagerTest do
  @moduledoc """
  Comprehensive tests for RoomManager including reconnection functionality.

  Tests cover:
  - Basic room management (create, join, leave)
  - Player disconnect handling
  - Reconnection within grace period
  - Grace period expiration and automatic cleanup
  - Multiple concurrent disconnections
  - Edge cases and error handling
  """

  use ExUnit.Case, async: false
  require Logger

  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}
  alias PidroServer.Games.Room.Positions

  # Note: async: false is required because RoomManager is a singleton GenServer

  setup do
    # Start the RoomManager if not already started
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    # Reset state between tests
    RoomManager.reset_for_test()

    :ok
  end

  describe "create_room/2" do
    test "creates a new room with host as first player" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test Room"})

      assert room.code != nil
      assert String.length(room.code) == 4
      assert room.host_id == "user1"
      assert Positions.player_ids(room) == ["user1"]
      assert room.status == :waiting
      assert room.max_players == 4
      assert room.metadata.name == "Test Room"
    end

    test "prevents creating room if already in another room" do
      {:ok, _room} = RoomManager.create_room("user1", %{})

      assert {:error, :already_in_room} = RoomManager.create_room("user1", %{})
    end

    test "generates unique room codes" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      assert room1.code != room2.code
    end
  end

  describe "join_room/2" do
    test "allows player to join existing room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, updated_room, _} = RoomManager.join_room(room.code, "user2")

      assert Positions.has_player?(updated_room, "user1") &&
               Positions.has_player?(updated_room, "user2") && Positions.count(updated_room) == 2

      assert updated_room.status == :waiting
    end

    test "prevents player from joining if already in another room" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      {:ok, _, _} = RoomManager.join_room(room1.code, "user3")

      assert {:error, :already_in_room} = RoomManager.join_room(room2.code, "user3")
    end

    test "prevents joining non-existent room" do
      assert {:error, :room_not_found} = RoomManager.join_room("ZZZZ", "user1")
    end

    test "prevents joining full room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      # When 4th player joins, room becomes :ready/:playing, so returns :room_not_available
      assert {:error, :room_not_available} = RoomManager.join_room(room.code, "user5")
    end

    test "changes status to ready when 4th player joins" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, final_room, _} = RoomManager.join_room(room.code, "user4")

      assert final_room.status == :ready
      assert Positions.count(final_room) == 4
    end

    test "handles case-insensitive room codes" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      lowercase_code = String.downcase(room.code)

      {:ok, updated_room, _} = RoomManager.join_room(lowercase_code, "user2")

      assert updated_room.code == room.code
    end
  end

  describe "leave_room/1" do
    test "removes player from room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.leave_room("user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.player_ids(updated_room) == ["user1"]
      assert Positions.count(updated_room) == 1
    end

    test "closes room when host leaves" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "deletes room when last player leaves" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "returns error when player not in room" do
      assert {:error, :not_in_room} = RoomManager.leave_room("nonexistent")
    end

    test "changes status back to waiting when player leaves from ready room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      :ok = RoomManager.leave_room("user4")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :waiting
      assert Positions.count(updated_room) == 3
    end
  end

  describe "handle_player_disconnect/2" do
    test "updates last_activity for waiting room disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      before_disconnect = DateTime.utc_now()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Waiting rooms: disconnect only updates last_activity, no seat cascade
      assert DateTime.compare(updated_room.last_activity, before_disconnect) in [:gt, :eq]

      # Player should still be in player_ids
      assert Positions.has_player?(updated_room, "user2")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.handle_player_disconnect("ZZZZ", "user1")
    end

    test "returns error when player not in room" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:error, :player_not_in_room} =
               RoomManager.handle_player_disconnect(room.code, "user999")
    end

    test "allows same player to be marked disconnected multiple times" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Wait a bit
      Process.sleep(10)

      # Second disconnect should also succeed for waiting rooms
      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Player should still be in the room
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, "user1")
    end

    test "tracks multiple players disconnecting" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # All players should still be in positions (waiting room, no seat cascade)
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, "user1")
      assert Positions.has_player?(updated_room, "user2")
      assert Positions.has_player?(updated_room, "user3")
    end
  end

  describe "handle_player_reconnect/2" do
    test "reconnect is not needed for waiting room disconnects" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Waiting rooms don't use seat cascade, so reconnect finds no disconnected seat
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user2")

      # But player is still in the room
      {:ok, room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(room, "user2")
    end

    test "returns error when player not disconnected" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      # Try to reconnect without disconnecting first
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user2")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.handle_player_reconnect("ZZZZ", "user1")
    end

    test "reconnect returns error for waiting room disconnects" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Waiting rooms don't track disconnects via seats
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user1")

      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user2")

      # But all players are still in the room
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, "user1")
      assert Positions.has_player?(updated_room, "user2")
      assert Positions.has_player?(updated_room, "user3")
    end
  end

  describe "disconnect timeout and grace period" do
    # Tests use configured grace period (50ms in test.exs)

    test "player remains in waiting room after disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Wait a short time
      Process.sleep(10)

      # Waiting rooms don't use seat cascade — player stays in positions
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, "user2")
    end

    test "player is NOT removed from waiting room after disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Verify player is still in positions
      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(disconnected_room, "user2")

      # Wait well past any legacy grace period
      Process.sleep(100)

      # Waiting rooms don't remove players on disconnect — no seat cascade
      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user2")
    end

    test "player stays in waiting room after disconnect without reconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Wait a bit
      Process.sleep(10)

      # No reconnect needed for waiting rooms — player persists
      Process.sleep(100)

      # Player should still be in room
      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user2")
    end

    test "multiple disconnected players stay in waiting room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      # Disconnect players at slightly different times
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      Process.sleep(10)
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Wait past any legacy grace period
      Process.sleep(100)

      # Waiting rooms don't remove players — all should still be present
      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user1")
      assert Positions.has_player?(final_room, "user2")
      assert Positions.has_player?(final_room, "user3")
      assert Positions.has_player?(final_room, "user4")
    end

    test "grace period check handles room that no longer exists" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Host leaves, closing the room
      :ok = RoomManager.leave_room("user1")

      # Wait for grace period - should not crash
      Process.sleep(100)

      # Room should still not exist
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end
  end

  describe "list_rooms/1" do
    test "lists all rooms by default" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      rooms = RoomManager.list_rooms()

      assert length(rooms) == 2
      codes = Enum.map(rooms, & &1.code)
      assert room1.code in codes
      assert room2.code in codes
    end

    test "filters rooms by status" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})
      {:ok, _, _} = RoomManager.join_room(room2.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room2.code, "user4")
      {:ok, _, _} = RoomManager.join_room(room2.code, "user5")

      waiting_rooms = RoomManager.list_rooms(:waiting)
      playing_rooms = RoomManager.list_rooms(:playing)

      assert length(waiting_rooms) == 1
      assert hd(waiting_rooms).code == room1.code

      # When 4th player joins, room transitions to :ready and immediately to :playing
      # because GameSupervisor auto-starts the game
      assert length(playing_rooms) == 1
      assert hd(playing_rooms).code == room2.code
    end

    test "returns empty list when no rooms exist" do
      rooms = RoomManager.list_rooms()
      assert rooms == []
    end
  end

  describe "get_room/1" do
    test "retrieves room by code" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test"})

      {:ok, fetched_room} = RoomManager.get_room(room.code)

      assert fetched_room.code == room.code
      assert fetched_room.host_id == "user1"
      assert fetched_room.metadata.name == "Test"
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = RoomManager.get_room("ZZZZ")
    end

    test "handles case-insensitive lookup" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      lowercase_code = String.downcase(room.code)

      {:ok, fetched_room} = RoomManager.get_room(lowercase_code)

      assert fetched_room.code == room.code
    end
  end

  describe "update_room_status/2" do
    test "updates room status" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.update_room_status(room.code, :playing)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :playing
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.update_room_status("ZZZZ", :playing)
    end

    test "allows all valid status transitions" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      for status <- [:waiting, :ready, :playing, :finished, :closed] do
        :ok = RoomManager.update_room_status(room.code, status)
        {:ok, updated_room} = RoomManager.get_room(room.code)
        assert updated_room.status == status
      end
    end
  end

  describe "close_room/1" do
    test "closes and removes room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.close_room(room.code)

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "removes all player mappings when closing room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.close_room(room.code)

      # Players should be able to join new rooms
      {:ok, new_room} = RoomManager.create_room("user1", %{})
      assert new_room.host_id == "user1"
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = RoomManager.close_room("ZZZZ")
    end
  end

  describe "edge cases and concurrent operations" do
    test "disconnect and leave are idempotent for same player" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.leave_room("user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      refute Positions.has_player?(updated_room, "user2")
    end

    test "handles room state correctly after disconnect in waiting room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Should have 3 players total — waiting room disconnect doesn't change positions
      assert Positions.count(updated_room) == 3
    end

    test "reconnect after disconnect in waiting room returns not_disconnected" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Waiting rooms don't use seat cascade, so reconnect is a no-op
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user1")

      # Player should still be in the room
      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user1")
    end
  end

  describe "last_activity tracking" do
    test "initializes last_activity on room creation" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test Room"})
      assert room.last_activity != nil
      assert DateTime.diff(DateTime.utc_now(), room.last_activity, :second) < 2
    end

    test "updates last_activity on player join" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      original_activity = room.last_activity

      Process.sleep(100)
      {:ok, updated_room, _} = RoomManager.join_room(room.code, "user2")

      assert DateTime.compare(updated_room.last_activity, original_activity) == :gt
    end

    test "updates last_activity on player disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, room_before} = RoomManager.get_room(room.code)

      Process.sleep(100)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert DateTime.compare(updated_room.last_activity, room_before.last_activity) == :gt
    end
  end

  describe "turn timers" do
    test "starts a room-owned timer for all-human dealer selection" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      room_code = room.code

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      {:ok, _, _} = RoomManager.join_room(room_code, "user2")
      {:ok, _, _} = RoomManager.join_room(room_code, "user3")
      {:ok, _, _} = RoomManager.join_room(room_code, "user4")

      assert_receive {:turn_timer_started, payload}, 200
      assert payload.scope == :room
      assert payload.position == nil
      assert payload.phase == :dealer_selection
      assert payload.transition_delay_ms == 0
      assert payload.event_seq == 0

      turn_timer = wait_for_turn_timer(room_code)
      assert turn_timer.scope == :room
      assert turn_timer.position == nil
      assert turn_timer.phase == :dealer_selection
      assert turn_timer.timer_id == payload.timer_id
      assert turn_timer.remaining_ms > 0
    end

    test "restarts the timer when a new same-position action window arrives" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      active_timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      send(
        RoomManager,
        {:state_update, room_code,
         %{state: %{bidding_state | events: bidding_state.events ++ [:synthetic_window]}, transition_delay_ms: 0}}
      )

      assert_receive {:turn_timer_cancelled, cancelled}, 200
      assert cancelled.timer_id == active_timer.timer_id
      assert cancelled.position == active_timer.position
      assert cancelled.reason == :acted

      assert_receive {:turn_timer_started, started}, 200
      assert started.scope == :seat
      assert started.position == active_timer.position
      assert started.phase == active_timer.phase
      assert started.event_seq == active_timer.event_seq + 1
      assert started.timer_id != active_timer.timer_id
    end

    test "pauses a seat-owned timer on disconnect and resumes it on reconnect" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      {:ok, room} = RoomManager.get_room(room_code)

      timed_user = Map.fetch!(room.positions, bidding_state.current_turn)

      :ok = RoomManager.handle_player_disconnect(room_code, timed_user)

      {:ok, paused_room} = RoomManager.get_room(room_code)
      assert paused_room.turn_timer == nil
      assert paused_room.seats[bidding_state.current_turn].status == :reconnecting
      assert paused_room.paused_turn_timer.key == {:seat, bidding_state.current_turn, :bidding, length(bidding_state.events)}
      assert paused_room.paused_turn_timer.remaining_ms > 0

      assert {:ok, nil} = RoomManager.get_turn_timer(room_code)

      assert {:ok, _room} = RoomManager.handle_player_reconnect(room_code, timed_user)

      resumed_timer = wait_for_turn_timer(room_code)
      {:ok, resumed_room} = RoomManager.get_room(room_code)

      assert resumed_room.paused_turn_timer == nil
      assert resumed_timer.scope == :seat
      assert resumed_timer.position == bidding_state.current_turn
      assert resumed_timer.phase == :bidding
      assert resumed_timer.event_seq == length(bidding_state.events)
      assert resumed_timer.duration_ms <= Lifecycle.config(:turn_timer_bid_ms)
      assert resumed_timer.remaining_ms > 0
    end

    test "reconciles the action window on reconnect when no paused timer survives" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      {:ok, room} = RoomManager.get_room(room_code)

      timed_position = bidding_state.current_turn
      timed_user = Map.fetch!(room.positions, timed_position)

      :ok = RoomManager.handle_player_disconnect(room_code, timed_user)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current_room = Map.fetch!(manager_state.rooms, room_code)
        updated_room = %{current_room | paused_turn_timer: nil, turn_timer: nil}
        %{manager_state | rooms: Map.put(manager_state.rooms, room_code, updated_room)}
      end)

      assert {:ok, nil} = RoomManager.get_turn_timer(room_code)
      assert {:ok, _room} = RoomManager.handle_player_reconnect(room_code, timed_user)

      resumed_timer = wait_for_turn_timer(room_code)

      assert resumed_timer.scope == :seat
      assert resumed_timer.position == timed_position
      assert resumed_timer.phase == :bidding
      assert resumed_timer.event_seq == length(bidding_state.events)
      assert resumed_timer.remaining_ms > 0
    end

    test "uses the disconnect fallback when a timed-out player has no live game channel pid" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      {:ok, room} = RoomManager.get_room(room_code)
      timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      position = bidding_state.current_turn
      threshold = Lifecycle.config(:consecutive_timeout_threshold)
      timed_user = Map.fetch!(room.positions, position)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current_room = Map.fetch!(manager_state.rooms, room_code)
        updated_room = %{current_room | consecutive_timeouts: %{position => threshold - 1}}
        %{manager_state | rooms: Map.put(manager_state.rooms, room_code, updated_room)}
      end)

      send(
        RoomManager,
        {:turn_timer_expired, room_code, timer.timer_id, {:seat, timer.position, timer.phase, timer.event_seq}}
      )

      assert_receive {:turn_auto_played, payload}, 200
      assert payload.scope == :seat
      assert payload.position == position
      assert payload.phase == :bidding
      assert payload.action == %{type: :pass}

      updated_room =
        wait_until(fn ->
          case RoomManager.get_room(room_code) do
            {:ok, %{seats: %{^position => seat}} = updated_room} when seat.status == :reconnecting ->
              updated_room

            _ ->
              nil
          end
        end)

      assert updated_room.consecutive_timeouts[position] == threshold
      assert updated_room.seats[position].user_id == timed_user
    end

    test "ignores stale timeout messages" do
      room_code = create_playing_room()
      _bidding_state = advance_room_to_bidding(room_code)
      timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      send(
        RoomManager,
        {:turn_timer_expired, room_code, timer.timer_id + 1_000, {:seat, timer.position, timer.phase, timer.event_seq}}
      )

      refute_receive {:turn_auto_played, _payload}, 50

      {:ok, current_timer} = RoomManager.get_turn_timer(room_code)
      assert current_timer.timer_id == timer.timer_id
      assert current_timer.position == timer.position
      assert current_timer.phase == timer.phase
      assert current_timer.event_seq == timer.event_seq
    end
  end

  describe "abandoned room cleanup" do
    test "removes abandoned room (inactive + no players)" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Clear the host's position to make the room empty
      # (host is auto-assigned to :north)
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, nil)

      # Verify room still exists but has no players
      assert {:ok, empty_room} = RoomManager.get_room(room.code)
      assert Positions.count(empty_room) == 0

      # Set activity to > 5 minutes ago
      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      # Trigger cleanup manually
      send(RoomManager, :cleanup_abandoned_rooms)

      # Allow message processing
      Process.sleep(50)

      # Room should be gone
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "does not remove room with active players even if idle" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Set activity to old
      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      # Trigger cleanup
      send(RoomManager, :cleanup_abandoned_rooms)
      Process.sleep(50)

      # Room should still exist because user1 is active
      assert {:ok, _} = RoomManager.get_room(room.code)
    end

    test "does not remove room with active spectators even if idle" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")
      # Room is now :ready -> :playing.

      {:ok, _} = RoomManager.join_spectator_room(room.code, "spectator1")

      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      send(RoomManager, :cleanup_abandoned_rooms)
      Process.sleep(50)

      assert {:ok, _} = RoomManager.get_room(room.code)
    end
  end

  describe "dev_set_position/3 - GitHub Issue #6" do
    test "sets a position to a user" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert updated_room.positions[:north] == "user2"
      assert Positions.has_player?(updated_room, "user2")
    end

    test "clears a seat when user_id is nil" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, room_with_player} = RoomManager.dev_set_position(room.code, :south, "user2")

      assert room_with_player.positions[:south] == "user2"

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :south, nil)

      assert updated_room.positions[:south] == nil
      refute Positions.has_player?(updated_room, "user2")
    end

    test "auto-starts game when 4 players assigned (returns :playing status)" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      {:ok, room2} = RoomManager.dev_set_position(room.code, :north, "user1")
      assert room2.status == :waiting

      {:ok, room3} = RoomManager.dev_set_position(room.code, :east, "user2")
      assert room3.status == :waiting

      {:ok, room4} = RoomManager.dev_set_position(room.code, :south, "user3")
      assert room4.status == :waiting

      # When 4th player is assigned, game auto-starts and returns final :playing status
      {:ok, final_room} = RoomManager.dev_set_position(room.code, :west, "user4")
      assert final_room.status == :playing
      assert Positions.count(final_room) == 4
    end

    test "broadcasts to correct topics on position change" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Subscribe to both topics
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")

      # Should receive room update
      assert_receive {:room_update, updated_room}, 100
      assert updated_room.positions[:east] == "user2"

      # Should receive lobby event
      assert_receive {:room_updated, _room}, 100
    end

    test "allows changes during :playing status (no restrictions)" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user1")
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user3")

      # Change status to playing before 4th player
      :ok = RoomManager.update_room_status(room.code, :playing)

      # Should still allow position changes and preserve :playing status
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :west, "user4")
      assert updated_room.positions[:west] == "user4"
      assert updated_room.status == :playing
      assert Positions.count(updated_room) == 4
    end

    test "allows changes during :playing status (after auto-start)" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user1")
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user3")
      {:ok, playing_room} = RoomManager.dev_set_position(room.code, :west, "user4")

      # Game auto-starts when 4 players are assigned
      assert playing_room.status == :playing

      # Should allow changing a seat even during :playing status
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user5")
      assert updated_room.positions[:north] == "user5"
    end

    test "allows changes during :finished status" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      :ok = RoomManager.update_room_status(room.code, :finished)

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :south, "user2")
      assert updated_room.positions[:south] == "user2"
      assert updated_room.status == :finished
    end

    test "returns error for invalid position" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:error, :invalid_position} =
               RoomManager.dev_set_position(room.code, :invalid, "user2")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.dev_set_position("ZZZZ", :north, "user1")
    end

    test "replaces player at position when reassigning" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert room2.positions[:north] == "user2"

      # Replace user2 with user3 at north
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user3")

      assert updated_room.positions[:north] == "user3"
      # user2 should no longer be in the room
      refute Positions.has_player?(updated_room, "user2")
      assert Positions.has_player?(updated_room, "user3")
    end

    test "updates player_rooms mapping correctly when replacing" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")

      # user2 should be mapped to this room
      {:ok, room_check} = RoomManager.get_room(room.code)
      assert Positions.has_player?(room_check, "user2")

      # Replace user2 with user3
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user3")

      # user2 should be able to join another room now (not blocked)
      {:ok, new_room} = RoomManager.create_room("user2", %{})
      assert new_room.host_id == "user2"
    end

    test "moves player from one position to another, clearing old position" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user2")

      # Move user2 from north to south
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user2")
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # user2 should now be at south only, old position (north) should be cleared
      assert updated_room.positions[:south] == "user2"
      assert updated_room.positions[:north] == nil

      # Verify user occupies exactly one seat
      seats = [
        updated_room.positions[:north],
        updated_room.positions[:south],
        updated_room.positions[:east],
        updated_room.positions[:west]
      ]

      assert Enum.count(seats, &(&1 == "user2")) == 1
    end

    test "updates last_activity timestamp" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      initial_activity = room.last_activity

      # Wait a tiny bit to ensure timestamp difference
      Process.sleep(10)

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert DateTime.compare(updated_room.last_activity, initial_activity) == :gt
    end
  end

  defp create_playing_room do
    {:ok, room} = RoomManager.create_room("user1", %{})
    room_code = room.code

    {:ok, _, _} = RoomManager.join_room(room_code, "user2")
    {:ok, _, _} = RoomManager.join_room(room_code, "user3")
    {:ok, _, _} = RoomManager.join_room(room_code, "user4")

    _room =
      wait_until(fn ->
        case RoomManager.get_room(room_code) do
          {:ok, %{status: :playing} = room} -> room
          _ -> nil
        end
      end)

    room_code
  end

  defp advance_room_to_bidding(room_code) do
    {:ok, state} = GameAdapter.get_state(room_code)

    if state.phase == :dealer_selection do
      {:ok, _state} = GameAdapter.apply_action(room_code, :north, :select_dealer)
    end

    wait_until(fn ->
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding} = state} -> state
        _ -> nil
      end
    end)
  end

  defp wait_for_turn_timer(room_code) do
    wait_until(fn ->
      case RoomManager.get_turn_timer(room_code) do
        {:ok, nil} -> nil
        {:ok, turn_timer} -> turn_timer
        _ -> nil
      end
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end
end
