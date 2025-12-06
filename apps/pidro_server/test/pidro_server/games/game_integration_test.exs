defmodule PidroServer.Games.GameIntegrationTest do
  @moduledoc """
  Integration test for Phase 3: Game Integration

  Tests the full game integration flow:
  - Starting a game via GameSupervisor
  - Applying actions via GameAdapter
  - Retrieving game state
  - PubSub broadcasting
  - Game lifecycle
  """

  use ExUnit.Case, async: true

  alias PidroServer.Games.{GameAdapter, GameSupervisor, RoomManager}

  @moduletag :integration

  setup do
    # The Games.Supervisor is already started by the application
    # No need to start it again in tests
    :ok
  end

  describe "game lifecycle via GameAdapter" do
    test "can start a game and retrieve initial state" do
      room_code = "TEST"

      # Start a game
      assert {:ok, pid} = GameSupervisor.start_game(room_code)
      assert Process.alive?(pid)

      # Get the initial state
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase == :dealer_selection
      assert state.hand_number == 1
      assert state.variant == :finnish
    end

    test "can apply bidding actions and state updates" do
      room_code = "BID1"
      assert {:ok, _pid} = GameSupervisor.start_game(room_code)

      # Get initial state - will be in dealer_selection phase
      assert {:ok, initial_state} = GameAdapter.get_state(room_code)
      assert initial_state.phase == :dealer_selection

      # Select dealer (any player can trigger this)
      assert {:ok, state} = GameAdapter.apply_action(room_code, :north, :select_dealer)

      # After dealer selection, should progress to dealing or bidding
      assert state.phase in [:dealing, :bidding]
      assert state.current_dealer != nil
    end

    test "subscribes to game updates via PubSub" do
      room_code = "PSUB"
      assert {:ok, _pid} = GameSupervisor.start_game(room_code)

      # Subscribe to game updates
      assert :ok = GameAdapter.subscribe(room_code)

      # Get initial state
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase == :dealer_selection

      # Get legal actions for any player
      assert {:ok, actions} = GameAdapter.get_legal_actions(room_code, :north)
      assert length(actions) > 0

      # Apply an action that will trigger a broadcast
      [first_action | _] = actions
      assert {:ok, _new_state} = GameAdapter.apply_action(room_code, :north, first_action)

      # Should receive a state update via PubSub
      assert_receive {:state_update, _updated_state}, 1000

      # Cleanup
      GameAdapter.unsubscribe(room_code)
    end

    test "can get legal actions for a position" do
      room_code = "LEGAL"
      assert {:ok, _pid} = GameSupervisor.start_game(room_code)

      # Get state - will be in dealer_selection phase
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase == :dealer_selection

      # Get legal actions for north player during dealer selection
      assert {:ok, actions} = GameAdapter.get_legal_actions(room_code, :north)

      # During dealer_selection, should only have :select_dealer action
      assert is_list(actions)
      assert :select_dealer in actions
    end

    test "handles invalid actions correctly" do
      room_code = "INV1"
      assert {:ok, _pid} = GameSupervisor.start_game(room_code)

      # Get state
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase == :dealer_selection

      # Try to bid when we're in dealer selection phase (should fail)
      assert {:error, _reason} = GameAdapter.apply_action(room_code, :north, {:bid, 6})
    end

    test "stops a game cleanly" do
      room_code = "STOP"
      assert {:ok, pid} = GameSupervisor.start_game(room_code)
      assert Process.alive?(pid)

      # Stop the game
      assert :ok = GameSupervisor.stop_game(room_code)

      # Give it a moment to fully terminate
      Process.sleep(10)

      # Process should no longer exist
      refute Process.alive?(pid)

      # Getting state should fail - GameAdapter should return :not_found from Registry
      assert {:error, :not_found} = GameAdapter.get_state(room_code)
    end

    test "game lookup via get_game" do
      room_code = "LOOK"
      assert {:ok, pid} = GameSupervisor.start_game(room_code)

      # Should be able to look up the game
      assert {:ok, ^pid} = GameAdapter.get_game(room_code)

      # Non-existent game returns error
      assert {:error, :not_found} = GameAdapter.get_game("NOEXIST")
    end
  end

  describe "full game flow integration" do
    test "complete dealer selection and bidding" do
      room_code = "FULL"
      assert {:ok, _pid} = GameSupervisor.start_game(room_code)

      # Get initial state
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase == :dealer_selection

      # Select dealer
      assert {:ok, state} = GameAdapter.apply_action(room_code, :north, :select_dealer)
      assert state.current_dealer != nil

      # Dealer should be selected, and game should progress
      # The phase should advance automatically or we should be ready to bid
      assert state.phase in [:dealing, :bidding, :declaring]
    end

    test "room manager integration - auto-start game when 4 players join" do
      # Create a room
      assert {:ok, room} = RoomManager.create_room("player1", %{name: "Test Game"})
      room_code = room.code

      # Join 3 more players
      assert {:ok, _, _} = RoomManager.join_room(room_code, "player2")
      assert {:ok, _, _} = RoomManager.join_room(room_code, "player3")
      assert {:ok, room, _} = RoomManager.join_room(room_code, "player4")

      # Room should be ready
      alias PidroServer.Games.Room.Positions
      assert room.status == :ready
      assert Positions.count(room) == 4

      # Game should have auto-started
      # Give it a moment to start
      Process.sleep(100)

      assert {:ok, _pid} = GameAdapter.get_game(room_code)
      assert {:ok, state} = GameAdapter.get_state(room_code)
      assert state.phase in [:dealer_selection, :bidding]
    end
  end

  describe "error handling" do
    test "returns error for non-existent game" do
      assert {:error, :not_found} = GameAdapter.get_state("NOEXIST")
      assert {:error, :not_found} = GameAdapter.apply_action("NOEXIST", :north, {:bid, 6})
      assert {:error, :not_found} = GameAdapter.get_legal_actions("NOEXIST", :north)
    end

    test "handles duplicate game start" do
      room_code = "DUP1"
      assert {:ok, pid1} = GameSupervisor.start_game(room_code)

      # Try to start again - should get already_started error
      assert {:error, {:already_started, pid2}} = GameSupervisor.start_game(room_code)
      assert pid1 == pid2
    end
  end

  ## Helper Functions

  # Unused but kept for potential future test expansion
  # defp next_position(:north), do: :east
  # defp next_position(:east), do: :south
  # defp next_position(:south), do: :west
  # defp next_position(:west), do: :north
end
