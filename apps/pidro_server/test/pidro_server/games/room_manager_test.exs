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

  alias PidroServer.Games.RoomManager
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
      assert room.disconnected_players == %{}
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
    test "marks player as disconnected with timestamp" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      before_disconnect = DateTime.utc_now()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      after_disconnect = DateTime.utc_now()

      {:ok, updated_room} = RoomManager.get_room(room.code)

      assert Map.has_key?(updated_room.disconnected_players, "user2")
      disconnect_time = updated_room.disconnected_players["user2"]
      assert DateTime.compare(disconnect_time, before_disconnect) in [:gt, :eq]
      assert DateTime.compare(disconnect_time, after_disconnect) in [:lt, :eq]

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
      first_disconnect_time = DateTime.utc_now()

      # Wait a bit (less than grace period of 50ms)
      Process.sleep(10)

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      second_disconnect_time = updated_room.disconnected_players["user1"]

      # Second disconnect should update timestamp
      assert DateTime.compare(second_disconnect_time, first_disconnect_time) == :gt
    end

    test "tracks multiple players disconnecting" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      assert Map.has_key?(updated_room.disconnected_players, "user1")
      assert Map.has_key?(updated_room.disconnected_players, "user2")
      refute Map.has_key?(updated_room.disconnected_players, "user3")
    end
  end

  describe "handle_player_reconnect/2" do
    test "successfully reconnects player within grace period" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      assert Positions.has_player?(reconnected_room, "user2")
      refute Map.has_key?(reconnected_room.disconnected_players, "user2")
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

    test "multiple players can reconnect independently" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, room_after_first} = RoomManager.handle_player_reconnect(room.code, "user1")
      refute Map.has_key?(room_after_first.disconnected_players, "user1")
      assert Map.has_key?(room_after_first.disconnected_players, "user2")

      {:ok, room_after_second} = RoomManager.handle_player_reconnect(room.code, "user2")
      refute Map.has_key?(room_after_second.disconnected_players, "user1")
      refute Map.has_key?(room_after_second.disconnected_players, "user2")
    end
  end

  describe "disconnect timeout and grace period" do
    # Tests use configured grace period (50ms in test.exs)

    test "player remains in room during grace period" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Wait a very short time (less than 50ms)
      Process.sleep(10)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, "user2")
      assert Map.has_key?(updated_room.disconnected_players, "user2")
    end

    test "player is removed after grace period expires" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Verify player is disconnected
      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      assert Map.has_key?(disconnected_room.disconnected_players, "user2")
      assert Positions.has_player?(disconnected_room, "user2")

      # Wait for grace period (50ms) plus buffer
      Process.sleep(100)

      # Use retry pattern to wait for GenServer to process the timeout message
      # Wait up to 1 second for the player to be removed
      result =
        Enum.reduce_while(1..10, nil, fn _, _acc ->
          {:ok, current_room} = RoomManager.get_room(room.code)

          if Positions.has_player?(current_room, "user2") do
            Process.sleep(50)
            {:cont, nil}
          else
            {:halt, {:ok, current_room}}
          end
        end)

      # Player should now be removed
      assert {:ok, final_room} = result
      refute Positions.has_player?(final_room, "user2")
      refute Map.has_key?(final_room.disconnected_players, "user2")
    end

    test "reconnecting cancels timeout removal" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Wait a bit
      Process.sleep(10)

      # Reconnect before grace period
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")

      # Wait past when timeout would have fired (50ms)
      Process.sleep(100)

      # Player should still be in room
      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user2")
      refute Map.has_key?(final_room.disconnected_players, "user2")
    end

    test "multiple disconnected players removed after grace period" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      # Disconnect players at slightly different times
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      Process.sleep(10)
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Wait for grace period
      Process.sleep(100)

      # Use retry pattern to wait for GenServer to process the timeout messages
      # Wait up to 1 second for both players to be removed
      result =
        Enum.reduce_while(1..10, nil, fn _, _acc ->
          {:ok, current_room} = RoomManager.get_room(room.code)

          if Positions.has_player?(current_room, "user2") or
               Positions.has_player?(current_room, "user3") do
            Process.sleep(50)
            {:cont, nil}
          else
            {:halt, {:ok, current_room}}
          end
        end)

      # Both should be removed
      assert {:ok, final_room} = result
      refute Positions.has_player?(final_room, "user2")
      refute Positions.has_player?(final_room, "user3")
      assert Positions.has_player?(final_room, "user1")
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

    test "handles room state correctly with disconnected players count" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Should have 3 players total
      assert Positions.count(updated_room) == 3
      # But one is disconnected
      assert map_size(updated_room.disconnected_players) == 1
    end

    test "reconnect after already reconnected does nothing harmful" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user1")

      # Try to reconnect again
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user1")

      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user1")
      refute Map.has_key?(final_room.disconnected_players, "user1")
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

  describe "abandoned room cleanup" do
    test "removes abandoned room (inactive + all players disconnected)" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Disconnect the only player
      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Verify room still exists
      assert {:ok, _} = RoomManager.get_room(room.code)

      # Set activity to > 5 minutes ago
      # 5 mins + 1 sec
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
end
