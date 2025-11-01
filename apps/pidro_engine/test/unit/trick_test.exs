defmodule Pidro.Core.TrickTest do
  use ExUnit.Case, async: true
  doctest Pidro.Core.Trick

  alias Pidro.Core.Trick

  describe "new/1" do
    test "creates a new empty trick with leader" do
      trick = Trick.new(:north)
      assert trick.leader == :north
      assert trick.plays == []
    end
  end

  describe "add_play/3" do
    test "adds a play to an empty trick" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})

      assert length(trick.plays) == 1
      assert trick.plays == [{:north, {14, :hearts}}]
    end

    test "adds multiple plays in order" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {13, :hearts})
        |> Trick.add_play(:south, {10, :hearts})

      assert length(trick.plays) == 3
      assert trick.plays == [
        {:north, {14, :hearts}},
        {:east, {13, :hearts}},
        {:south, {10, :hearts}}
      ]
    end
  end

  describe "winner/2" do
    test "returns error for empty trick" do
      trick = Trick.new(:north)
      assert Trick.winner(trick, :hearts) == {:error, :incomplete_trick}
    end

    test "highest card wins" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {13, :hearts})

      assert Trick.winner(trick, :hearts) == {:ok, :north}
    end

    test "right 5 beats wrong 5" do
      trick =
        Trick.new(:south)
        |> Trick.add_play(:south, {5, :hearts})
        |> Trick.add_play(:west, {5, :diamonds})

      assert Trick.winner(trick, :hearts) == {:ok, :south}
    end

    test "wrong 5 beats lower cards" do
      trick =
        Trick.new(:east)
        |> Trick.add_play(:east, {4, :hearts})
        |> Trick.add_play(:south, {5, :diamonds})

      assert Trick.winner(trick, :hearts) == {:ok, :south}
    end

    test "2 of trump is lowest trump" do
      trick =
        Trick.new(:west)
        |> Trick.add_play(:west, {2, :hearts})
        |> Trick.add_play(:north, {4, :hearts})

      assert Trick.winner(trick, :hearts) == {:ok, :north}
    end

    test "ace beats all other cards" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {5, :hearts})
        |> Trick.add_play(:south, {5, :diamonds})
        |> Trick.add_play(:west, {13, :hearts})

      assert Trick.winner(trick, :hearts) == {:ok, :north}
    end
  end

  describe "points/2" do
    test "calculates points for ace and jack" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {11, :hearts})

      assert Trick.points(trick, :hearts) == 2
    end

    test "calculates points for right 5" do
      trick =
        Trick.new(:south)
        |> Trick.add_play(:south, {5, :hearts})
        |> Trick.add_play(:west, {10, :hearts})

      assert Trick.points(trick, :hearts) == 6
    end

    test "calculates points for wrong 5" do
      trick =
        Trick.new(:east)
        |> Trick.add_play(:east, {5, :diamonds})
        |> Trick.add_play(:south, {11, :hearts})

      assert Trick.points(trick, :hearts) == 6
    end

    test "subtracts 2 of trump from total (player keeps it)" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {2, :hearts})

      # A(1) + 2(1) = 2, but player with 2 keeps 1, so winner gets 1
      assert Trick.points(trick, :hearts) == 1
    end

    test "handles trick with only 2 of trump" do
      trick =
        Trick.new(:west)
        |> Trick.add_play(:west, {2, :hearts})

      # 2 is worth 1 point, but player keeps it
      assert Trick.points(trick, :hearts) == 0
    end

    test "returns 0 for trick with no point cards" do
      trick =
        Trick.new(:east)
        |> Trick.add_play(:east, {7, :hearts})
        |> Trick.add_play(:south, {9, :hearts})

      assert Trick.points(trick, :hearts) == 0
    end

    test "calculates all point cards including 2" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {11, :hearts})
        |> Trick.add_play(:south, {10, :hearts})
        |> Trick.add_play(:west, {2, :hearts})

      # A(1) + J(1) + 10(1) + 2(1) = 4, but 2 is kept by player, so winner gets 3
      assert Trick.points(trick, :hearts) == 3
    end

    test "calculates maximum points in a trick" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {5, :hearts})
        |> Trick.add_play(:east, {5, :diamonds})
        |> Trick.add_play(:south, {14, :hearts})
        |> Trick.add_play(:west, {11, :hearts})

      # Right5(5) + Wrong5(5) + A(1) + J(1) = 12
      assert Trick.points(trick, :hearts) == 12
    end
  end

  describe "play_count/1" do
    test "returns 0 for empty trick" do
      trick = Trick.new(:north)
      assert Trick.play_count(trick) == 0
    end

    test "returns count of plays" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {10, :hearts})

      assert Trick.play_count(trick) == 2
    end
  end

  describe "complete?/1" do
    test "returns false for empty trick" do
      trick = Trick.new(:north)
      refute Trick.complete?(trick)
    end

    test "returns false for partially complete trick" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {10, :hearts})

      refute Trick.complete?(trick)
    end

    test "returns true for complete trick" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {10, :hearts})
        |> Trick.add_play(:south, {7, :hearts})
        |> Trick.add_play(:west, {3, :hearts})

      assert Trick.complete?(trick)
    end
  end

  describe "card_played_by/2" do
    test "returns error when position hasn't played" do
      trick = Trick.new(:north)
      assert Trick.card_played_by(trick, :east) == {:error, :not_found}
    end

    test "returns card when position has played" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})

      assert Trick.card_played_by(trick, :north) == {:ok, {14, :hearts}}
    end

    test "finds correct card for specific position" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {10, :hearts})
        |> Trick.add_play(:south, {7, :hearts})

      assert Trick.card_played_by(trick, :east) == {:ok, {10, :hearts}}
      assert Trick.card_played_by(trick, :south) == {:ok, {7, :hearts}}
    end
  end

  describe "positions_played/1" do
    test "returns empty list for empty trick" do
      trick = Trick.new(:north)
      assert Trick.positions_played(trick) == []
    end

    test "returns positions that have played" do
      trick =
        Trick.new(:north)
        |> Trick.add_play(:north, {14, :hearts})
        |> Trick.add_play(:east, {10, :hearts})

      assert Trick.positions_played(trick) == [:north, :east]
    end
  end
end
