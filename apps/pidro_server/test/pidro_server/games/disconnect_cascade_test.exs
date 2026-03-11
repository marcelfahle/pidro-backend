defmodule PidroServer.Games.DisconnectCascadeTest do
  @moduledoc """
  Tests for the three-phase disconnect cascade.

  Phase 1 (Hiccup): Player disconnects → seat becomes :reconnecting → timer scheduled
  Phase 2 (Grace): Hiccup timer fires → bot spawned → seat becomes :bot_substitute
  Phase 3 (Gone): Grace timer fires → bot becomes permanent → seat no longer reclaimable

  These tests verify Phase 1 behavior: disconnect triggers :reconnecting state,
  PubSub events are broadcast, reconnect during Phase 1 restores the seat,
  and phase timers are properly scheduled and cancelled.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()

    # BotSupervisor needed for Phase 2 (SubstituteBot spawning)
    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  # Creates a room with 4 players in :playing state.
  # Returns the room struct and a map of position => user_id.
  defp create_playing_room do
    {:ok, room} = RoomManager.create_room("user1", %{name: "Cascade Test"})
    {:ok, _, _} = RoomManager.join_room(room.code, "user2")
    {:ok, _, _} = RoomManager.join_room(room.code, "user3")
    {:ok, _, _} = RoomManager.join_room(room.code, "user4")
    {:ok, playing_room} = RoomManager.get_room(room.code)

    assert playing_room.status == :playing

    # Build position->user_id lookup
    player_positions =
      Enum.reduce(playing_room.seats, %{}, fn {pos, seat}, acc ->
        if seat.user_id, do: Map.put(acc, pos, seat.user_id), else: acc
      end)

    {playing_room, player_positions}
  end

  # Finds the position for a given user_id in the room seats.
  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  describe "Phase 1 (Hiccup) — disconnect triggers reconnecting" do
    test "disconnect marks seat as :reconnecting with disconnected_at set" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[position]

      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at != nil
    end

    test "disconnect does not affect other seats" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)

      for {pos, seat} <- updated_room.seats, pos != position do
        assert seat.status == :connected,
               "Expected seat at #{pos} to remain :connected, got #{seat.status}"
      end
    end

    test "player_reconnecting event is broadcast on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      assert_receive {:player_reconnecting, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "reconnect during Phase 1 restores seat to :connected :human" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      # Verify seat is reconnecting
      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      assert disconnected_room.seats[position].status == :reconnecting

      # Reconnect
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)
      seat = reconnected_room.seats[position]

      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at == nil
    end

    test "reconnect during Phase 1 broadcasts player_reconnected event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      # Drain the disconnect broadcast
      assert_receive {:player_reconnecting, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reconnected, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "phase transition timer is scheduled on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      timer_ref = updated_room.phase_timers[position]

      assert timer_ref != nil
      # Timer should still be active (not yet fired)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 1 cancels the phase timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      timer_ref = disconnected_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      {:ok, reconnected_room} = RoomManager.get_room(room.code)
      # Timer should be cleared from phase_timers
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled (returns false if already cancelled)
      assert Process.cancel_timer(timer_ref) == false
    end

    test "disconnect only triggers cascade for :playing rooms" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      # Room is :waiting, not :playing
      {:ok, waiting_room} = RoomManager.get_room(room.code)
      assert waiting_room.status == :waiting

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      # Seats should NOT have cascade state for :waiting rooms
      user2_position = position_for(waiting_room, "user2")

      if user2_position do
        seat = updated_room.seats[user2_position]
        # Seat should remain :connected (no cascade for :waiting rooms)
        assert seat.status == :connected
      end

      # No phase timers should exist
      assert updated_room.phase_timers == %{}
    end

    test "multiple simultaneous disconnects are independent" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both seats should be independently :reconnecting
      assert updated_room.seats[user2_position].status == :reconnecting
      assert updated_room.seats[user3_position].status == :reconnecting

      # Both should have independent phase timers
      assert updated_room.phase_timers[user2_position] != nil
      assert updated_room.phase_timers[user3_position] != nil

      assert updated_room.phase_timers[user2_position] !=
               updated_room.phase_timers[user3_position]

      # Should receive two independent PubSub events
      assert_receive {:player_reconnecting, %{user_id: "user2", position: ^user2_position}}, 200
      assert_receive {:player_reconnecting, %{user_id: "user3", position: ^user3_position}}, 200
    end

    test "reconnecting one player does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Reconnect user2 only
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # user2 should be back to :connected
      assert updated_room.seats[user2_position].status == :connected

      # user3 should still be :reconnecting with active timer
      assert updated_room.seats[user3_position].status == :reconnecting
      assert updated_room.phase_timers[user3_position] != nil

      # user2's timer should be cleaned up
      assert updated_room.phase_timers[user2_position] == nil
    end

    test "disconnecting host triggers cascade (host seat becomes :reconnecting)" do
      {room, _positions} = create_playing_room()
      host_position = position_for(room, "user1")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[host_position]

      assert seat.status == :reconnecting
      assert seat.is_owner == true
      assert seat.user_id == "user1"
    end
  end

  # Helper: disconnect a player and manually trigger Phase 2 by sending
  # the {:phase2_start, ...} message to RoomManager (bypasses 20s timer).
  # Returns the updated room after Phase 2 completes.
  defp trigger_phase2(room_code, user_id) do
    {_room, position} = disconnect_and_get_position(room_code, user_id)

    # Manually send the Phase 2 timer message
    send(GenServer.whereis(RoomManager), {:phase2_start, room_code, position})

    # Synchronize: get_room is a GenServer.call, ensuring handle_info processed
    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  defp disconnect_and_get_position(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)
    {room, position}
  end

  # Helper: trigger Phase 2 then Phase 3 for a player.
  defp trigger_phase3(room_code, user_id) do
    {_room, position} = trigger_phase2(room_code, user_id)

    # Manually send the Phase 3 timer message
    send(GenServer.whereis(RoomManager), {:phase3_gone, room_code, position})

    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  describe "Phase 2 (Grace) — bot spawned after hiccup timeout" do
    test "Phase 2 spawns a bot — seat becomes :bot_substitute with live bot_pid" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase2(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
      assert seat.reserved_for == user_id
      assert seat.grace_expires_at != nil
      assert seat.user_id == nil
    end

    test "Phase 2 broadcasts bot_substitute_active event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase2(room.code, user_id)

      # Drain the disconnect broadcast first
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, %{position: ^position, user_id: ^user_id}}, 200
    end

    test "Phase 2 schedules Phase 3 timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase2(room.code, "user2")

      timer_ref = updated_room.phase_timers[position]
      assert timer_ref != nil
      # Timer should still be active (Phase 3 hasn't fired yet)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 2 terminates bot and restores seat" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      # Capture bot pid before reconnect
      bot_pid = phase2_room.seats[position].bot_pid
      assert Process.alive?(bot_pid)

      # Reconnect during Phase 2
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      seat = reconnected_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.bot_pid == nil
      assert seat.reserved_for == nil
      assert seat.grace_expires_at == nil

      # Bot process should be dead
      Process.sleep(50)
      refute Process.alive?(bot_pid)
    end

    test "reconnect during Phase 2 cancels Phase 3 timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      timer_ref = phase2_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Timer should be cleared
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled
      assert Process.cancel_timer(timer_ref) == false
    end

    test "reconnect during Phase 2 broadcasts player_reclaimed_seat event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_phase2_room, position} = trigger_phase2(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reclaimed_seat, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "Phase 2 does nothing if player already reconnected (Phase 1)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, disc_room} = RoomManager.get_room(room.code)
      position = position_for(disc_room, user_id)

      # Reconnect during Phase 1
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 2 message (timer would have fired)
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 2 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end
  end

  describe "Phase 3 (Gone) — bot becomes permanent" do
    test "Phase 3 makes bot permanent — reserved_for is nil" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase3(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.reserved_for == nil
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
    end

    test "Phase 3 cleans up phase timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase3(room.code, "user2")

      assert updated_room.phase_timers[position] == nil
    end

    test "Phase 3 broadcasts seat_permanently_botted event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      assert_receive {:seat_permanently_botted, %{position: ^position}}, 200
    end

    test "reconnect during Phase 3 is rejected — seat permanently filled" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {_updated_room, _position} = trigger_phase3(room.code, user_id)

      result = RoomManager.handle_player_reconnect(room.code, user_id)
      assert result == {:error, :seat_permanently_filled}
    end

    test "Phase 3 does nothing if player already reclaimed (Phase 2)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {_phase2_room, position} = trigger_phase2(room.code, user_id)

      # Reconnect during Phase 2
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 3 message (timer would have fired)
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 3 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end

    test "Phase 3 notifies owner about decision when owner is a different connected human" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      assert_receive {:seat_permanently_botted, _}, 200

      # Owner (user1) should get notified since they're still connected
      assert_receive {:owner_decision_available, %{position: ^position, owner_id: "user1"}}, 200
    end
  end

  describe "Multiple disconnects and full lifecycle" do
    test "multiple simultaneous disconnects each have independent cascades through Phase 2" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user2_position})
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user3_position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both should have independent bots
      seat2 = updated_room.seats[user2_position]
      seat3 = updated_room.seats[user3_position]

      assert seat2.status == :bot_substitute
      assert seat3.status == :bot_substitute
      assert seat2.bot_pid != seat3.bot_pid
      assert seat2.reserved_for == "user2"
      assert seat3.reserved_for == "user3"
      assert Process.alive?(seat2.bot_pid)
      assert Process.alive?(seat3.bot_pid)
    end

    test "reclaiming one bot does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user2_position})
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user3_position})
      {:ok, _} = RoomManager.get_room(room.code)

      # Reclaim user2's seat only
      {:ok, updated_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      # user2 should be back
      assert updated_room.seats[user2_position].status == :connected
      assert updated_room.seats[user2_position].user_id == "user2"

      # user3 should still have bot
      assert updated_room.seats[user3_position].status == :bot_substitute
      assert updated_room.seats[user3_position].reserved_for == "user3"
      assert Process.alive?(updated_room.seats[user3_position].bot_pid)
    end

    test "full lifecycle: disconnect → Phase 2 → Phase 3 → rejected reconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      # Phase 1: Disconnect
      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, room1} = RoomManager.get_room(room.code)
      assert room1.seats[position].status == :reconnecting

      # Phase 2: Bot spawns
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, room2} = RoomManager.get_room(room.code)
      assert room2.seats[position].status == :bot_substitute
      assert room2.seats[position].reserved_for == user_id

      # Phase 3: Bot permanent
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, room3} = RoomManager.get_room(room.code)
      assert room3.seats[position].status == :bot_substitute
      assert room3.seats[position].reserved_for == nil

      # Reconnect rejected
      assert {:error, :seat_permanently_filled} =
               RoomManager.handle_player_reconnect(room.code, user_id)
    end
  end
end
