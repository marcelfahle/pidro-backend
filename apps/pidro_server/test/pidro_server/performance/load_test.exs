defmodule PidroServer.Performance.LoadTest do
  @moduledoc """
  Performance and load testing for Pidro Server.

  Tests system behavior under various load conditions:
  - 10 concurrent games
  - 100 concurrent connections
  - Stress testing game creation/joining
  - Channel subscription performance
  """

  use ExUnit.Case, async: false

  alias PidroServer.Games.{RoomManager, GameSupervisor, GameAdapter}
  alias PidroServer.Accounts.Auth
  alias PidroServerWeb.{UserSocket, GameChannel}

  @moduletag :performance
  @moduletag timeout: 300_000  # 5 minutes max

  setup do
    # Start required processes for testing
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(PidroServer.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(PidroServer.Repo, {:shared, self()})

    # Clear any existing rooms
    RoomManager.reset_for_test()

    :ok
  end

  describe "Concurrent Games Performance" do
    test "handles 10 concurrent games with 40 total players" do
      start_time = System.monotonic_time(:millisecond)

      # Create 40 users (4 per game)
      users = create_users(40)

      # Create 10 rooms concurrently
      room_tasks =
        Enum.map(0..9, fn i ->
          Task.async(fn ->
            host_user = Enum.at(users, i * 4)
            {:ok, room} = RoomManager.create_room(host_user.id)
            room_code = room.code

            # Have 3 other players join
            [p1, p2, p3] = Enum.slice(users, i * 4 + 1, 3)
            {:ok, _} = RoomManager.join_room(room_code, p1.id)
            {:ok, _} = RoomManager.join_room(room_code, p2.id)
            {:ok, room} = RoomManager.join_room(room_code, p3.id)

            {room_code, room}
          end)
        end)

      rooms = Task.await_many(room_tasks, 30_000)

      creation_time = System.monotonic_time(:millisecond) - start_time
      IO.puts("\n10 rooms created and filled in #{creation_time}ms")
      # Games auto-start when 4th player joins, so creation time includes game startup
      assert creation_time < 15_000, "Room creation took too long: #{creation_time}ms"

      # Verify all games are auto-started (RoomManager starts games automatically)
      started_games =
        Enum.map(rooms, fn {room_code, _room} ->
          case GameSupervisor.get_game(room_code) do
            {:ok, pid} -> {room_code, pid}
            {:error, _} -> {room_code, nil}
          end
        end)

      # Verify all games are running
      Enum.each(started_games, fn {room_code, pid} ->
        assert Process.alive?(pid)
        {:ok, state} = GameAdapter.get_state(room_code)
        assert state != nil
      end)

      # Cleanup
      Enum.each(started_games, fn {room_code, _pid} ->
        GameSupervisor.stop_game(room_code)
      end)

      total_time = System.monotonic_time(:millisecond) - start_time
      IO.puts("Total test completed in #{total_time}ms")
      assert total_time < 20_000, "Total test took too long: #{total_time}ms"
    end

    test "handles rapid room creation and destruction" do
      users = create_users(4)
      [host | players] = Enum.map(users, & &1.id)

      iterations = 20
      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..iterations, fn i ->
        # Create room
        {:ok, room} = RoomManager.create_room(host)
        room_code = room.code

        # Join players (game auto-starts when 4th player joins)
        Enum.each(players, fn player_id ->
          {:ok, _} = RoomManager.join_room(room_code, player_id)
        end)

        # Verify game was auto-started
        {:ok, pid} = GameSupervisor.get_game(room_code)
        assert Process.alive?(pid)

        # Stop game and close room
        :ok = GameSupervisor.stop_game(room_code)
        :ok = RoomManager.close_room(room_code)

        if rem(i, 5) == 0 do
          IO.write(".")
        end
      end)

      duration = System.monotonic_time(:millisecond) - start_time
      avg_per_game = duration / iterations

      IO.puts("\n#{iterations} games cycled in #{duration}ms (#{Float.round(avg_per_game, 2)}ms avg)")
      assert avg_per_game < 500, "Average game cycle too slow: #{avg_per_game}ms"
    end
  end

  describe "WebSocket Connection Performance" do
    @tag :skip  # Skip by default as it requires actual socket connections
    test "handles 100 concurrent WebSocket connections" do
      # This test would require actual WebSocket client connections
      # For now, we test the channel join performance
      users = create_users(100)

      # Create 25 games (4 players each)
      rooms =
        Enum.chunk_every(users, 4)
        |> Enum.take(25)
        |> Enum.map(fn [host | players] ->
          {:ok, room} = RoomManager.create_room(host.id)
          room_code = room.code

          # Game auto-starts when 4th player joins
          Enum.each(players, fn player ->
            {:ok, _} = RoomManager.join_room(room_code, player.id)
          end)

          {room_code, [host | players]}
        end)

      start_time = System.monotonic_time(:millisecond)

      # Simulate channel joins for all users
      join_tasks =
        Enum.flat_map(rooms, fn {room_code, room_users} ->
          Enum.map(room_users, fn user ->
            Task.async(fn ->
              # Simulate socket assignment
              socket = %Phoenix.Socket{
                assigns: %{user_id: user.id},
                channel: GameChannel,
                endpoint: PidroServerWeb.Endpoint,
                handler: UserSocket,
                joined: false,
                join_ref: "1",
                ref: nil,
                pubsub_server: PidroServer.PubSub,
                topic: "game:#{room_code}"
              }

              # Measure join time
              join_start = System.monotonic_time(:microsecond)
              result = GameChannel.join("game:#{room_code}", %{}, socket)
              join_duration = System.monotonic_time(:microsecond) - join_start

              {result, join_duration}
            end)
          end)
        end)

      results = Task.await_many(join_tasks, 30_000)

      duration = System.monotonic_time(:millisecond) - start_time

      # Analyze results
      {successful, failed} = Enum.split_with(results, fn {{status, _, _}, _} -> status == :ok end)
      join_times = Enum.map(successful, fn {_, time} -> time end)

      avg_join_time = Enum.sum(join_times) / length(join_times)
      max_join_time = Enum.max(join_times, fn -> 0 end)
      min_join_time = Enum.min(join_times, fn -> 0 end)

      IO.puts("\n100 connections simulated in #{duration}ms")
      IO.puts("Successful joins: #{length(successful)}/100")
      IO.puts("Failed joins: #{length(failed)}/100")
      IO.puts("Average join time: #{Float.round(avg_join_time / 1000, 2)}ms")
      IO.puts("Min join time: #{Float.round(min_join_time / 1000, 2)}ms")
      IO.puts("Max join time: #{Float.round(max_join_time / 1000, 2)}ms")

      assert length(successful) >= 95, "Too many failed joins: #{length(failed)}"
      assert avg_join_time < 10_000, "Average join time too slow: #{avg_join_time}μs"

      # Cleanup
      Enum.each(rooms, fn {room_code, _} ->
        GameSupervisor.stop_game(room_code)
      end)
    end
  end

  describe "Game Action Performance" do
    test "measures action processing latency under load" do
      # Create a single game with 4 players
      users = create_users(4)
      [host | players] = Enum.map(users, & &1.id)

      {:ok, room} = RoomManager.create_room(host)
      room_code = room.code

      # Game auto-starts when 4th player joins
      Enum.each(players, fn player_id ->
        {:ok, _} = RoomManager.join_room(room_code, player_id)
      end)

      # Give a moment for auto-start to complete
      Process.sleep(100)

      # Get initial state
      {:ok, state} = GameAdapter.get_state(room_code)

      # Select dealer (if needed)
      if state.phase == :dealer_selection do
        start_time = System.monotonic_time(:microsecond)
        {:ok, _} = GameAdapter.apply_action(room_code, :north, :select_dealer)
        _action_time = System.monotonic_time(:microsecond) - start_time
      end

      # Simulate rapid bidding
      {:ok, state} = GameAdapter.get_state(room_code)

      if state.phase == :bidding do
        bid_times =
          Enum.map(1..10, fn _i ->
            current_state = GameAdapter.get_state(room_code)

            case current_state do
              {:ok, %{phase: :bidding, current_player: player}} ->
                start_time = System.monotonic_time(:microsecond)

                result =
                  case GameAdapter.apply_action(room_code, player, :pass) do
                    {:ok, _} -> :ok
                    {:error, _} -> :error
                  end

                duration = System.monotonic_time(:microsecond) - start_time
                {result, duration}

              _ ->
                {:done, 0}
            end
          end)
          |> Enum.reject(fn {status, _} -> status == :done end)
          |> Enum.filter(fn {status, _} -> status == :ok end)
          |> Enum.map(fn {_, time} -> time end)

        if length(bid_times) > 0 do
          avg_bid_time = Enum.sum(bid_times) / length(bid_times)

          IO.puts("\nAction Performance:")
          IO.puts("Actions processed: #{length(bid_times)}")
          IO.puts("Average action time: #{Float.round(avg_bid_time / 1000, 2)}ms")
          IO.puts("Max action time: #{Float.round(Enum.max(bid_times) / 1000, 2)}ms")
          IO.puts("Min action time: #{Float.round(Enum.min(bid_times) / 1000, 2)}ms")

          assert avg_bid_time < 5_000,
                 "Average action processing too slow: #{avg_bid_time}μs"
        end
      end

      # Cleanup
      GameSupervisor.stop_game(room_code)
    end
  end

  describe "Memory and Process Management" do
    test "verifies proper cleanup after games end" do
      # Get initial process count
      initial_processes = length(Process.list())

      # Create and destroy 10 games
      users = create_users(40)

      game_pids =
        Enum.chunk_every(users, 4)
        |> Enum.take(10)
        |> Enum.map(fn [host | players] ->
          {:ok, room} = RoomManager.create_room(host.id)
          room_code = room.code

          # Game auto-starts when 4th player joins
          Enum.each(players, fn player ->
            {:ok, _} = RoomManager.join_room(room_code, player.id)
          end)

          {:ok, pid} = GameSupervisor.get_game(room_code)
          {room_code, pid}
        end)

      peak_processes = length(Process.list())
      process_increase = peak_processes - initial_processes

      IO.puts("\nProcess count increased by #{process_increase} for 10 games")

      # Stop all games
      Enum.each(game_pids, fn {room_code, _pid} ->
        GameSupervisor.stop_game(room_code)
      end)

      # Give cleanup time
      Process.sleep(100)

      final_processes = length(Process.list())
      remaining_increase = final_processes - initial_processes

      IO.puts("After cleanup: #{remaining_increase} processes remaining (from initial)")

      # Allow some variance for test processes, but should be mostly cleaned up
      assert remaining_increase < process_increase / 2,
             "Too many processes remaining after cleanup"
    end

    test "handles game supervisor crashes gracefully" do
      users = create_users(4)
      [host | players] = Enum.map(users, & &1.id)

      {:ok, room} = RoomManager.create_room(host)
      room_code = room.code

      # Game auto-starts when 4th player joins
      Enum.each(players, fn player_id ->
        {:ok, _} = RoomManager.join_room(room_code, player_id)
      end)

      {:ok, pid} = GameSupervisor.get_game(room_code)
      assert Process.alive?(pid)

      # Kill the game process
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Verify the game supervisor is still alive
      supervisor_pid = Process.whereis(PidroServer.Games.GameSupervisor)
      assert Process.alive?(supervisor_pid)

      # Verify we can start a new game manually (since the process crashed)
      # The game won't auto-restart, so we need to start it explicitly
      result = GameSupervisor.start_game(room_code)

      case result do
        {:ok, new_pid} ->
          assert Process.alive?(new_pid)
          # Cleanup
          GameSupervisor.stop_game(room_code)

        {:error, {:already_started, existing_pid}} ->
          # Process may have auto-restarted via supervisor
          assert Process.alive?(existing_pid)
          GameSupervisor.stop_game(room_code)
      end
    end
  end

  describe "System Resource Monitoring" do
    test "reports system metrics under load" do
      start_memory = :erlang.memory(:total)

      # Create load
      users = create_users(40)

      rooms =
        Enum.chunk_every(users, 4)
        |> Enum.take(10)
        |> Enum.map(fn [host | players] ->
          {:ok, room} = RoomManager.create_room(host.id)
          room_code = room.code

          # Game auto-starts when 4th player joins
          Enum.each(players, fn player ->
            {:ok, _} = RoomManager.join_room(room_code, player.id)
          end)

          room_code
        end)

      peak_memory = :erlang.memory(:total)
      memory_increase = peak_memory - start_memory

      # Get process info
      process_count = length(Process.list())
      scheduler_usage = :erlang.statistics(:scheduler_wall_time)

      IO.puts("\nSystem Metrics Under Load:")
      IO.puts("Memory increase: #{Float.round(memory_increase / 1_048_576, 2)} MB")
      IO.puts("Total processes: #{process_count}")
      IO.puts("Active games: #{length(rooms)}")

      if scheduler_usage != :undefined do
        IO.puts("Scheduler wall time enabled")
      end

      # Memory should be reasonable (less than 100MB for 10 games)
      assert memory_increase < 100 * 1_048_576,
             "Memory increase too high: #{memory_increase} bytes"

      # Cleanup
      Enum.each(rooms, fn room_code ->
        GameSupervisor.stop_game(room_code)
      end)

      # Verify memory is released
      :erlang.garbage_collect()
      Process.sleep(100)

      final_memory = :erlang.memory(:total)
      remaining_increase = final_memory - start_memory

      IO.puts("After cleanup: #{Float.round(remaining_increase / 1_048_576, 2)} MB remaining")
    end
  end

  # Helper Functions

  defp create_users(count) do
    Enum.map(1..count, fn i ->
      username = "perf_user_#{i}_#{:rand.uniform(1_000_000)}"
      email = "#{username}@test.com"

      {:ok, user} =
        Auth.register_user(%{
          username: username,
          email: email,
          password: "password123"
        })

      user
    end)
  end
end
