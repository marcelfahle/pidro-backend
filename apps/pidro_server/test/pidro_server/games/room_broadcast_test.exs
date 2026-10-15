defmodule PidroServer.Games.RoomBroadcastTest do
  use PidroServerWeb.ChannelCase

  alias PidroServer.Games.RoomManager
  alias PidroServer.AccountsFixtures
  alias PidroServerWeb.LobbyChannel

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # Create a user for the test socket
    user = AccountsFixtures.user_fixture()
    {:ok, socket} = create_socket(user)

    {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby")
    %{socket: socket}
  end

  test "lobby reports game progress only when a hand or score changes", %{socket: socket} do
    [host, departed | others] =
      Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Player #{&1}"}))

    {:ok, room} = RoomManager.create_room(host.id)
    assert_push "room_created", %{room: waiting}
    refute Map.has_key?(waiting, :game)
    for user <- [departed | others], do: RoomManager.join_room(room.code, user.id)
    PidroServer.RoomFixtures.ready_room(room.code)
    assert_push "room_updated", %{room: %{status: :playing, game: initial}}
    assert initial == %{hand: 1, scores: %{north_south: 0, east_west: 0}}
    :sys.get_state(socket.channel_pid)
    flush_messages()

    {:ok, snapshot} = PidroServer.Games.GameAdapter.get_snapshot(room.code)
    snapshot = Map.put(snapshot, :transition_delay_ms, 0)

    game = %{
      snapshot.state
      | hand_number: 4,
        cumulative_scores: %{north_south: 34, east_west: 21}
    }

    update = %{snapshot | state: game, state_revision: snapshot.state_revision + 1}
    send(RoomManager, {:state_update, room.code, update})
    assert_push "room_updated", %{room: %{game: progress}}
    assert progress == %{hand: 4, scores: %{north_south: 34, east_west: 21}}
    refute_push "room_updated", _, 50

    # A stale snapshot cannot rewind the row, and an in-hand trick cannot refresh it.
    send(RoomManager, {:state_update, room.code, snapshot})
    trick = %{game | tricks: [%{winner: :east}], current_trick: nil}
    update = %{update | state: trick, state_revision: update.state_revision + 1}
    send(RoomManager, {:state_update, room.code, update})
    refute_push "room_updated", _, 50

    scored = %{game | cumulative_scores: %{north_south: -6, east_west: 35}}
    update = %{update | state: scored, state_revision: update.state_revision + 1}
    send(RoomManager, {:state_update, room.code, update})
    assert_push "room_updated", %{room: %{game: %{hand: 4, scores: scores}}}
    assert scores == %{north_south: -6, east_west: 35}
    refute_push "room_updated", _, 50

    update = %{
      update
      | state: %{scored | hand_number: 5},
        state_revision: update.state_revision + 1
    }

    send(RoomManager, {:state_update, room.code, update})
    assert_push "room_updated", %{room: %{game: %{hand: 5, scores: ^scores}}}
    refute_push "room_updated", _, 50

    :ok = RoomManager.leave_room(departed.id)
    {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)
    assert_push "room_updated", %{category: "substitute_needed", room: opened}
    seat = Enum.find(opened.seats, &(&1.position == :east))
    assert seat.vacated_by == departed.display_name
    replacement = AccountsFixtures.user_fixture()
    {:ok, filled, :east} = RoomManager.join_room(room.code, replacement.id)
    refute Map.has_key?(PidroServerWeb.API.RoomJSON.room(filled).seats.east, :vacated_by)
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
    PidroServer.RoomFixtures.ready_room(room_code)

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
