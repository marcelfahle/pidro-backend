defmodule PidroServer.Games.SpectatorLifecycleTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.RoomFixtures
  alias PidroServerWeb.API.RoomJSON

  setup tags do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    {room, _} = RoomFixtures.waiting_room_fixture(seated: 4)
    if tags[:locked], do: RoomManager.set_locked(room.code, "host", true)
    room = RoomFixtures.ready_room(room.code)
    %{room: room}
  end

  test "multiple transports, repeated unregister and stale expiry preserve a reconnected watch",
       %{room: room} do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    initial_timer = timer(room.code)
    pid = spawn_channel()
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", self())
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", self())
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", pid)
    assert map_size(state().spectator_monitors) == 2

    assert :channels_remaining =
             RoomManager.unregister_spectator_channel(room.code, "watcher", pid)

    assert :not_registered = RoomManager.unregister_spectator_channel(room.code, "watcher", pid)
    assert timer(room.code) == nil
    expire(room.code, initial_timer)
    assert RoomManager.is_spectator?(room.code, "watcher")

    assert :last_channel_closed =
             RoomManager.unregister_spectator_channel(room.code, "watcher", self())

    disconnected_timer = timer(room.code)
    assert is_reference(disconnected_timer)
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", pid)
    expire(room.code, disconnected_timer)
    assert RoomManager.is_spectator?(room.code, "watcher")
    assert timer(room.code) == nil
  end

  test "spectator channel registration normalizes room codes", %{room: room} do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    lowercase = String.downcase(room.code)
    assert :ok = RoomManager.register_spectator_channel(lowercase, "watcher", self())
    assert timer(room.code) == nil

    assert :last_channel_closed =
             RoomManager.unregister_spectator_channel(lowercase, "watcher", self())

    assert is_reference(timer(room.code))
    expire(room.code, timer(room.code))
    refute RoomManager.is_spectator?(room.code, "watcher")
  end

  test "never attached and killed watchers release capacity after fenced grace expiry", %{
    room: room
  } do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    expire(room.code, timer(room.code))
    refute RoomManager.is_spectator?(room.code, "watcher")

    assert {:error, :not_spectating} =
             RoomManager.register_spectator_channel(room.code, "watcher", self())

    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    pid = spawn_channel()
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # Wait for RoomManager's independent monitor, not just the test process's monitor.
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if is_reference(timer(room.code)), do: {:halt, :ok}, else: {:cont, Process.sleep(10)}
    end)

    assert is_reference(timer(room.code))
    assert RoomManager.is_spectator?(room.code, "watcher")
    expire(room.code, timer(room.code))
    refute RoomManager.is_spectator?(room.code, "watcher")
    assert state().spectator_monitors == %{}
  end

  test "old channel and timer cannot delete rewatch, another room's watch, or a promoted player",
       %{room: room} do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    old_timer = timer(room.code)
    old_pid = spawn_channel()
    :ok = RoomManager.register_spectator_channel(room.code, "watcher", old_pid)
    [{old_ref, _}] = Map.to_list(state().spectator_monitors)
    :ok = RoomManager.leave_spectator(room.code, "watcher")
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    new_timer = timer(room.code)

    assert :not_registered =
             RoomManager.unregister_spectator_channel(room.code, "watcher", old_pid)

    send(RoomManager, {:DOWN, old_ref, :process, old_pid, :normal})
    expire(room.code, old_timer)
    assert timer(room.code) == new_timer
    assert RoomManager.is_spectator?(room.code, "watcher")

    :ok = RoomManager.leave_spectator(room.code, "watcher")
    {other, _} = RoomFixtures.waiting_room_fixture(seated: 4, host_id: "other", prefix: "other")
    RoomFixtures.ready_room(other.code)
    {:ok, _} = RoomManager.join_spectator_room(other.code, "watcher")
    assert {:error, :not_spectating} = RoomManager.leave_spectator(room.code, "watcher")
    expire(room.code, new_timer)
    assert RoomManager.is_spectator?(other.code, "watcher")

    :ok = RoomManager.leave_room("user2")
    {:ok, _} = RoomManager.open_seat(room.code, :east, "host")
    {:ok, promoted, :east} = RoomManager.join_room(room.code, "watcher")
    refute "watcher" in promoted.spectator_ids
    refute RoomManager.is_spectator?(other.code, "watcher")
    send(RoomManager, {:DOWN, old_ref, :process, old_pid, :normal})
    expire(room.code, old_timer)

    assert :not_registered =
             RoomManager.unregister_spectator_channel(room.code, "watcher", old_pid)

    assert state().rooms[room.code].seats.east.status == :connected
    assert state().player_rooms["watcher"] == room.code
    refute Map.has_key?(state().spectator_rooms, "watcher")
  end

  test "failed claims preserve watch; successful competing claims are exclusive and published once",
       %{room: room} do
    for user <- ["watcher", "competitor"],
        do: assert({:ok, _} = RoomManager.join_spectator_room(room.code, user))

    assert {:error, :no_vacant_seat} = RoomManager.join_room(room.code, "watcher")
    :ok = RoomManager.leave_room("user2")
    {:ok, opened} = RoomManager.open_seat(room.code, :east, "host")
    assert RoomManager.is_spectator?(room.code, "watcher")
    assert is_reference(timer(room.code))
    assert RoomManager.available_positions(opened) == [:east]
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

    results =
      ["watcher", "competitor"]
      |> Task.async_stream(&RoomManager.join_room(room.code, &1), ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, :east}, &1)) == 1
    assert Enum.count(results, &match?({:error, :no_vacant_seat}, &1)) == 1
    {:ok, final, :east} = Enum.find(results, &match?({:ok, _, _}, &1))
    winner = final.positions.east
    assert {:error, :already_seated} = RoomManager.join_room(room.code, winner)
    refute winner in final.spectator_ids
    assert length(final.spectator_ids) == 1
    assert final.seat_lifecycle_revision == opened.seat_lifecycle_revision + 1
    assert_receive {:seat_lifecycle, snapshot}
    assert snapshot.revision == final.seat_lifecycle_revision
    refute_receive {:seat_lifecycle, _}
    assert RoomJSON.show(%{room: final}).data.room.available_positions == []
    assert RoomManager.list_lobby(nil).substitute_needed == []
  end

  @tag locked: true
  test "a locked playing room rejects substitutes without ending watches", %{room: room} do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    :ok = RoomManager.leave_room("user2")
    {:ok, locked} = RoomManager.open_seat(room.code, :east, "host")
    assert RoomManager.available_positions(locked) == []
    assert RoomJSON.show(%{room: locked}).data.room.available_positions == []
    assert RoomManager.list_lobby(nil).substitute_needed == []
    assert Enum.any?(RoomManager.list_lobby(nil).spectatable, &(&1.code == room.code))

    for join <- [&RoomManager.join_room/2, &RoomManager.join_as_substitute/2] do
      assert {:error, :table_locked} = join.(room.code, "watcher")
    end

    assert RoomManager.is_spectator?(room.code, "watcher")
    assert is_reference(timer(room.code))
  end

  test "replacement bots do not advertise vacancies and repeated Watch never consumes capacity",
       %{room: room} do
    :ok = RoomManager.leave_room("user2")
    {:ok, room} = RoomManager.get_room(room.code)
    assert room.positions.east == nil
    assert room.seats.east.occupant_type == :bot
    assert RoomJSON.show(%{room: room}).data.room.available_positions == []
    assert RoomManager.list_lobby(nil).substitute_needed == []
    for _ <- 1..12, do: assert({:ok, _} = RoomManager.join_spectator_room(room.code, "watcher"))
    assert state().rooms[room.code].spectator_ids == ["watcher"]
  end

  test "creating or joining a waiting room ends watching and room closure clears registrations",
       %{room: room} do
    {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
    {:ok, new_room} = RoomManager.create_room("watcher")
    refute RoomManager.is_spectator?(room.code, "watcher")
    {:ok, _} = RoomManager.join_spectator_room(room.code, "guest")
    {:ok, _, _} = RoomManager.join_room(new_room.code, "guest")
    refute RoomManager.is_spectator?(room.code, "guest")
    {:ok, _} = RoomManager.join_spectator_room(room.code, "remaining")
    :ok = RoomManager.register_spectator_channel(room.code, "remaining", self())
    :ok = RoomManager.close_room(room.code)
    assert state().spectator_monitors == %{}
    assert state().spectator_timers == %{}
    assert state().spectator_rooms == %{}
  end

  defp state, do: :sys.get_state(RoomManager)
  defp timer(code), do: state().spectator_timers[{code, "watcher"}]

  defp expire(code, ref) do
    send(RoomManager, {:timeout, ref, {:spectator_expired, code, "watcher"}})
    state()
  end

  defp spawn_channel do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end
end
