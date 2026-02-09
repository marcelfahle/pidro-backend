defmodule Pidro.IExServerGameTest do
  use ExUnit.Case, async: true

  alias Pidro.IEx

  describe "start_server_game/0" do
    test "returns {:ok, pid} with game in bidding phase" do
      {:ok, pid} = IEx.start_server_game()
      assert is_pid(pid)

      state = Pidro.Server.get_state(pid)
      assert state.phase == :bidding
      assert state.current_dealer in [:north, :east, :south, :west]
      assert state.current_turn in [:north, :east, :south, :west]

      GenServer.stop(pid)
    end

    test "each player has 9 cards after initial deal" do
      {:ok, pid} = IEx.start_server_game()
      state = Pidro.Server.get_state(pid)

      for pos <- [:north, :east, :south, :west] do
        player = Map.get(state.players, pos)
        assert length(player.hand) == 9, "#{pos} should have 9 cards, got #{length(player.hand)}"
      end

      GenServer.stop(pid)
    end

    test "accepts options passed through to Server" do
      {:ok, pid} = IEx.start_server_game(game_id: "test-game", telemetry: false)
      assert is_pid(pid)
      GenServer.stop(pid)
    end
  end

  describe "play_full_game/2" do
    test "completes a game with random strategy" do
      {:ok, pid} = IEx.start_server_game()

      {:ok, result} = IEx.play_full_game(pid, IEx.random_strategy())

      assert result.winner in [:north_south, :east_west]
      assert is_map(result.scores)
      assert result.hands_played >= 1

      # Verify the server also reports game over
      assert Pidro.Server.game_over?(pid)

      GenServer.stop(pid)
    end

    test "handles dealer rob (select_hand marker)" do
      # Play a game - the dealer rob is handled internally
      {:ok, pid} = IEx.start_server_game()

      {:ok, result} = IEx.play_full_game(pid, IEx.random_strategy())

      assert result.winner in [:north_south, :east_west]
      GenServer.stop(pid)
    end

    test "handles eliminated players (cold)" do
      # Random play will sometimes cause eliminations; the game should complete
      {:ok, pid} = IEx.start_server_game()

      {:ok, result} = IEx.play_full_game(pid, IEx.random_strategy())

      assert result.winner in [:north_south, :east_west]
      GenServer.stop(pid)
    end

    test "works with raw GameState (no GenServer)" do
      state = IEx.new_game()

      {:ok, result} = IEx.play_full_game(state, IEx.random_strategy())

      assert result.winner in [:north_south, :east_west]
      assert result.hands_played >= 1
    end

    test "10 random games all complete without errors" do
      results =
        for _ <- 1..10 do
          state = IEx.new_game()

          {:ok, result} = IEx.play_full_game(state, IEx.random_strategy())

          result
        end

      assert length(results) == 10

      for result <- results do
        assert result.winner in [:north_south, :east_west]
        assert result.hands_played >= 1
      end
    end

    @tag timeout: 120_000
    test "100 random games all complete without errors" do
      results =
        for _ <- 1..100 do
          state = IEx.new_game()

          {:ok, result} = IEx.play_full_game(state, IEx.random_strategy())

          result
        end

      assert length(results) == 100

      for result <- results do
        assert result.winner in [:north_south, :east_west]
        assert result.hands_played >= 1
      end

      # Report some stats
      total_hands = Enum.sum(Enum.map(results, & &1.hands_played))
      ns_wins = Enum.count(results, &(&1.winner == :north_south))

      IO.puts(
        "\n  100 games: #{ns_wins} N/S wins, #{100 - ns_wins} E/W wins, avg #{Float.round(total_hands / 100, 1)} hands/game"
      )
    end
  end
end
