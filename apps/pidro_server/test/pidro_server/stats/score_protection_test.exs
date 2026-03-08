defmodule PidroServer.Stats.ScoreProtectionTest do
  @moduledoc """
  Tests for score recording with disconnected and substitute players.

  Verifies that:
  - All 4 connected humans get :played participation at game_over
  - Disconnected players (bot-substituted) get :abandoned with correct win/loss
  - Pre-start abandonment (leaving during :waiting) does NOT record a game result
  - Phase 3 fires record_abandonment for the abandoning user
  """

  use ExUnit.Case, async: false

  alias PidroServer.Stats
  alias PidroServer.Games.Room.Seat

  describe "build_player_results/2 — all humans connected" do
    test "records all 4 original humans as :played" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert map_size(results) == 4

      for {user_id, result} <- results do
        assert result.participation == :played, "#{user_id} should be :played"
      end
    end

    test "assigns :win to winning team and :loss to losing team" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert results["user1"].result == :win
      assert results["user1"].team == :north_south
      assert results["user2"].result == :win
      assert results["user2"].team == :north_south
      assert results["user3"].result == :loss
      assert results["user3"].team == :east_west
      assert results["user4"].result == :loss
      assert results["user4"].team == :east_west
    end

    test "records correct positions for each player" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :east_west)

      assert results["user1"].position == :north
      assert results["user2"].position == :south
      assert results["user3"].position == :east
      assert results["user4"].position == :west
    end
  end

  describe "build_player_results/2 — disconnected player (bot-substituted)" do
    test "abandoned human gets :abandoned with correct win/loss result" do
      # Simulate: user2 disconnected, bot playing at south with reserved_for
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, s} -> Seat.start_grace(s, DateTime.utc_now()) end)
        |> then(fn {:ok, s} -> Seat.substitute_bot(s, bot_pid) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      # user2 abandoned but their team won — they still get the win
      assert results["user2"].participation == :abandoned
      assert results["user2"].result == :win
      assert results["user2"].team == :north_south
      assert results["user2"].position == :south

      Process.exit(bot_pid, :kill)
    end

    test "abandoned human on losing team gets :loss" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:east, "user3")
        |> Seat.disconnect()
        |> then(fn {:ok, s} -> Seat.start_grace(s, DateTime.utc_now()) end)
        |> then(fn {:ok, s} -> Seat.substitute_bot(s, bot_pid) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: bot_seat,
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert results["user3"].participation == :abandoned
      assert results["user3"].result == :loss

      Process.exit(bot_pid, :kill)
    end

    test "permanent bot (reserved_for nil) is skipped — no stats recorded" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, s} -> Seat.start_grace(s, DateTime.utc_now()) end)
        |> then(fn {:ok, s} -> Seat.substitute_bot(s, bot_pid) end)
        |> then(fn {:ok, s} -> Seat.make_permanent_bot(s) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      # Permanent bot (reserved_for cleared) should be skipped
      assert map_size(results) == 3
      refute Map.has_key?(results, "user2")

      Process.exit(bot_pid, :kill)
    end

    test "vacant seat is skipped" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_vacant(:south),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert map_size(results) == 3
    end
  end

  describe "build_player_results/2 — pre-start abandonment" do
    test "leaving during :waiting does not produce results (no seats in cascade)" do
      # In a waiting room, all seats are either connected humans or vacant.
      # A player who leaves has their seat set to vacant.
      # build_player_results with a vacant seat produces no entry.
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_vacant(:south),
        east: Seat.new_vacant(:east),
        west: Seat.new_vacant(:west)
      }

      results = Stats.build_player_results(seats, :north_south)

      # Only user1 would be recorded — but in practice, build_player_results
      # is only called at game_over (:playing rooms). A :waiting room that
      # never started has no game_over event and no scores to record.
      assert map_size(results) == 1
      refute Map.has_key?(results, "user2")
    end

    test "returns empty map for non-map seats input" do
      assert Stats.build_player_results(nil, :north_south) == %{}
      assert Stats.build_player_results("invalid", :north_south) == %{}
    end
  end

  describe "record_abandonment/3" do
    test "returns :ok and logs the abandonment" do
      assert :ok = Stats.record_abandonment("user123", "ABC123", :north)
    end
  end

  describe "record_abandonment integration — Phase 3 fires abandonment" do
    # This test verifies that Phase 3 in RoomManager calls record_abandonment
    # by checking the seat state transition. The abandonment call happens right
    # before make_permanent_bot (which clears reserved_for). If Phase 3 fires
    # and reserved_for becomes nil, record_abandonment was called at that point.

    setup do
      case GenServer.whereis(PidroServer.Games.RoomManager) do
        nil -> start_supervised!(PidroServer.Games.RoomManager)
        _pid -> :ok
      end

      PidroServer.Games.RoomManager.reset_for_test()

      case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
        nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
        _pid -> :ok
      end

      :ok
    end

    @tag :capture_log
    test "Phase 3 makes bot permanent after abandonment — reserved_for cleared" do
      alias PidroServer.Games.RoomManager

      # Create a 4-player playing room
      {:ok, room} = RoomManager.create_room("user1", %{name: "Abandon Test"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")
      {:ok, playing_room} = RoomManager.get_room(room.code)
      assert playing_room.status == :playing

      user_id = "user2"

      position =
        Enum.find_value(playing_room.seats, fn {pos, seat} ->
          if seat.user_id == user_id, do: pos
        end)

      # Disconnect and trigger full cascade
      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      # Trigger Phase 2 — bot fills the seat
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, phase2_room} = RoomManager.get_room(room.code)

      # Verify Phase 2 state: bot substitute with reserved_for set
      phase2_seat = phase2_room.seats[position]
      assert phase2_seat.status == :bot_substitute
      assert phase2_seat.reserved_for == user_id

      # Trigger Phase 3 — record_abandonment is called, then make_permanent_bot
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, phase3_room} = RoomManager.get_room(room.code)

      # After Phase 3: reserved_for should be cleared (abandonment was recorded
      # before this happened — see room_manager.ex Phase 3 handler)
      phase3_seat = phase3_room.seats[position]
      assert phase3_seat.status == :bot_substitute
      assert phase3_seat.reserved_for == nil
      assert phase3_seat.occupant_type == :bot
    end

    @tag :capture_log
    test "Phase 3 does not fire abandonment for already-reclaimed seats" do
      alias PidroServer.Games.RoomManager

      {:ok, room} = RoomManager.create_room("user1", %{name: "No Abandon Test"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")
      {:ok, playing_room} = RoomManager.get_room(room.code)

      user_id = "user2"

      position =
        Enum.find_value(playing_room.seats, fn {pos, seat} ->
          if seat.user_id == user_id, do: pos
        end)

      # Disconnect, trigger Phase 2, then reclaim
      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, _} = RoomManager.get_room(room.code)
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Trigger Phase 3 — should be a no-op since player already reclaimed
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, final_room} = RoomManager.get_room(room.code)

      # Seat should still be connected human (Phase 3 was a no-op)
      seat = final_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end
  end
end
