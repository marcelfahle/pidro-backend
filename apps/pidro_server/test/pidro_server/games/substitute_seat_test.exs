defmodule PidroServer.Games.SubstituteSeatTest do
  @moduledoc """
  Tests for the substitute seat flow (Phase 8).

  Owner can open bot-filled seats for human substitutes, strangers can join
  :playing rooms with vacant seats, and owner can close vacant seats back to bots.
  """

  use ExUnit.Case, async: false

  alias PidroServer.Games.RoomManager

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
  # Returns the room struct and a map of position => user_id.
  defp create_playing_room do
    {:ok, room} = RoomManager.create_room("user1", %{name: "Substitute Test"})
    {:ok, _, _} = RoomManager.join_room(room.code, "user2")
    {:ok, _, _} = RoomManager.join_room(room.code, "user3")
    {:ok, _, _} = RoomManager.join_room(room.code, "user4")
    {:ok, playing_room} = RoomManager.get_room(room.code)

    assert playing_room.status == :playing

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

  # Disconnects a player and runs them through the cascade to :bot_substitute.
  defp make_seat_bot_substitute(room, user_id) do
    position = position_for(room, user_id)
    :ok = RoomManager.handle_player_disconnect(room.code, user_id)

    # Trigger Phase 2: bot substitution
    send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
    {:ok, room_after_p2} = RoomManager.get_room(room.code)

    {room_after_p2, position}
  end

  describe "open_seat — owner opens a bot-filled seat" do
    test "owner can open a bot_substitute seat — seat becomes vacant" do
      {room, _positions} = create_playing_room()

      # Pick a non-owner player to disconnect and cascade to bot_substitute
      non_owner_id = "user2"
      {room_with_bot, position} = make_seat_bot_substitute(room, non_owner_id)

      # Verify seat is bot_substitute before opening
      seat = room_with_bot.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot

      # Owner opens the seat
      {:ok, updated_room} = RoomManager.open_seat(room.code, position, "user1")

      opened_seat = updated_room.seats[position]
      assert opened_seat.occupant_type == :vacant
      assert opened_seat.status == nil
      assert opened_seat.bot_pid == nil
      assert opened_seat.user_id == nil
    end

    test "non-owner cannot open a seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # user3 is not the owner
      assert {:error, :not_owner} = RoomManager.open_seat(room.code, position, "user3")
    end

    test "cannot open a seat that isn't bot_substitute" do
      {room, _positions} = create_playing_room()

      # Try to open a connected human seat
      position = position_for(room, "user2")

      assert {:error, :seat_not_bot_substitute} =
               RoomManager.open_seat(room.code, position, "user1")
    end

    test "cannot open a seat in a non-playing room" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})

      assert {:error, :room_not_playing} =
               RoomManager.open_seat(room.code, :north, "user1")
    end

    test "opening a seat terminates the bot process" do
      {room, _positions} = create_playing_room()
      {room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      bot_pid = room_with_bot.seats[position].bot_pid
      assert is_pid(bot_pid)
      assert Process.alive?(bot_pid)

      {:ok, _updated_room} = RoomManager.open_seat(room.code, position, "user1")

      # Bot process should be terminated
      refute Process.alive?(bot_pid)
    end
  end

  describe "join_as_substitute — stranger joins a playing room with vacant seat" do
    test "stranger can join a playing room with a vacant seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # Owner opens the seat
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      # Stranger joins
      {:ok, updated_room, joined_position} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert joined_position == position

      seat = updated_room.seats[joined_position]
      assert seat.occupant_type == :human
      assert seat.status == :connected
      assert seat.user_id == "stranger1"
    end

    test "substitute is placed in the correct position in positions map" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      {:ok, updated_room, joined_position} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert updated_room.positions[joined_position] == "stranger1"
    end

    test "cannot join as substitute when no vacant seat exists" do
      {room, _positions} = create_playing_room()

      # All seats are occupied by humans — no vacant seats
      assert {:error, :no_vacant_seat} =
               RoomManager.join_as_substitute(room.code, "stranger1")
    end

    test "cannot join as substitute in a non-playing room" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})

      assert {:error, :room_not_playing} =
               RoomManager.join_as_substitute(room.code, "stranger1")
    end
  end

  describe "close_seat — owner closes a vacant seat back to bot" do
    test "owner can close a vacant seat back to bot" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      # Verify seat is vacant
      {:ok, open_room} = RoomManager.get_room(room.code)
      assert open_room.seats[position].occupant_type == :vacant

      # Owner closes the seat
      {:ok, updated_room} = RoomManager.close_seat(room.code, position, "user1")

      closed_seat = updated_room.seats[position]
      assert closed_seat.occupant_type == :bot
      assert closed_seat.status == :bot_substitute
      assert is_pid(closed_seat.bot_pid)
      assert Process.alive?(closed_seat.bot_pid)
      assert closed_seat.reserved_for == nil
    end

    test "non-owner cannot close a seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      assert {:error, :not_owner} = RoomManager.close_seat(room.code, position, "user3")
    end

    test "cannot close a seat that isn't vacant" do
      {room, _positions} = create_playing_room()

      # Seat is occupied by a human, not vacant
      position = position_for(room, "user2")

      assert {:error, :seat_not_vacant} =
               RoomManager.close_seat(room.code, position, "user1")
    end
  end

  describe "full substitute seat flow end-to-end" do
    test "disconnect → bot → open → substitute joins → seat filled" do
      {room, _positions} = create_playing_room()

      # Step 1: Player disconnects and gets bot substituted
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # Step 2: Owner opens the seat
      {:ok, opened_room} = RoomManager.open_seat(room.code, position, "user1")
      assert opened_room.seats[position].occupant_type == :vacant

      # Step 3: Stranger joins as substitute
      {:ok, final_room, joined_pos} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert joined_pos == position
      assert final_room.seats[position].user_id == "stranger1"
      assert final_room.seats[position].occupant_type == :human
      assert final_room.seats[position].status == :connected
    end

    test "open seat broadcasts substitute_available event" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      assert_receive {:substitute_available, %{position: ^position}}
    end

    test "close seat broadcasts substitute_seat_closed event" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _} = RoomManager.close_seat(room.code, position, "user1")

      assert_receive {:substitute_seat_closed, %{position: ^position}}
    end

    test "substitute_joined is broadcast when stranger joins" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _, _} = RoomManager.join_as_substitute(room.code, "stranger1")

      assert_receive {:substitute_joined, %{position: ^position, user_id: "stranger1"}}
    end
  end
end
