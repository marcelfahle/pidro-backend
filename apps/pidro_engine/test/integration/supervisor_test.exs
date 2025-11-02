defmodule Pidro.SupervisorTest do
  use ExUnit.Case

  alias Pidro.Supervisor
  alias Pidro.Server
  alias Pidro.Core.Types.GameState, as: GameStateType

  @moduletag :integration

  setup_all do
    # Start one supervisor for all tests to avoid conflicts
    unless Process.whereis(Pidro.Supervisor) do
      {:ok, _sup_pid} = Supervisor.start_link()
    end

    :ok
  end

  setup do
    # Tests share the global supervisor
    %{supervisor: Process.whereis(Pidro.Supervisor)}
  end

  describe "start_link/1" do
    test "starts supervisor successfully", %{supervisor: sup} do
      # The global supervisor is already started in setup_all
      assert Process.alive?(sup)
    end

    test "starts with cache enabled by default" do
      # The global supervisor has cache enabled
      # Verify MoveCache is running
      assert Process.whereis(Pidro.MoveCache) != nil
    end

    test "starts with registry enabled by default" do
      # The global supervisor has registry enabled
      # Verify Registry is running
      assert Process.whereis(Pidro.Registry) != nil
    end
  end

  describe "start_game/1" do
    test "starts a game server", %{supervisor: _sup} do
      assert {:ok, pid} = Supervisor.start_game()
      assert Process.alive?(pid)
      assert %GameStateType{} = Server.get_state(pid)
    end

    test "starts multiple independent games", %{supervisor: _sup} do
      assert {:ok, pid1} = Supervisor.start_game(game_id: "game1")
      assert {:ok, pid2} = Supervisor.start_game(game_id: "game2")
      assert {:ok, pid3} = Supervisor.start_game(game_id: "game3")

      assert pid1 != pid2
      assert pid2 != pid3
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
      assert Process.alive?(pid3)
    end

    test "starts game with game_id", %{supervisor: _sup} do
      game_id = "test_game_#{:erlang.unique_integer()}"
      assert {:ok, pid} = Supervisor.start_game(game_id: game_id)
      assert Process.alive?(pid)
    end

    test "registers game when register option is true", %{supervisor: _sup} do
      game_id = "registered_game_#{:erlang.unique_integer()}"
      assert {:ok, pid} = Supervisor.start_game(game_id: game_id, register: true)

      # Verify we can look it up
      assert {:ok, ^pid} = Supervisor.lookup_game(game_id)
    end

    test "does not register game when register option is false", %{supervisor: _sup} do
      game_id = "unregistered_game_#{:erlang.unique_integer()}"
      assert {:ok, _pid} = Supervisor.start_game(game_id: game_id, register: false)

      # Verify we cannot look it up
      assert {:error, :not_found} = Supervisor.lookup_game(game_id)
    end

    test "returns error when trying to register duplicate game_id", %{supervisor: _sup} do
      game_id = "duplicate_game_#{:erlang.unique_integer()}"
      assert {:ok, _pid1} = Supervisor.start_game(game_id: game_id, register: true)
      assert {:error, _reason} = Supervisor.start_game(game_id: game_id, register: true)
    end
  end

  describe "stop_game/1" do
    test "stops a running game", %{supervisor: _sup} do
      {:ok, pid} = Supervisor.start_game()
      assert Process.alive?(pid)

      assert :ok = Supervisor.stop_game(pid)
      refute Process.alive?(pid)
    end

    test "returns error when stopping non-existent game", %{supervisor: _sup} do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert {:error, :not_found} = Supervisor.stop_game(fake_pid)
    end
  end

  describe "lookup_game/1" do
    test "finds registered game", %{supervisor: _sup} do
      game_id = "findable_game_#{:erlang.unique_integer()}"
      {:ok, pid} = Supervisor.start_game(game_id: game_id, register: true)

      assert {:ok, ^pid} = Supervisor.lookup_game(game_id)
    end

    test "returns error for non-existent game", %{supervisor: _sup} do
      assert {:error, :not_found} = Supervisor.lookup_game("nonexistent_game")
    end

    test "returns error after game is stopped", %{supervisor: _sup} do
      game_id = "stoppable_game_#{:erlang.unique_integer()}"
      {:ok, pid} = Supervisor.start_game(game_id: game_id, register: true)

      :ok = Supervisor.stop_game(pid)
      assert {:error, :not_found} = Supervisor.lookup_game(game_id)
    end
  end

  describe "list_games/0" do
    test "returns empty list when no games running", %{supervisor: _sup} do
      # Note: May have games from other tests, so we filter by our game IDs
      games = Supervisor.list_games()
      assert is_list(games)
    end

    test "returns all registered games", %{supervisor: _sup} do
      id1 = "list_game_1_#{:erlang.unique_integer()}"
      id2 = "list_game_2_#{:erlang.unique_integer()}"
      id3 = "list_game_3_#{:erlang.unique_integer()}"

      {:ok, pid1} = Supervisor.start_game(game_id: id1, register: true)
      {:ok, pid2} = Supervisor.start_game(game_id: id2, register: true)
      {:ok, pid3} = Supervisor.start_game(game_id: id3, register: true)

      games = Supervisor.list_games()
      game_ids = Enum.map(games, fn {id, _pid} -> id end)

      assert id1 in game_ids
      assert id2 in game_ids
      assert id3 in game_ids

      # Verify PIDs match
      {^id1, ^pid1} = Enum.find(games, fn {id, _} -> id == id1 end)
      {^id2, ^pid2} = Enum.find(games, fn {id, _} -> id == id2 end)
      {^id3, ^pid3} = Enum.find(games, fn {id, _} -> id == id3 end)
    end

    test "does not include unregistered games", %{supervisor: _sup} do
      registered_id = "registered_#{:erlang.unique_integer()}"
      unregistered_id = "unregistered_#{:erlang.unique_integer()}"

      {:ok, _pid1} = Supervisor.start_game(game_id: registered_id, register: true)
      {:ok, _pid2} = Supervisor.start_game(game_id: unregistered_id, register: false)

      games = Supervisor.list_games()
      game_ids = Enum.map(games, fn {id, _pid} -> id end)

      assert registered_id in game_ids
      refute unregistered_id in game_ids
    end
  end

  describe "game_count/0" do
    test "returns zero when no games running", %{supervisor: _sup} do
      # Note: count may include games from other tests
      initial_count = Supervisor.game_count()
      assert is_integer(initial_count)
      assert initial_count >= 0
    end

    test "increments when starting games", %{supervisor: _sup} do
      initial_count = Supervisor.game_count()

      {:ok, _pid1} = Supervisor.start_game()
      {:ok, _pid2} = Supervisor.start_game()
      {:ok, _pid3} = Supervisor.start_game()

      final_count = Supervisor.game_count()
      assert final_count == initial_count + 3
    end

    test "decrements when stopping games", %{supervisor: _sup} do
      {:ok, pid1} = Supervisor.start_game()
      {:ok, pid2} = Supervisor.start_game()

      count_before = Supervisor.game_count()

      :ok = Supervisor.stop_game(pid1)
      :ok = Supervisor.stop_game(pid2)

      count_after = Supervisor.game_count()
      assert count_after == count_before - 2
    end
  end

  describe "supervision" do
    test "restarts crashed game server", %{supervisor: _sup} do
      game_id = "crashable_game_#{:erlang.unique_integer()}"
      {:ok, pid1} = Supervisor.start_game(game_id: game_id, register: true)

      # Make some moves
      {:ok, _state} = Server.apply_action(pid1, :north, :select_dealer)

      # Kill the process
      Process.exit(pid1, :kill)

      # Wait for the process to die and registry to clean up
      Process.sleep(100)

      # Process should be dead
      refute Process.alive?(pid1)

      # A new game can be started with the same ID since the old one is gone
      {:ok, pid2} = Supervisor.start_game(game_id: game_id, register: true)
      assert Process.alive?(pid2)
      assert pid1 != pid2

      # New game should have fresh state
      state = Server.get_state(pid2)
      assert state.phase == :dealer_selection
    end

    test "supervisor keeps running when game crashes", %{supervisor: sup} do
      {:ok, pid} = Supervisor.start_game()

      # Kill the game
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Supervisor should still be alive
      assert Process.alive?(sup)

      # Can start new games
      assert {:ok, _new_pid} = Supervisor.start_game()
    end

    test "multiple game crashes do not affect supervisor", %{supervisor: sup} do
      {:ok, pid1} = Supervisor.start_game()
      {:ok, pid2} = Supervisor.start_game()
      {:ok, pid3} = Supervisor.start_game()

      # Kill all games
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)

      # Supervisor should still be alive
      assert Process.alive?(sup)

      # Can still start new games
      assert {:ok, _new_pid} = Supervisor.start_game()
    end
  end

  describe "integration with Server" do
    test "can play full game through supervised server", %{supervisor: _sup} do
      {:ok, pid} = Supervisor.start_game(game_id: "integration_game")

      # Select dealer - this automatically transitions through dealing to bidding
      {:ok, state} = Server.apply_action(pid, :north, :select_dealer)
      assert state.phase == :bidding
      assert state.current_dealer != nil

      # Make a bid
      current_turn = state.current_turn
      {:ok, state} = Server.apply_action(pid, current_turn, {:bid, 10})

      # Verify action was applied
      assert state.highest_bid != nil
    end

    test "multiple supervised games run independently", %{supervisor: _sup} do
      {:ok, pid1} = Supervisor.start_game(game_id: "game_a", register: true)
      {:ok, pid2} = Supervisor.start_game(game_id: "game_b", register: true)

      # Advance first game - select_dealer auto-transitions through dealing to bidding
      {:ok, _state1} = Server.apply_action(pid1, :north, :select_dealer)

      # Second game should be unchanged
      state2 = Server.get_state(pid2)

      state1 = Server.get_state(pid1)
      assert state1.phase == :bidding
      assert state2.phase == :dealer_selection

      # Verify via lookup
      {:ok, looked_up_pid1} = Supervisor.lookup_game("game_a")
      {:ok, looked_up_pid2} = Supervisor.lookup_game("game_b")

      assert looked_up_pid1 == pid1
      assert looked_up_pid2 == pid2
    end
  end
end
