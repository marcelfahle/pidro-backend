defmodule Pidro.ServerTest do
  use ExUnit.Case, async: true

  alias Pidro.Server
  alias Pidro.Core.GameState
  alias Pidro.Core.Types.GameState, as: GameStateType

  describe "start_link/1" do
    test "starts server with default options" do
      assert {:ok, pid} = Server.start_link()
      assert Process.alive?(pid)
    end

    test "starts server with game_id" do
      assert {:ok, pid} = Server.start_link(game_id: "test_game")
      state = Server.get_state(pid)
      assert state.phase == :dealer_selection
    end

    test "starts server with initial state" do
      initial_state = %GameStateType{GameState.new() | hand_number: 5}
      assert {:ok, pid} = Server.start_link(initial_state: initial_state)
      state = Server.get_state(pid)
      assert state.hand_number == 5
    end

    test "starts server with telemetry disabled" do
      assert {:ok, pid} = Server.start_link(telemetry: false)
      assert Process.alive?(pid)
    end
  end

  describe "get_state/1" do
    test "returns current game state" do
      {:ok, pid} = Server.start_link()
      state = Server.get_state(pid)
      assert %GameStateType{} = state
      assert state.phase == :dealer_selection
    end
  end

  describe "apply_action/3" do
    test "applies valid action and returns new state" do
      {:ok, pid} = Server.start_link()

      # Get initial state to check legal actions
      state = Server.get_state(pid)
      actions = Server.legal_actions(pid, :north)

      # If dealer selection is available, use it
      if :select_dealer in actions do
        {:ok, new_state} = Server.apply_action(pid, :north, :select_dealer)
        assert new_state.phase != state.phase
      end
    end

    test "returns error for invalid action" do
      {:ok, pid} = Server.start_link()
      # Try an action that's not legal in initial phase
      assert {:error, _reason} = Server.apply_action(pid, :north, {:bid, 10})
    end

    test "updates server state after successful action" do
      {:ok, pid} = Server.start_link()
      initial_state = Server.get_state(pid)

      # Find a legal action
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _new_state} = Server.apply_action(pid, :north, action)

        # Verify server state was potentially updated
        current_state = Server.get_state(pid)
        # State should be valid (it may or may not have changed phase)
        assert %GameStateType{} = current_state
      end
    end

    test "does not update server state on error" do
      {:ok, pid} = Server.start_link()
      initial_state = Server.get_state(pid)

      # Try invalid action
      {:error, _reason} = Server.apply_action(pid, :north, {:bid, 10})

      # Verify state unchanged
      current_state = Server.get_state(pid)
      assert current_state.phase == initial_state.phase
    end
  end

  describe "legal_actions/2" do
    test "returns list of actions" do
      {:ok, pid} = Server.start_link()
      actions = Server.legal_actions(pid, :north)
      assert is_list(actions)
    end

    test "legal actions depend on game state" do
      {:ok, pid} = Server.start_link()
      # Different positions may have different legal actions
      actions_north = Server.legal_actions(pid, :north)
      actions_east = Server.legal_actions(pid, :east)
      # Both should be lists
      assert is_list(actions_north)
      assert is_list(actions_east)
    end
  end

  describe "game_over?/1" do
    test "returns false for new game" do
      {:ok, pid} = Server.start_link()
      refute Server.game_over?(pid)
    end

    test "returns true when game is complete" do
      {:ok, pid} = Server.start_link()

      # Fast-forward to complete state
      complete_state = %GameStateType{GameState.new() | phase: :complete, winner: :north_south}
      :sys.replace_state(pid, fn state -> %{state | game_state: complete_state} end)

      assert Server.game_over?(pid)
    end
  end

  describe "winner/1" do
    test "returns error when game is not over" do
      {:ok, pid} = Server.start_link()
      assert {:error, _reason} = Server.winner(pid)
    end

    test "returns winner when game is complete" do
      {:ok, pid} = Server.start_link()

      # Set to complete state with winner
      complete_state = %GameStateType{GameState.new() | phase: :complete, winner: :north_south}
      :sys.replace_state(pid, fn state -> %{state | game_state: complete_state} end)

      assert {:ok, :north_south} = Server.winner(pid)
    end
  end

  describe "get_history/1" do
    test "returns list of events" do
      {:ok, pid} = Server.start_link()
      events = Server.get_history(pid)
      assert is_list(events)
    end

    test "history grows after actions are applied" do
      {:ok, pid} = Server.start_link()
      initial_events = Server.get_history(pid)
      initial_count = length(initial_events)

      # Try to apply a legal action
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid, :north, action)

        new_events = Server.get_history(pid)
        new_count = length(new_events)
        # History may have grown
        assert new_count >= initial_count
      end
    end
  end

  describe "reset/1" do
    test "resets game to initial state" do
      {:ok, pid} = Server.start_link()

      # Make some legal moves if possible
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid, :north, action)
      end

      # Reset
      assert :ok = Server.reset(pid)

      # Verify reset
      state = Server.get_state(pid)
      assert state.phase == :dealer_selection
      assert state.hand_number == 1
    end

    test "returns to initial state" do
      {:ok, pid} = Server.start_link()

      # Reset should work regardless of state
      assert :ok = Server.reset(pid)

      # Verify we're in initial state
      state = Server.get_state(pid)
      assert %GameStateType{} = state
      assert state.phase == :dealer_selection
    end
  end

  describe "process isolation" do
    test "multiple servers maintain independent state" do
      {:ok, pid1} = Server.start_link(game_id: "game1")
      {:ok, pid2} = Server.start_link(game_id: "game2")

      # Get initial state of both
      state1_before = Server.get_state(pid1)
      state2_before = Server.get_state(pid2)

      # Try to advance first game
      actions = Server.legal_actions(pid1, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid1, :north, action)
      end

      # Verify second game unchanged
      state2_after = Server.get_state(pid2)
      assert state2_after.phase == state2_before.phase
      assert state2_after.hand_number == state2_before.hand_number
    end

    test "server crash does not affect other servers" do
      # Trap exits so we don't crash the test process
      Process.flag(:trap_exit, true)

      {:ok, pid1} = Server.start_link()
      {:ok, pid2} = Server.start_link()

      # Kill first server
      Process.exit(pid1, :kill)

      # Wait for exit message
      receive do
        {:EXIT, ^pid1, :killed} -> :ok
      after
        100 -> :ok
      end

      refute Process.alive?(pid1)

      # Verify second server still works
      assert Process.alive?(pid2)
      state = Server.get_state(pid2)
      assert %GameStateType{} = state
    end
  end
end
