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

  use ExUnit.Case, async: false

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
end
