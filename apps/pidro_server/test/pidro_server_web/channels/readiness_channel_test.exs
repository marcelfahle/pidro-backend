defmodule PidroServerWeb.ReadinessChannelTest do
  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.{GameSupervisor, RoomManager}
  alias PidroServerWeb.GameChannel

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Ready Player #{&1}"}))
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host.id, %{})
    for user <- others, do: RoomManager.join_room(room.code, user.id)

    # Deliberately withhold the fourth channel join: filling the room via HTTP
    # must not start a game while the slow final client is still connecting.
    channels =
      Enum.map(Enum.take(users, 3), fn user ->
        {:ok, socket} = create_socket(user)
        {:ok, reply, joined} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
        {user, reply, joined}
      end)

    %{room: room, channels: channels, last_user: List.last(users)}
  end

  test "late fourth join and staggered confirmations share named snapshots and start only on final ready",
       %{
         room: room,
         channels: channels,
         last_user: last_user
       } do
    [{host, %{readiness: initial} = reply, socket} | rest] = channels
    refute Map.has_key?(reply, :state)
    assert initial.status == :waiting
    assert initial.ready_players == []
    assert initial.room_id == room.id
    assert initial.seats.north.username == host.username
    assert initial.seats.north.display_name == host.display_name
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    {:ok, last_socket} = create_socket(last_user)

    {:ok, last_reply, last_joined} =
      subscribe_and_join(last_socket, GameChannel, "game:#{room.code}")

    assert last_reply.readiness == initial
    refute Map.has_key?(last_reply, :state)
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    ref = push(socket, "ready", %{})
    assert_reply ref, :error, %{reason: "invalid_readiness"}
    ref = push(socket, "ready", %{"room_id" => "old-room", "ready_epoch" => initial.ready_epoch})
    assert_reply ref, :error, %{reason: "stale_readiness", readiness: ^initial}

    params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{readiness: accepted}
    assert accepted.ready_epoch == initial.ready_epoch
    assert accepted.snapshot_revision == initial.snapshot_revision + 1
    assert accepted.ready_players == [:north]
    assert accepted.seats == initial.seats
    assert_push "readiness_updated", ^accepted

    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{readiness: ^accepted}
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    Enum.each(rest ++ [{last_user, last_reply, last_joined}], fn {_user, _reply, joined} ->
      assert {:error, :not_found} = GameSupervisor.get_game(room.code)
      ref = push(joined, "ready", params)
      assert_reply ref, :ok, %{readiness: %{ready_epoch: epoch}}
      assert epoch == initial.ready_epoch
    end)

    assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
    assert {:ok, pid} = GameSupervisor.get_game(room.code)
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{readiness: %{status: :playing}}
    assert {:ok, ^pid} = GameSupervisor.get_game(room.code)
  end

  test "ready after room closure omits readiness instead of inventing an incomplete roster", %{
    room: room,
    channels: [{_host, %{readiness: initial}, socket} | _]
  } do
    assert :ok = RoomManager.close_room(room.code)
    ref = push(socket, "ready", %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch})
    assert_reply ref, :error, response
    assert response == %{reason: "room_not_found"}
  end

  test "roster replacement rejects old intent with the current full snapshot", %{
    room: room,
    channels: channels
  } do
    [{host, %{readiness: initial}, socket}, {second, _, _} | _] = channels
    params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{}
    assert :ok = RoomManager.leave_room(second.id)
    replacement = AccountsFixtures.user_fixture(%{display_name: "Replacement"})
    {:ok, _, :east} = RoomManager.join_room(room.code, replacement.id)

    ref = push(socket, "ready", params)
    assert_reply ref, :error, %{reason: "stale_readiness", readiness: current}
    assert current.ready_epoch > initial.ready_epoch
    assert current.ready_players == []
    assert current.positions.north == host.id
    assert current.positions.east == replacement.id
    assert current.seats.east.display_name == "Replacement"
    assert_push "readiness_updated", ^current
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
  end
end
