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
          # Ace: 1 point
          {:north, {14, :hearts}},
          # Jack: 1 point
          {:east, {11, :hearts}},
          # Ten: 1 point
          {:south, {10, :hearts}},
          # Seven: 0 points
          {:west, {7, :hearts}}
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
          # Right 5: 5 points
          {:north, {5, :hearts}},
          # 2 of trump: 1 point (kept by player)
          {:east, {2, :hearts}},
          # Ten: 1 point (wins - highest card)
          {:south, {10, :hearts}},
          # Four: 0 points
          {:west, {4, :hearts}}
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      # 10 beats Right 5 in trump ranking
      assert result.winner == :south
      # Right 5 + Ten (2 is kept by East)
      assert result.winner_points == 6
      assert result.two_of_trump_player == :east
      assert result.two_of_trump_points == 1
    end

    test "handles 2 of trump played by winner" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          # Ace: 1 point (wins)
          {:north, {14, :hearts}},
          # 2 of trump: 1 point (kept by player)
          {:east, {2, :hearts}},
          # Three: 0 points
          {:south, {3, :hearts}},
          # Four: 0 points
          {:west, {4, :hearts}}
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      assert result.winner == :north
      # Ace (2 is kept by East)
      assert result.winner_points == 1
      assert result.two_of_trump_player == :east
      assert result.two_of_trump_points == 1
    end

    test "handles 2 of trump when it's the only card" do
      trick = %Types.Trick{
        number: 1,
        leader: :north,
        plays: [
          # 2 of trump: 1 point (only card, so "wins")
          {:north, {2, :hearts}}
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      # Only player
      assert result.winner == :north
      # Winner is also 2 player, so gets 0 as winner
      assert result.winner_points == 0
      assert result.two_of_trump_player == :north
      # But keeps 1 as 2 player
      assert result.two_of_trump_points == 1
    end

    test "scores trick with both 5s" do
      trick = %Types.Trick{
        number: 1,
        leader: :south,
        plays: [
          # Right 5: 5 points
          {:south, {5, :hearts}},
          # Wrong 5: 5 points
          {:west, {5, :diamonds}},
          # Ten: 1 point
          {:north, {10, :hearts}},
          # Jack: 1 point (wins - highest rank 11)
          {:east, {11, :hearts}}
        ]
      }

      result = Scorer.score_trick(trick, :hearts)

      # Jack (rank 11) beats 10, beats Right 5, beats Wrong 5
      assert result.winner == :east
      # Right 5 + Wrong 5 + Ten + Jack
      assert result.winner_points == 12
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

      # 8 is highest
      assert result.winner == :south
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

      # North: 5, South: 2
      assert result.north_south == 7
      # East: 7
      assert result.east_west == 7
    end

    test "aggregates scores with 2 of trump played" do
      tricks = [
        %{winner: :north, winner_points: 5, two_of_trump_player: :east, two_of_trump_points: 1},
        %{winner: :east, winner_points: 6, two_of_trump_player: nil, two_of_trump_points: 0},
        %{winner: :south, winner_points: 1, two_of_trump_player: :west, two_of_trump_points: 1}
      ]

      result = Scorer.aggregate_team_scores(tricks)

      # North: 5, South: 1
      assert result.north_south == 6
      # East: 6+1 (2 of trump), West: 1 (2 of trump)
      assert result.east_west == 8
    end

    test "handles same player winning and playing 2 of trump" do
      tricks = [
        %{winner: :north, winner_points: 6, two_of_trump_player: :north, two_of_trump_points: 1}
      ]

      result = Scorer.aggregate_team_scores(tricks)

      # 6 as winner + 1 for 2 of trump
      assert result.north_south == 7
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

      # 15 + 9
      assert result.cumulative_scores.north_south == 24
      # 20 + 5
      assert result.cumulative_scores.east_west == 25
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

      # 30 + 7
      assert result.cumulative_scores.north_south == 37
      # 40 + 7
      assert result.cumulative_scores.east_west == 47
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

      # 15 + 8
      assert result.cumulative_scores.north_south == 23
      # 20 - 10
      assert result.cumulative_scores.east_west == 10
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

      # 8 - 12
      assert result.cumulative_scores.north_south == -4
      # 30 + 9
      assert result.cumulative_scores.east_west == 39
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

  describe "total_available_points/1" do
    test "returns 14 when no cards have been killed" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{}
      }

      assert Scorer.total_available_points(state) == 14
    end

    test "returns 14 when only non-point cards are killed" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          north: [{13, :hearts}],
          # King (0 points)
          east: [{12, :hearts}, {9, :hearts}]
          # Queen, 9 (both 0 points)
        }
      }

      assert Scorer.total_available_points(state) == 14
    end

    test "excludes point value of killed cards that are not the top card" do
      # North killed King (top, 0 pts) and 10 (2nd, 1 pt)
      # Only the 10 is excluded, King will be played
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          north: [{13, :hearts}, {10, :hearts}]
        }
      }

      assert Scorer.total_available_points(state) == 13
    end

    test "handles multiple players with killed point cards" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          # Top: King (0 pts, played), Out: 10 (1 pt)
          north: [{13, :hearts}, {10, :hearts}],
          # Top: Ace (1 pt, played), Out: Jack (1 pt)
          east: [{14, :hearts}, {11, :hearts}]
        }
      }

      # 14 - 1 (10) - 1 (Jack) = 12
      assert Scorer.total_available_points(state) == 12
    end

    test "handles killed right-5 and wrong-5 (5 points each)" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          # Top: King (0 pts), Out: Right-5 (5 pts)
          north: [{13, :hearts}, {5, :hearts}],
          # Top: Queen (0 pts), Out: Wrong-5 (5 pts)
          south: [{12, :hearts}, {5, :diamonds}]
        }
      }

      # 14 - 5 (Right-5) - 5 (Wrong-5) = 4
      assert Scorer.total_available_points(state) == 4
    end

    test "handles killed 2 of trump (1 point)" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          # Top: King (0 pts), Out: 2 (1 pt)
          north: [{13, :hearts}, {2, :hearts}]
        }
      }

      # 14 - 1 (2 of trump) = 13
      assert Scorer.total_available_points(state) == 13
    end

    test "handles player with only one killed card (top card will be played)" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          # Top: Ace (1 pt) - will be played, not excluded
          north: [{14, :hearts}]
        }
      }

      # 14 - 0 = 14 (Ace will be played)
      assert Scorer.total_available_points(state) == 14
    end

    test "handles complex scenario with multiple players and various point cards" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :clubs,
        killed_cards: %{
          # Top: King, Out: Ace (1), 10 (1)
          north: [{13, :clubs}, {14, :clubs}, {10, :clubs}],
          # Top: Queen - will be played
          east: [{12, :clubs}],
          # Top: 9, Out: Jack (1), 2 (1)
          south: [{9, :clubs}, {11, :clubs}, {2, :clubs}],
          # No killed cards
          west: []
        }
      }

      # 14 - 1 (Ace) - 1 (10) - 1 (Jack) - 1 (2) = 10
      assert Scorer.total_available_points(state) == 10
    end

    test "handles empty killed_cards for specific positions" do
      state = %Types.GameState{
        players: create_test_players(),
        trump_suit: :hearts,
        killed_cards: %{
          north: [],
          east: [{13, :hearts}, {10, :hearts}],
          # Empty list
          # Top: King, Out: 10 (1 pt)
          south: [],
          west: []
        }
      }

      # 14 - 1 (10 from east) = 13
      assert Scorer.total_available_points(state) == 13
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
