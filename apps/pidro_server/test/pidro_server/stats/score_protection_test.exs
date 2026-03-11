defmodule PidroServer.Stats.ScoreProtectionTest do
  @moduledoc """
  Tests for score recording with disconnected and substitute players.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.RoomManager
  alias PidroServer.Stats
  alias PidroServer.Stats.{AbandonmentEvent, GameStats}

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

  describe "build_player_results/3" do
    test "records all connected humans as played with correct winners" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert map_size(results) == 4
      assert results["user1"].participation == :played
      assert results["user2"].result == :win
      assert results["user3"].result == :loss
      assert results["user4"].position == :west
    end

    test "records abandoned humans when the substitute bot still carries reserved_for" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, seat} -> Seat.start_grace(seat, DateTime.utc_now()) end)
        |> then(fn {:ok, seat} -> Seat.substitute_bot(seat, bot_pid) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert results["user2"].participation == :abandoned
      assert results["user2"].result == :win

      Process.exit(bot_pid, :kill)
    end

    test "merges permanent bot abandonments back into player results" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, seat} -> Seat.start_grace(seat, DateTime.utc_now()) end)
        |> then(fn {:ok, seat} -> Seat.substitute_bot(seat, bot_pid) end)
        |> then(fn {:ok, seat} -> Seat.make_permanent_bot(seat) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      abandonment_events = [
        %AbandonmentEvent{user_id: "user2", room_code: "ROOM1", position: "south"}
      ]

      results = Stats.build_player_results(seats, :north_south, abandonment_events)

      assert map_size(results) == 4
      assert results["user2"].participation == :abandoned
      assert results["user2"].position == :south

      Process.exit(bot_pid, :kill)
    end

    test "records both the original abandoned player and the substitute human" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: %Seat{
          position: :south,
          occupant_type: :human,
          user_id: "substitute1",
          status: :connected,
          substitute: true
        },
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      abandonment_events = [%{user_id: "user2", position: "south"}]
      results = Stats.build_player_results(seats, :north_south, abandonment_events)

      assert map_size(results) == 5
      assert results["user2"].participation == :abandoned
      assert results["substitute1"].participation == :substitute
      assert results["substitute1"].result == :win
    end
  end

  describe "record_abandonment/3" do
    test "persists one abandonment event per user and room" do
      assert :ok = Stats.record_abandonment("user123", "ABC123", :north)
      assert :ok = Stats.record_abandonment("user123", "ABC123", :north)

      events = Stats.list_abandonments_for_room("ABC123")

      assert length(events) == 1
      assert hd(events).user_id == "user123"
      assert hd(events).position == "north"
    end

    test "user stats exposes abandonment metrics" do
      user_id = Ecto.UUID.generate()

      {:ok, _game_stats} =
        Stats.save_game_result(%{
          room_code: "ROOM1",
          winner: :north_south,
          final_scores: %{north_south: 62, east_west: 45},
          bid_amount: 8,
          bid_team: :north_south,
          duration_seconds: 300,
          completed_at: DateTime.utc_now(),
          player_ids: [user_id],
          player_results: %{
            user_id => %{
              participation: :played,
              result: :win,
              team: :north_south,
              position: :north
            }
          }
        })

      assert :ok = Stats.record_abandonment(user_id, "ROOM1", :north)

      stats = Stats.get_user_stats(user_id)

      assert stats.games_played == 1
      assert stats.games_abandoned == 1
      assert stats.abandonment_rate == 1.0
      assert %DateTime{} = stats.last_abandoned_at
    end
  end

  describe "completed game persistence" do
    test "persists original players and substitutes exactly once on game_over" do
      user1 = Ecto.UUID.generate()
      user2 = Ecto.UUID.generate()
      user3 = Ecto.UUID.generate()
      user4 = Ecto.UUID.generate()
      substitute = Ecto.UUID.generate()

      {:ok, room} = RoomManager.create_room(user1, %{name: "Score Protection"})
      {:ok, _, _} = RoomManager.join_room(room.code, user2)
      {:ok, _, _} = RoomManager.join_room(room.code, user3)
      {:ok, _, _} = RoomManager.join_room(room.code, user4)

      {:ok, playing_room} = RoomManager.get_room(room.code)
      position = position_for(playing_room, user2)

      :ok = RoomManager.handle_player_disconnect(room.code, user2)
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, _} = RoomManager.open_seat(room.code, position, user1)
      {:ok, _, ^position} = RoomManager.join_as_substitute(room.code, substitute)

      game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)
      send(GenServer.whereis(RoomManager), game_over)

      saved_game =
        wait_until(fn ->
          Repo.get_by(GameStats, room_code: room.code)
        end)

      assert saved_game.winner == "north_south"
      assert map_size(saved_game.player_results) == 5
      assert saved_game.player_results[user2]["participation"] == "abandoned"
      assert saved_game.player_results[substitute]["participation"] == "substitute"

      assert Enum.sort(saved_game.player_ids) ==
               Enum.sort([user1, user2, user3, user4, substitute])

      assert Repo.aggregate(GameStats, :count) == 1
    end

    test "pre-start abandonment does not record a game or abandonment" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      assert :ok = RoomManager.leave_room("user2")

      assert Stats.list_abandonments_for_room(room.code) == []
      assert Repo.get_by(GameStats, room_code: room.code) == nil
    end
  end

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end
end
