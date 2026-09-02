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

  import ExUnit.CaptureLog

  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomCodes, RoomManager}
  alias PidroServer.Games.Room.{Positions, Seat}
  alias PidroServer.RoomFixtures

  # Note: async: false is required because RoomManager is a singleton GenServer

  setup do
    # Start the RoomManager if not already started
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    # Reset state between tests
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

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

  describe "create_room/2 room code allocation" do
    # The :create_room handler reads an optional generator override from the
    # app env at call time so collisions can be forced deterministically.
    setup do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      :ok
    end

    test "retries a colliding code and leaves the existing room untouched" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room("user1", %{name: "First"})
      {:ok, _room, _position} = RoomManager.join_room("ZZZZ", "user2")

      Application.put_env(:pidro_server, RoomCodes,
        generator: sequence_generator(["ZZZZ", "YYYY"])
      )

      assert {:ok, %{code: "YYYY", host_id: "user3"}} = RoomManager.create_room("user3", %{})

      assert {:ok, existing} = RoomManager.get_room("ZZZZ")
      assert existing.host_id == "user1"
      assert Enum.sort(Positions.player_ids(existing)) == ["user1", "user2"]
      assert existing.metadata.name == "First"
    end

    test "replies :room_code_exhausted after 10 collisions and keeps the colliding room intact" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room("user1", %{name: "First"})
      {:ok, _room, _position} = RoomManager.join_room("ZZZZ", "user2")

      calls = :counters.new(1, [])

      Application.put_env(:pidro_server, RoomCodes,
        generator: fn ->
          :counters.add(calls, 1, 1)
          "ZZZZ"
        end
      )

      log =
        capture_log([level: :error], fn ->
          assert {:error, :room_code_exhausted} = RoomManager.create_room("user3", %{})
        end)

      assert :counters.get(calls, 1) == 10
      assert log =~ "live rooms: 1"

      assert {:ok, existing} = RoomManager.get_room("ZZZZ")
      assert existing.host_id == "user1"
      assert Enum.sort(Positions.player_ids(existing)) == ["user1", "user2"]
      assert existing.metadata.name == "First"
      assert length(RoomManager.list_rooms(:all)) == 1

      # The failed host was never tracked, so a later attempt with a free code succeeds
      Application.delete_env(:pidro_server, RoomCodes)
      assert {:ok, %{host_id: "user3"}} = RoomManager.create_room("user3", %{})
    end

    test "get_room/1 finds a room by its lowercased code" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ABCD" end)
      {:ok, %{code: "ABCD"}} = RoomManager.create_room("user1", %{})

      assert {:ok, %{code: "ABCD"}} = RoomManager.get_room("abcd")
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

    test "closes a single-player table when the human leaves mid-game" do
      {:ok, room} = RoomManager.create_room("user1", %{single_player: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
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

    test "single-player room stays alive with grace period when human disconnects during play" do
      {:ok, room} = RoomManager.create_room("user1", %{single_player: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Room stays alive — disconnect cascade starts instead of immediate removal
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :playing

      # Player's seat is in :reconnecting phase (hiccup window)
      position = Positions.get_position(updated_room, "user1")
      seat = Map.get(updated_room.seats, position)
      assert seat.status == :reconnecting
    end

    test "single-player room allows reconnection after disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{single_player: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Reconnect within hiccup window succeeds
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user1")
      position = Positions.get_position(reconnected_room, "user1")
      seat = Map.get(reconnected_room.seats, position)
      assert seat.status == :connected
      assert seat.occupant_type == :human
    end

    test "intentional leave still closes single-player room immediately" do
      {:ok, room} = RoomManager.create_room("user1", %{single_player: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
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
    test "does not start turn timers for single-player rooms" do
      room_code = create_playing_room(%{single_player: true})
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      _bidding_state = advance_room_to_bidding(room_code)

      assert {:ok, nil} = RoomManager.get_turn_timer(room_code)
      refute_receive {:turn_timer_started, _payload}, 100
    end

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
         %{
           state: %{bidding_state | events: bidding_state.events ++ [:synthetic_window]},
           transition_delay_ms: 0
         }}
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

      assert paused_room.paused_turn_timer.key ==
               {:seat, bidding_state.current_turn, :bidding, length(bidding_state.events)}

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
        {:turn_timer_expired, room_code, timer.timer_id,
         {:seat, timer.position, timer.phase, timer.event_seq}}
      )

      assert_receive {:turn_auto_played, payload}, 200
      assert payload.scope == :seat
      assert payload.position == position
      assert payload.phase == :bidding
      assert payload.action == %{type: :pass}

      updated_room =
        wait_until(fn ->
          case RoomManager.get_room(room_code) do
            {:ok, %{seats: %{^position => seat}} = updated_room}
            when seat.status == :reconnecting ->
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
        {:turn_timer_expired, room_code, timer.timer_id + 1_000,
         {:seat, timer.position, timer.phase, timer.event_seq}}
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

  describe "room identity" do
    test "create_room/2 assigns a UUID id and the invite defaults" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:ok, _uuid} = Ecto.UUID.cast(room.id)
      assert room.locked == false
      assert room.kicked_ids == []
      assert room.invite_live_until == nil
    end

    test "every room gets its own id" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      assert room1.id != room2.id
    end
  end

  describe "claim_seat/4 room identity" do
    setup do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      :ok
    end

    test "seats the caller with the live room id and refuses a stale id for a reused code" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ", id: stale_id}} = RoomManager.create_room("host-a", %{})
      :ok = RoomManager.leave_room("host-a")
      {:ok, %{code: "ZZZZ", id: live_id}} = RoomManager.create_room("host-b", %{})

      assert stale_id != live_id

      assert {:error, :room_not_found} =
               RoomManager.claim_seat("ZZZZ", stale_id, "guest", display_name: "Guest")

      assert {:ok, room, :east, true} =
               RoomManager.claim_seat("ZZZZ", live_id, "guest", display_name: "Guest")

      assert room.positions[:east] == "guest"
      assert Seat.connected_human?(room.seats[:east])
      assert {:ok, %{positions: %{east: "guest"}}} = RoomManager.get_room("ZZZZ")
    end

    test "returns :room_not_found for an unknown code" do
      assert {:error, :room_not_found} =
               RoomManager.claim_seat("NOPE", Ecto.UUID.generate(), "guest", [])
    end
  end

  describe "claim_seat/4" do
    test "honours the seat hint and falls back on a second claim with the same hint" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, _room, :south, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :south)

      assert {:ok, updated, :east, false} =
               RoomManager.claim_seat(room.code, room.id, "guest2", hint: :south)

      assert updated.positions == %{north: "host", east: "guest2", south: "guest1", west: nil}
    end

    test "honours a team hint" do
      {room, _ids} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:ok, _room, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :east_west)
    end

    test "resolves :partner to the seat opposite the host after the host has moved" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _moved} = RoomManager.move_seat(room.code, host, host, :east)

      assert {:ok, updated, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :partner)

      assert updated.positions[:west] == "guest1"
    end

    test "returns :room_not_found for :partner when the host has no seat" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _room} = RoomManager.dev_set_position(room.code, :north, nil)

      assert {:error, :room_not_found} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :partner)
    end

    test "an explicit taken position returns next_open in N/E/S/W order" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _room, :south} = RoomManager.join_room(room.code, "user2", :south)

      assert {:error, {:seat_taken, [:east, :west]}} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :north)

      assert {:error, {:seat_taken, [:east, :west]}} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :south)

      assert {:ok, _room, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :west, hint: :north)
    end

    test "a caller already seated at the table gets the current seat and nothing changes" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, seated, :east, true} = RoomManager.claim_seat(room.code, room.id, "guest1", [])
      assert_receive {:invite_redeemed, %{user_id: "guest1"}}, 100

      assert {:ok, again, :east, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :west)

      assert again.positions == seated.positions
      assert again.seats == seated.seats
      assert again.last_activity == seated.last_activity
      refute_receive {:invite_redeemed, _payload}, 50
    end

    test "a caller connected in another room gets :already_in_room" do
      {room_a, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)
      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")

      assert {:error, :already_in_room} =
               RoomManager.claim_seat(room_b.code, room_b.id, "user2", [])

      assert {:ok, %{positions: %{east: "user2"}}} = RoomManager.get_room(room_a.code)
    end

    test "evicts a caller whose seat elsewhere is disconnected (U3 vacates it and holds waiting seats)" do
      {room_a, [_host_a, "user2"]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)

      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")

      # Simulate a disconnected seat: today only the :playing cascade produces
      # this state; U3 makes a waiting-room disconnect hold the seat like this.
      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current = Map.fetch!(manager_state.rooms, room_a.code)
        {:ok, held} = Seat.disconnect(current.seats[:east])
        updated = %{current | seats: Map.put(current.seats, :east, held)}
        %{manager_state | rooms: Map.put(manager_state.rooms, room_a.code, updated)}
      end)

      assert {:ok, seated, :east, true} =
               RoomManager.claim_seat(room_b.code, room_b.id, "user2", [])

      assert seated.positions[:east] == "user2"
      # The caller is now tracked in room B: leaving removes them from B.
      :ok = RoomManager.leave_room("user2")
      assert {:ok, %{positions: %{east: nil}}} = RoomManager.get_room(room_b.code)
    end

    test "the fourth claim starts the game" do
      {room, _ids} = RoomFixtures.waiting_room_fixture(seated: 3)

      assert {:ok, %{status: :ready}, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      wait_until(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(room.code))
      end)
    end

    test "broadcasts invite_redeemed with the display name on game:<code>" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, _room, :east, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", display_name: "Ada")

      assert_receive {:invite_redeemed,
                      %{position: :east, user_id: "guest1", display_name: "Ada"}},
                     100

      assert_receive {:room_update, %{positions: %{east: "guest1"}}}, 100
      assert_receive {:room_updated, %{positions: %{east: "guest1"}}}, 100
    end

    test "touches last_activity" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      old_time = DateTime.add(DateTime.utc_now(), -301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      assert {:ok, updated, _position, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      assert DateTime.compare(updated.last_activity, old_time) == :gt
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()
      {:ok, room} = RoomManager.get_room(room_code)

      assert {:error, :room_not_available} =
               RoomManager.claim_seat(room_code, room.id, "guest1", [])
    end
  end

  describe "note_invite/2" do
    test "stores the given value, including nil, and the room stays lobby-visible" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert :ok = RoomManager.note_invite(room.code, until)
      assert {:ok, %{invite_live_until: ^until} = live} = RoomManager.get_room(room.code)
      assert RoomManager.visible_in_lobby?(live)
      assert Enum.any?(RoomManager.list_lobby("someone").open_tables, &(&1.code == room.code))
      assert Enum.any?(RoomManager.list_rooms(:waiting), &(&1.code == room.code))

      assert :ok = RoomManager.note_invite(room.code, nil)
      assert {:ok, %{invite_live_until: nil}} = RoomManager.get_room(room.code)
    end

    test "touches last_activity" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      old_time = DateTime.add(DateTime.utc_now(), -301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      :ok = RoomManager.note_invite(room.code, DateTime.utc_now())

      {:ok, updated} = RoomManager.get_room(room.code)
      assert DateTime.compare(updated.last_activity, old_time) == :gt
    end

    test "returns :room_not_found for an unknown code" do
      assert {:error, :room_not_found} = RoomManager.note_invite("NOPE", nil)
    end
  end

  describe "set_locked/3" do
    test "the host locks and unlocks the table" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, %{locked: true}} = RoomManager.set_locked(room.code, host, true)
      assert {:ok, %{locked: true}} = RoomManager.get_room(room.code)
      assert {:error, :table_locked} = RoomManager.join_room(room.code, "user2")

      assert {:error, :table_locked} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      assert {:ok, %{locked: false}} = RoomManager.set_locked(room.code, host, false)
      assert {:ok, _room, :east} = RoomManager.join_room(room.code, "user2")
    end

    test "a locked room still accepts a reclaim of a disconnected seat" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      {:ok, _locked} = RoomManager.set_locked(room.code, host, true)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current = Map.fetch!(manager_state.rooms, room.code)
        {:ok, held} = Seat.disconnect(current.seats[:east])
        updated = %{current | seats: Map.put(current.seats, :east, held)}
        %{manager_state | rooms: Map.put(manager_state.rooms, room.code, updated)}
      end)

      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, "user2")
      assert Seat.connected_human?(reclaimed.seats[:east])
      assert reclaimed.locked
    end

    test "a non-host gets :not_owner" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :not_owner} = RoomManager.set_locked(room.code, "user2", true)
      assert {:ok, %{locked: false}} = RoomManager.get_room(room.code)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} = RoomManager.set_locked(room_code, "user1", true)
    end

    test "broadcasts the room and lobby updates" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _room} = RoomManager.set_locked(room.code, host, true)

      assert_receive {:room_update, %{locked: true}}, 100
      assert_receive {:room_updated, %{locked: true}}, 100
    end
  end

  describe "kick_player/3" do
    test "vacates the seat, records the id, notifies the channel and clears the mapping" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.register_game_channel(room.code, "user2", self())
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")

      assert {:ok, kicked} = RoomManager.kick_player(room.code, host, :east)

      assert kicked.positions[:east] == nil
      assert Seat.vacant?(kicked.seats[:east])
      assert kicked.kicked_ids == ["user2"]
      assert kicked.status == :waiting
      assert_receive {:force_disconnect, :kicked}, 100
      assert_receive {:kicked, %{position: :east, user_id: "user2"}}, 100
      assert_receive {:room_update, %{positions: %{east: nil}}}, 100

      assert {:error, :not_in_room} = RoomManager.leave_room("user2")
      assert {:ok, _room} = RoomManager.create_room("user2", %{})
    end

    test "a kicked id is refused on join, claim and a later substitute join" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      {:ok, _room} = RoomManager.kick_player(room.code, host, :east)

      assert {:error, :kicked} = RoomManager.join_room(room.code, "user2")
      assert {:error, :kicked} = RoomManager.claim_seat(room.code, room.id, "user2", [])

      {:ok, _room, _pos} = RoomManager.join_room(room.code, "user3")
      {:ok, _room, _pos} = RoomManager.join_room(room.code, "user4")
      {:ok, _room, user5_position} = RoomManager.join_room(room.code, "user5")

      wait_until(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(room.code))
      end)

      # Open a seat for substitutes: disconnect, skip the hiccup timer, open.
      :ok = RoomManager.handle_player_disconnect(room.code, "user5")
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user5_position})

      wait_until(fn ->
        match?(
          {:ok, %{seats: %{^user5_position => %{status: :bot_substitute}}}},
          RoomManager.get_room(room.code)
        )
      end)

      {:ok, _room} = RoomManager.open_seat(room.code, user5_position, host)

      assert {:error, :kicked} = RoomManager.join_as_substitute(room.code, "user2")
      assert {:ok, _room, ^user5_position} = RoomManager.join_as_substitute(room.code, "user6")
    end

    test "the host's own seat and vacant seats are not kickable" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :seat_not_kickable} = RoomManager.kick_player(room.code, host, :north)
      assert {:error, :seat_not_kickable} = RoomManager.kick_player(room.code, host, :west)
      assert {:ok, %{positions: %{north: ^host, east: "user2"}}} = RoomManager.get_room(room.code)
    end

    test "a non-host gets :not_owner" do
      {room, [_host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      assert {:error, :not_owner} = RoomManager.kick_player(room.code, "user2", :south)
      assert {:ok, %{positions: %{south: "user3"}}} = RoomManager.get_room(room.code)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} = RoomManager.kick_player(room_code, "user1", :east)
    end
  end

  describe "move_seat/4" do
    test "the host moves another player to a vacant seat and broadcasts seat_moved" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, moved} = RoomManager.move_seat(room.code, host, "user2", :west)

      assert moved.positions == %{north: host, east: nil, south: nil, west: "user2"}
      assert Seat.vacant?(moved.seats[:east])
      assert %Seat{position: :west, user_id: "user2", is_owner: false} = moved.seats[:west]
      assert Seat.connected_human?(moved.seats[:west])
      assert_receive {:seat_moved, %{user_id: "user2", from: :east, to: :west}}, 100
      assert_receive {:room_update, %{positions: %{west: "user2"}}}, 100
      assert_receive {:room_updated, %{positions: %{west: "user2"}}}, 100
    end

    test "keeps is_owner when the host moves themselves" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, moved} = RoomManager.move_seat(room.code, host, host, :south)

      assert moved.host_id == host
      assert moved.positions == %{north: nil, east: nil, south: host, west: nil}
      assert Seat.owner?(moved.seats[:south])
      assert Seat.vacant?(moved.seats[:north])
      refute Seat.owner?(moved.seats[:north])
    end

    test "a non-host moving someone else gets :not_owner" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :not_owner} = RoomManager.move_seat(room.code, "user2", host, :west)
      assert {:ok, %{positions: %{north: ^host}}} = RoomManager.get_room(room.code)
    end

    test "a non-host moves themselves" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:ok, moved} = RoomManager.move_seat(room.code, "user2", "user2", :south)
      assert moved.positions[:south] == "user2"
      assert moved.positions[:east] == nil
    end

    test "moving onto a taken seat fails with :seat_taken" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :north)
      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :east)
    end

    test "moving onto a held seat fails with :seat_taken" do
      {room, [host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current = Map.fetch!(manager_state.rooms, room.code)
        {:ok, held} = Seat.disconnect(current.seats[:south])
        updated = %{current | seats: Map.put(current.seats, :south, held)}
        %{manager_state | rooms: Map.put(manager_state.rooms, room.code, updated)}
      end)

      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :south)
      assert {:ok, %{positions: %{south: "user3"}}} = RoomManager.get_room(room.code)
    end

    test "an unseated target returns :player_not_in_room" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:error, :player_not_in_room} =
               RoomManager.move_seat(room.code, host, "stranger", :west)
    end

    test "rejects an invalid position" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:error, :invalid_position} = RoomManager.move_seat(room.code, host, host, :middle)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} =
               RoomManager.move_seat(room_code, "user1", "user1", :west)
    end
  end

  defp create_playing_room(metadata \\ %{}) do
    {:ok, room} = RoomManager.create_room("user1", metadata)
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

  # Returns a zero-arity room code generator that yields `codes` in order and
  # then repeats the last one forever. Runs inside the RoomManager process.
  defp sequence_generator(codes) do
    index = :counters.new(1, [])
    codes = List.to_tuple(codes)

    fn ->
      position = :counters.get(index, 1)
      :counters.add(index, 1, 1)
      elem(codes, min(position, tuple_size(codes) - 1))
    end
  end
end
