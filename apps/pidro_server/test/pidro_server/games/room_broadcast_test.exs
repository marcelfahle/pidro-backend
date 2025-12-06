defmodule PidroServer.Games.RoomBroadcastTest do
  use PidroServerWeb.ChannelCase

  alias PidroServer.Games.RoomManager
  alias PidroServer.AccountsFixtures
  alias PidroServerWeb.LobbyChannel
  alias PidroServerWeb.UserSocket

  setup do
    RoomManager.reset_for_test()

    # Create a user for the test socket
    user = AccountsFixtures.user_fixture()
    {:ok, socket} = create_socket(user)

    {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby")
    %{socket: socket}
  end

  test "broadcasting room update when player leaves", %{socket: _socket} do
    # 1. Create Room
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Test Room"})
    room_code = room.code

    # 2. Add 3 more players to make it full
    p2 = AccountsFixtures.user_fixture()
    p3 = AccountsFixtures.user_fixture()
    p4 = AccountsFixtures.user_fixture()

    {:ok, _, _} = RoomManager.join_room(room_code, p2.id)
    {:ok, _, _} = RoomManager.join_room(room_code, p3.id)
    {:ok, _, _} = RoomManager.join_room(room_code, p4.id)

    # Wait for the game start broadcast (to ensure we are synced)
    assert_push "room_updated", %{room: %{status: :playing, player_count: 4}}

    # Verify room is full
    {:ok, room} = RoomManager.get_room(room_code)
    alias PidroServer.Games.Room.Positions
    assert Positions.count(room) == 4
    # Game starts when 4 players join
    assert room.status == :playing

    # Clear messages received so far
    flush_messages()

    # 3. Player 4 leaves
    :ok = RoomManager.leave_room(p4.id)

    # Verify list_rooms returns correct state (simulate Lobby join)
    available_rooms = RoomManager.list_rooms(:available)
    room_after_leave = Enum.find(available_rooms, &(&1.code == room_code))
    assert Positions.count(room_after_leave) == 3

    # 4. Verify broadcast
    assert_push "room_updated", payload

    assert payload.room.code == room_code
    assert payload.room.player_count == 3
    assert length(payload.room.seats) == 4

    # Verify seat 3 is now free (since p4 joined last, he should be at index 3)
    # Note: This assumes RoomManager appends to list.
    seat3 = Enum.find(payload.room.seats, &(&1.seat_index == 3))
    assert seat3.status == "free"
    assert seat3.player == nil

    # Verify other seats are still occupied
    seat0 = Enum.find(payload.room.seats, &(&1.seat_index == 0))
    assert seat0.status == "occupied"
    assert seat0.player.id == host.id
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
