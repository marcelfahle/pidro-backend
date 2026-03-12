defmodule PidroServer.Games.OwnershipPromotionTest do
  @moduledoc """
  Tests for ownership auto-promotion when the owner disconnects permanently
  (Phase 3) or explicitly leaves a :playing room.

  Promotion priority: partner first (N↔S, E↔W), then remaining positions
  sorted by joined_at. If no connected humans remain, returns {:no_humans, room}.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.Room.Seat

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()

    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  # Creates a room with 4 players in :playing state.
  # user1 is always the host/owner.
  defp create_playing_room do
    {:ok, room} = RoomManager.create_room("user1", %{name: "Ownership Test"})
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

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  defp owner_position(room) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if Seat.owner?(seat), do: pos
    end)
  end

  defp partner_position(:north), do: :south
  defp partner_position(:south), do: :north
  defp partner_position(:east), do: :west
  defp partner_position(:west), do: :east

  # Disconnect and trigger Phase 2 + Phase 3 for a player (makes bot permanent).
  defp trigger_full_cascade(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    # Phase 2: bot spawns
    send(GenServer.whereis(RoomManager), {:phase2_start, room_code, position})
    {:ok, _} = RoomManager.get_room(room_code)

    # Phase 3: bot permanent
    send(GenServer.whereis(RoomManager), {:phase3_gone, room_code, position})
    {:ok, updated_room} = RoomManager.get_room(room_code)

    {updated_room, position}
  end

  # Disconnect and trigger Phase 2 only (bot substitute, still reclaimable).
  defp trigger_phase2(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    send(GenServer.whereis(RoomManager), {:phase2_start, room_code, position})
    {:ok, updated_room} = RoomManager.get_room(room_code)

    {updated_room, position}
  end

  describe "owner disconnect (Phase 3) promotes partner" do
    test "partner is promoted to owner when owner's bot becomes permanent" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)
      partner_pos = partner_position(owner_pos)
      partner_user_id = room.seats[partner_pos].user_id

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      # Full cascade on owner (user1)
      {updated_room, _pos} = trigger_full_cascade(room.code, "user1")

      # Partner should now be owner
      assert updated_room.seats[partner_pos].is_owner == true
      assert updated_room.host_id == partner_user_id

      # Old owner seat should not be owner
      assert updated_room.seats[owner_pos].is_owner == false

      # owner_changed event should have been broadcast
      assert_receive {:owner_changed,
                      %{new_owner_id: ^partner_user_id, new_owner_position: ^partner_pos}},
                     500
    end
  end

  describe "owner disconnect promotes opponent if partner also disconnected" do
    test "promotion skips disconnected partner and goes to next connected human" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)
      partner_pos = partner_position(owner_pos)
      partner_user_id = room.seats[partner_pos].user_id

      # Disconnect the partner first (full cascade — permanent bot)
      {_room_after_partner, _} = trigger_full_cascade(room.code, partner_user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      # Now disconnect the owner (full cascade)
      {updated_room, _pos} = trigger_full_cascade(room.code, "user1")

      # Partner is a permanent bot, so one of the opponents should be promoted
      new_owner_pos = owner_position(updated_room)
      assert new_owner_pos != nil
      assert new_owner_pos != owner_pos
      assert new_owner_pos != partner_pos

      new_owner_seat = updated_room.seats[new_owner_pos]
      assert Seat.connected_human?(new_owner_seat)
      assert updated_room.host_id == new_owner_seat.user_id

      # owner_changed event should have been broadcast
      assert_receive {:owner_changed, %{new_owner_id: _, new_owner_position: ^new_owner_pos}},
                     500
    end
  end

  describe "owner reconnect during grace keeps ownership" do
    test "owner reclaims seat during Phase 2 and retains ownership" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)

      # Phase 2 only (bot substitute, still reclaimable)
      {phase2_room, _pos} = trigger_phase2(room.code, "user1")

      # Owner seat should still have is_owner (bot substitute preserves it)
      assert phase2_room.seats[owner_pos].is_owner == true

      # Reconnect during Phase 2
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user1")

      # Owner should retain ownership
      seat = reconnected_room.seats[owner_pos]
      assert seat.is_owner == true
      assert seat.status == :connected
      assert seat.user_id == "user1"
      assert reconnected_room.host_id == "user1"
    end
  end

  describe "explicit leave triggers promotion" do
    test "owner leaving a :playing room promotes next human" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.leave_room("user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Someone else should be owner now
      new_owner_pos = owner_position(updated_room)
      assert new_owner_pos != nil
      assert new_owner_pos != owner_pos

      new_owner_seat = updated_room.seats[new_owner_pos]
      assert Seat.connected_human?(new_owner_seat)
      assert updated_room.host_id == new_owner_seat.user_id

      # owner_changed event
      assert_receive {:owner_changed, %{new_owner_id: _, new_owner_position: _}}, 500
    end
  end

  describe "all humans disconnected returns {:no_humans, room}" do
    test "no promotion when all humans disconnect permanently" do
      {room, _positions} = create_playing_room()

      # Disconnect all 4 players through full cascade
      trigger_full_cascade(room.code, "user1")
      trigger_full_cascade(room.code, "user2")
      trigger_full_cascade(room.code, "user3")
      trigger_full_cascade(room.code, "user4")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # All seats should be bots with no reserved_for
      for {_pos, seat} <- updated_room.seats do
        assert seat.occupant_type == :bot
        assert seat.reserved_for == nil
      end

      # No seat should be owner (or the original owner seat still has is_owner but is a bot)
      connected_owner =
        Enum.find(updated_room.seats, fn {_pos, seat} ->
          Seat.owner?(seat) && Seat.connected_human?(seat)
        end)

      assert connected_owner == nil
    end

    test "all non-owner humans disconnect first, then owner — no connected owner remains" do
      {room, _positions} = create_playing_room()

      # Disconnect non-owners first
      trigger_full_cascade(room.code, "user2")
      trigger_full_cascade(room.code, "user3")
      trigger_full_cascade(room.code, "user4")

      # Owner is still connected
      {:ok, mid_room} = RoomManager.get_room(room.code)
      owner_pos = owner_position(mid_room)
      assert mid_room.seats[owner_pos].user_id == "user1"
      assert Seat.connected_human?(mid_room.seats[owner_pos])

      # Now disconnect owner — no one left to promote to
      trigger_full_cascade(room.code, "user1")

      {:ok, final_room} = RoomManager.get_room(room.code)

      # No connected human should be owner
      connected_humans =
        Enum.filter(final_room.seats, fn {_pos, seat} ->
          Seat.connected_human?(seat)
        end)

      assert connected_humans == []
    end
  end
end
