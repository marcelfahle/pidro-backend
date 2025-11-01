defmodule Pidro.Finnish.ScorerTest do
  use ExUnit.Case, async: true

  alias Pidro.Finnish.Scorer
  alias Pidro.Core.Types

  doctest Pidro.Finnish.Scorer

  describe "score_trick/2" do
    test "scores a simple trick without 2 of trump" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {14, :hearts}},  # Ace: 1 point
          {:east, {11, :hearts}},   # Jack: 1 point
          {:south, {10, :hearts}},  # Ten: 1 point
          {:west, {7, :hearts}}     # Seven: 0 points
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :north
      assert result.winner_points == 3
      assert result.two_of_trump_player == nil
      assert result.two_of_trump_points == 0
    end

    test "handles 2 of trump played by non-winner" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {5, :hearts}},   # Right 5: 5 points
          {:east, {2, :hearts}},    # 2 of trump: 1 point (kept by player)
          {:south, {10, :hearts}},  # Ten: 1 point (wins - highest card)
          {:west, {4, :hearts}}     # Four: 0 points
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :south  # 10 beats Right 5 in trump ranking
      assert result.winner_points == 6  # Right 5 + Ten (2 is kept by East)
      assert result.two_of_trump_player == :east
      assert result.two_of_trump_points == 1
    end

    test "handles 2 of trump played by winner" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {14, :hearts}},  # Ace: 1 point (wins)
          {:east, {2, :hearts}},    # 2 of trump: 1 point (kept by player)
          {:south, {3, :hearts}},   # Three: 0 points
          {:west, {4, :hearts}}     # Four: 0 points
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :north
      assert result.winner_points == 1  # Ace (2 is kept by East)
      assert result.two_of_trump_player == :east
      assert result.two_of_trump_points == 1
    end

    test "handles 2 of trump when it's the only card" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          {:north, {2, :hearts}}  # 2 of trump: 1 point (only card, so "wins")
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :north  # Only player
      assert result.winner_points == 0  # Winner is also 2 player, so gets 0 as winner
      assert result.two_of_trump_player == :north
      assert result.two_of_trump_points == 1  # But keeps 1 as 2 player
    end

    test "scores trick with both 5s" do
      trick = %Types.Trick{
        number: 1,
        leader: :south,
        plays: [
          {:south, {5, :hearts}},    # Right 5: 5 points
          {:west, {5, :diamonds}},   # Wrong 5: 5 points
          {:north, {10, :hearts}},   # Ten: 1 point
          {:east, {11, :hearts}}     # Jack: 1 point (wins - highest rank 11)
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :east  # Jack (rank 11) beats 10, beats Right 5, beats Wrong 5
      assert result.winner_points == 12  # Right 5 + Wrong 5 + Ten + Jack
      assert result.two_of_trump_player == nil
      assert result.two_of_trump_points == 0
    end

    test "scores trick with no point cards" do
      trick = %Types.Trick{
        number: 1,
        leader: :east,
        plays: [
          {:east, {7, :hearts}},
          {:south, {8, :hearts}},
          {:west, {6, :hearts}},
          {:north, {4, :hearts}}
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :south  # 8 is highest
      assert result.winner_points == 0
      assert result.two_of_trump_player == nil
      assert result.two_of_trump_points == 0
    end
  end

  describe "aggregate_team_scores/1" do
    test "aggregates scores for multiple tricks without 2 of trump" do
      tricks = [
        %{winner: :north, winner_points: 5, two_of_trump_player: nil, two_of_trump_points: 0},
        %{winner: :east, winner_points: 7, two_of_trump_player: nil, two_of_trump_points: 0},
        %{winner: :south, winner_points: 2, two_of_trump_player: nil, two_of_trump_points: 0}
      ]

      result = Scorer.aggregate_team_scores(tricks)

      assert result.north_south == 7  # North: 5, South: 2
      assert result.east_west == 7    # East: 7
    end

    test "aggregates scores with 2 of trump played" do
      tricks = [
        %{winner: :north, winner_points: 5, two_of_trump_player: :east, two_of_trump_points: 1},
        %{winner: :east, winner_points: 6, two_of_trump_player: nil, two_of_trump_points: 0},
        %{winner: :south, winner_points: 1, two_of_trump_player: :west, two_of_trump_points: 1}
      ]

      result = Scorer.aggregate_team_scores(tricks)

      assert result.north_south == 6  # North: 5, South: 1
      assert result.east_west == 8    # East: 6+1 (2 of trump), West: 1 (2 of trump)
    end

    test "handles same player winning and playing 2 of trump" do
      tricks = [
        %{winner: :north, winner_points: 6, two_of_trump_player: :north, two_of_trump_points: 1}
      ]

      result = Scorer.aggregate_team_scores(tricks)

      assert result.north_south == 7  # 6 as winner + 1 for 2 of trump
      assert result.east_west == 0
    end

    test "handles empty trick list" do
      result = Scorer.aggregate_team_scores([])

      assert result.north_south == 0
      assert result.east_west == 0
    end
  end

  describe "apply_bid_result/1" do
    test "bidding team makes their bid" do
      state = %Types.GameState{
        players: create_test_players(),
        bidding_team: :north_south,
        highest_bid: {:north, 7},
        hand_points: %{north_south: 9, east_west: 5},
        cumulative_scores: %{north_south: 15, east_west: 20},
        events: []
      }

      result = Scorer.apply_bid_result(state)

      assert result.cumulative_scores.north_south == 24  # 15 + 9
      assert result.cumulative_scores.east_west == 25    # 20 + 5
      assert length(result.events) == 2
    end

    test "bidding team exactly makes their bid" do
      state = %Types.GameState{
        players: create_test_players(),
        bidding_team: :east_west,
        highest_bid: {:east, 7},
        hand_points: %{north_south: 7, east_west: 7},
        cumulative_scores: %{north_south: 30, east_west: 40},
        events: []
      }

      result = Scorer.apply_bid_result(state)

      assert result.cumulative_scores.north_south == 37  # 30 + 7
      assert result.cumulative_scores.east_west == 47    # 40 + 7
    end

    test "bidding team fails their bid" do
      state = %Types.GameState{
        players: create_test_players(),
        bidding_team: :east_west,
        highest_bid: {:east, 10},
        hand_points: %{north_south: 8, east_west: 6},
        cumulative_scores: %{north_south: 15, east_west: 20},
        events: []
      }

      result = Scorer.apply_bid_result(state)

      assert result.cumulative_scores.north_south == 23  # 15 + 8
      assert result.cumulative_scores.east_west == 10    # 20 - 10
    end

    test "bidding team can go negative" do
      state = %Types.GameState{
        players: create_test_players(),
        bidding_team: :north_south,
        highest_bid: {:north, 12},
        hand_points: %{north_south: 5, east_west: 9},
        cumulative_scores: %{north_south: 8, east_west: 30},
        events: []
      }

      result = Scorer.apply_bid_result(state)

      assert result.cumulative_scores.north_south == -4  # 8 - 12
      assert result.cumulative_scores.east_west == 39    # 30 + 9
    end

    test "adds scoring events to event history" do
      state = %Types.GameState{
        players: create_test_players(),
        bidding_team: :north_south,
        highest_bid: {:north, 7},
        hand_points: %{north_south: 9, east_west: 5},
        cumulative_scores: %{north_south: 15, east_west: 20},
        events: [{:some_previous_event, :data}]
      }

      result = Scorer.apply_bid_result(state)

      assert length(result.events) == 3
      assert {:hand_scored, :north_south, 9} in result.events
      assert {:hand_scored, :east_west, 5} in result.events
    end
  end

  describe "game_over?/1" do
    test "returns false when no team has reached 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 61, east_west: 58}
      }

      refute Scorer.game_over?(state)
    end

    test "returns true when north_south reaches 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 62, east_west: 58}
      }

      assert Scorer.game_over?(state)
    end

    test "returns true when east_west reaches 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 55, east_west: 62}
      }

      assert Scorer.game_over?(state)
    end

    test "returns true when both teams reach 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 62, east_west: 62}
      }

      assert Scorer.game_over?(state)
    end

    test "returns true when score exceeds 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 70, east_west: 55}
      }

      assert Scorer.game_over?(state)
    end

    test "handles negative scores correctly" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: -10, east_west: 62}
      }

      assert Scorer.game_over?(state)
    end
  end

  describe "determine_winner/1" do
    test "returns north_south when they reach 62 first" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 65, east_west: 58},
        bidding_team: :north_south
      }

      assert {:ok, :north_south} = Scorer.determine_winner(state)
    end

    test "returns east_west when they reach 62 first" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 55, east_west: 63},
        bidding_team: :east_west
      }

      assert {:ok, :east_west} = Scorer.determine_winner(state)
    end

    test "bidding team wins when both teams reach 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 62, east_west: 62},
        bidding_team: :east_west
      }

      assert {:ok, :east_west} = Scorer.determine_winner(state)
    end

    test "bidding team wins when both exceed 62" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 70, east_west: 65},
        bidding_team: :east_west
      }

      assert {:ok, :east_west} = Scorer.determine_winner(state)
    end

    test "returns error when game is not over" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: 61, east_west: 58},
        bidding_team: :north_south
      }

      assert {:error, :game_not_over} = Scorer.determine_winner(state)
    end

    test "handles one team with negative score" do
      state = %Types.GameState{
        players: create_test_players(),
        cumulative_scores: %{north_south: -5, east_west: 62},
        bidding_team: :north_south
      }

      assert {:ok, :east_west} = Scorer.determine_winner(state)
    end
  end

  # Helper function to create test players
  defp create_test_players do
    %{
      north: %Types.Player{position: :north, team: :north_south, hand: []},
      east: %Types.Player{position: :east, team: :east_west, hand: []},
      south: %Types.Player{position: :south, team: :north_south, hand: []},
      west: %Types.Player{position: :west, team: :east_west, hand: []}
    }
  end
end
