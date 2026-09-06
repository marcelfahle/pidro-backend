defmodule PidroServer.Games.ReadinessTest do
  use ExUnit.Case, async: false

  alias PidroServer.Games.{GameSupervisor, RoomManager}
  alias PidroServer.RoomFixtures

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  test "four human joins wait; staggered confirmations share an epoch and start exactly once" do
    {room, users} = RoomFixtures.waiting_room_fixture(seated: 4)
    assert room.status == :waiting
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
    {:ok, initial} = RoomManager.readiness(room.code)
    assert initial.ready_players == []
    assert map_size(initial.seats) == 4
    assert initial.seats.north.user_id == hd(users)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

    for user <- users, do: RoomManager.register_game_channel(room.code, user, self())

    users
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.each(fn {user, count} ->
      assert {:ok, snapshot} = ready(room, user, initial.ready_epoch)
      assert snapshot.ready_epoch == initial.ready_epoch
      assert snapshot.snapshot_revision == initial.snapshot_revision + count
      assert length(snapshot.ready_players) == count
      assert snapshot.status == :waiting
      assert_receive {:readiness_updated, ^snapshot}
      assert {:ok, ^snapshot} = ready(room, user, initial.ready_epoch)
      refute_receive {:readiness_updated, _}, 0
      assert {:error, :not_found} = GameSupervisor.get_game(room.code)
    end)

    assert {:ok, playing} = ready(room, List.last(users), initial.ready_epoch)
    assert playing.status == :playing
    assert playing.ready_epoch == initial.ready_epoch
    assert playing.snapshot_revision == initial.snapshot_revision + 5
    assert_receive {:readiness_updated, %{status: :ready}}
    assert_receive {:readiness_updated, ^playing}
    assert {:ok, game_pid} = GameSupervisor.get_game(room.code)

    for user <- users, do: assert({:ok, ^playing} = ready(room, user, initial.ready_epoch))
    refute_receive {:readiness_updated, _}, 0
    assert {:ok, ^game_pid} = GameSupervisor.get_game(room.code)
  end

  test "rejects wrong room incarnation, epoch, identity, and incomplete tables without mutation" do
    {room, [host]} = RoomFixtures.waiting_room_fixture()
    RoomManager.register_game_channel(room.code, host, self())
    {:ok, snapshot} = RoomManager.readiness(room.code)

    assert {:error, :stale_readiness, ^snapshot} =
             RoomManager.confirm_ready(room.code, "old-room", host, self(), snapshot.ready_epoch)

    assert {:error, :stale_readiness, ^snapshot} = ready(room, host, snapshot.ready_epoch + 1)
    assert {:error, :stale_identity, ^snapshot} = ready(room, "spectator", snapshot.ready_epoch)
    assert {:error, :table_not_full, ^snapshot} = ready(room, host, snapshot.ready_epoch)
    assert {:ok, ^snapshot} = RoomManager.readiness(room.code)
  end

  test "leave, seat move and replacement invalidate all prior intent" do
    {room, [host, second | _]} = RoomFixtures.waiting_room_fixture(seated: 4)
    RoomManager.register_game_channel(room.code, host, self())
    {:ok, initial} = RoomManager.readiness(room.code)
    {:ok, accepted} = ready(room, host, initial.ready_epoch)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

    assert :ok = RoomManager.leave_room(second)
    assert_receive {:readiness_updated, left}
    assert left.ready_epoch == accepted.ready_epoch + 1
    assert left.snapshot_revision == accepted.snapshot_revision + 1
    assert left.ready_players == []
    assert left.seats.east.occupant_type == :vacant
    assert {:ok, moved} = RoomManager.move_seat(room.code, host, host, :east)
    assert moved.ready_epoch == left.ready_epoch + 1
    assert_receive {:readiness_updated, %{ready_players: [], positions: %{east: ^host}}}
    assert {:ok, _, :north} = RoomManager.join_room(room.code, "replacement", :north)
    {:ok, current} = RoomManager.readiness(room.code)
    assert current.ready_epoch == moved.ready_epoch + 1
    assert {:error, :stale_readiness, ^current} = ready(room, host, initial.ready_epoch)
    assert {:error, :stale_identity, ^current} = ready(room, second, current.ready_epoch)
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
  end

  for close <- [:unregister, :down] do
    test "#{close}: only the last channel resets readiness; reconnect stays pending" do
      {room, [host | _]} = RoomFixtures.waiting_room_fixture(seated: 4)

      other =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(other), do: send(other, :stop) end)
      RoomManager.register_game_channel(room.code, host, self())
      RoomManager.register_game_channel(room.code, host, other)
      {:ok, initial} = RoomManager.readiness(room.code)
      {:ok, accepted} = ready(room, host, initial.ready_epoch)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert :channels_remaining = RoomManager.unregister_game_channel(room.code, host, self())
      assert {:ok, ^accepted} = RoomManager.readiness(room.code)
      refute_receive {:room_updated, _}, 0
      refute_receive {:seat_lifecycle, _}, 0

      if unquote(close) == :unregister do
        assert :last_channel_closed = RoomManager.unregister_game_channel(room.code, host, other)
      else
        send(other, :stop)
      end

      assert_receive {:readiness_updated, disconnected}
      assert disconnected.ready_epoch == initial.ready_epoch + 1
      assert disconnected.ready_players == []
      assert disconnected.seats.north.status == :reconnecting
      assert_receive {:room_updated, %{seats: %{north: %{status: :reconnecting}}}}
      assert_receive {:seat_lifecycle, %{seats: %{north: %{status: :reconnecting}}}}
      assert :not_registered = RoomManager.unregister_game_channel(room.code, host, other)
      assert {:ok, ^disconnected} = RoomManager.readiness(room.code)
      refute_receive {:room_updated, _}, 0
      refute_receive {:seat_lifecycle, _}, 0

      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, host)
      assert_receive {:readiness_updated, reconnected}
      assert reconnected.ready_epoch == disconnected.ready_epoch
      assert reconnected.snapshot_revision == disconnected.snapshot_revision + 1
      assert reconnected.seats.north.status == :connected
      assert reconnected.ready_players == []
      assert reconnected.status == :waiting
      assert {:error, :stale_identity, ^reconnected} = ready(room, host, reconnected.ready_epoch)
      RoomManager.register_game_channel(room.code, host, self())
      assert {:error, :stale_readiness, ^reconnected} = ready(room, host, initial.ready_epoch)
      assert {:ok, %{ready_players: [:north]}} = ready(room, host, reconnected.ready_epoch)
      assert {:error, :not_found} = GameSupervisor.get_game(room.code)
    end
  end

  test "new identities cannot ready an already playing table" do
    {room, _} = RoomFixtures.waiting_room_fixture(seated: 4)
    RoomFixtures.ready_room(room.code)
    {:ok, _} = RoomManager.dev_set_position(room.code, :east, "replacement")
    RoomManager.register_game_channel(room.code, "replacement", self())
    {:ok, snapshot} = RoomManager.readiness(room.code)

    assert {:error, :room_not_waiting, ^snapshot} =
             ready(room, "replacement", snapshot.ready_epoch)

    assert {:ok, ^snapshot} = RoomManager.readiness(room.code)
  end

  test "a queued final confirmation cannot start before a dead channel's DOWN is handled" do
    {room, [host, second, third, last]} = RoomFixtures.waiting_room_fixture(seated: 4)

    channel =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(channel)
    RoomManager.register_game_channel(room.code, host, channel)

    for user <- [second, third, last],
        do: RoomManager.register_game_channel(room.code, user, self())

    {:ok, snapshot} = RoomManager.readiness(room.code)
    {:ok, _} = RoomManager.confirm_ready(room.code, room.id, host, channel, snapshot.ready_epoch)
    for user <- [second, third], do: ready(room, user, snapshot.ready_epoch)

    manager = Process.whereis(RoomManager)
    :sys.suspend(manager)
    ref = make_ref()

    try do
      # This call is queued BEFORE DOWN, so monitor handling cannot hide a dead
      # registration from the final start gate. No sleeps or scheduler races.
      send(
        manager,
        {:"$gen_call", {self(), ref},
         {:confirm_ready, room.code, room.id, last, self(), snapshot.ready_epoch}}
      )

      send(channel, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^channel, :normal}
    after
      :sys.resume(manager)
    end

    assert_receive {^ref, {:ok, %{status: status}}}
    refute status == :playing
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
    {:ok, reset} = RoomManager.readiness(room.code)
    assert reset.ready_epoch == snapshot.ready_epoch + 1
    assert reset.ready_players == []
  end

  test "a registered dead PID cannot submit a queued readiness intent" do
    {room, [host | _]} = RoomFixtures.waiting_room_fixture(seated: 4)

    channel =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(channel)
    RoomManager.register_game_channel(room.code, host, channel)
    {:ok, snapshot} = RoomManager.readiness(room.code)
    manager = Process.whereis(RoomManager)
    :sys.suspend(manager)
    ref = make_ref()

    try do
      send(
        manager,
        {:"$gen_call", {self(), ref},
         {:confirm_ready, room.code, room.id, host, channel, snapshot.ready_epoch}}
      )

      send(channel, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^channel, :normal}
    after
      :sys.resume(manager)
    end

    assert_receive {^ref, {:error, :stale_identity, ^snapshot}}
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
  end

  test "an all-bot table starts on final trusted bot seating and broadcasts to the lobby" do
    {:ok, room} = RoomManager.create_room("dev_host", %{})
    {:ok, _} = RoomManager.dev_set_position(room.code, :north, nil)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    for position <- [:north, :east, :south, :west] do
      assert {:ok, _, ^position} =
               RoomManager.join_bot(room.code, "bot_#{position}", self(), position)
    end

    assert_receive {:room_updated, %{status: :playing}}

    assert {:ok, %{status: :playing, ready_players: [:east, :north, :south, :west]}} =
             RoomManager.readiness(room.code)

    assert {:ok, _} = GameSupervisor.get_game(room.code)
  end

  test "practice bots survive waiting-room events but a bot-like human ID still needs confirmation" do
    {:ok, room} = RoomManager.create_room("bot_human", %{})

    for position <- [:east, :south, :west] do
      pid =
        start_supervised!(
          {PidroServer.Games.Bots.BotPlayer,
           room_code: room.code, position: position, paused?: true},
          id: position
        )

      before = :sys.get_state(pid)

      for event <- [:invite_redeemed, :seat_moved, :kicked] do
        send(pid, {event, %{user_id: "human", position: :north}})
        assert :sys.get_state(pid) == before
      end
    end

    {:ok, snapshot} = RoomManager.readiness(room.code)
    assert snapshot.ready_players == [:east, :south, :west]
    assert snapshot.status == :waiting
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
    assert {:error, :stale_identity, ^snapshot} = ready(room, "bot_human", snapshot.ready_epoch)
    RoomManager.register_game_channel(room.code, "bot_human", self())
    assert {:ok, %{status: :playing}} = ready(room, "bot_human", snapshot.ready_epoch)
  end

  defp ready(room, user, epoch),
    do: RoomManager.confirm_ready(room.code, room.id, user, self(), epoch)
end
