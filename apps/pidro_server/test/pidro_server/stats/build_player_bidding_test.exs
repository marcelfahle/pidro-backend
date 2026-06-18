defmodule PidroServer.Stats.BuildPlayerBiddingTest do
  @moduledoc """
  Pure tests for `Stats.build_player_bidding/2` — folding a synthetic
  GameState.events list + seats map into per-player bidding facts (PID-51).
  """

  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Seat
  alias PidroServer.Stats

  defp human_seat(position, user_id) do
    %Seat{
      position: position,
      occupant_type: :human,
      status: :connected,
      user_id: user_id,
      substitute: false
    }
  end

  defp bot_seat(position) do
    %Seat{position: position, occupant_type: :bot, status: :connected, reserved_for: nil}
  end

  defp abandoned_seat(position, reserved_for) do
    %Seat{
      position: position,
      occupant_type: :bot,
      status: :bot_substitute,
      reserved_for: reserved_for
    }
  end

  test "folds three bidding_complete events across four human seats" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    c = Ecto.UUID.generate()
    d = Ecto.UUID.generate()

    seats = %{
      north: human_seat(:north, a),
      east: human_seat(:east, b),
      south: human_seat(:south, c),
      west: human_seat(:west, d)
    }

    events = [
      {:bid_made, :north, 6},
      {:player_passed, :east},
      {:bidding_complete, :north, 7},
      {:bid_made, :east, 9},
      {:bidding_complete, :east, 9},
      {:player_passed, :south},
      {:bidding_complete, :north, 6}
    ]

    result = Stats.build_player_bidding(events, seats)

    assert result[a] == %{"attempts" => 3, "wins" => 2, "won_bid_sum" => 13}
    assert result[b] == %{"attempts" => 3, "wins" => 1, "won_bid_sum" => 9}
    assert result[c] == %{"attempts" => 3, "wins" => 0, "won_bid_sum" => 0}
    assert result[d] == %{"attempts" => 3, "wins" => 0, "won_bid_sum" => 0}
  end

  test "a bot seat is excluded from the map even when it wins a bid" do
    a = Ecto.UUID.generate()

    seats = %{
      north: human_seat(:north, a),
      east: bot_seat(:east)
    }

    events = [
      {:bidding_complete, :north, 7},
      # The bot at :east won this hand — contributes to nobody.
      {:bidding_complete, :east, 8}
    ]

    result = Stats.build_player_bidding(events, seats)

    # Only the human appears; both hands counted as attempts for the human.
    assert Map.keys(result) == [a]
    assert result[a] == %{"attempts" => 2, "wins" => 1, "won_bid_sum" => 7}
  end

  test "an abandoned seat attributes its won bids to reserved_for" do
    original = Ecto.UUID.generate()
    a = Ecto.UUID.generate()

    seats = %{
      north: human_seat(:north, a),
      # original human left; a substitute bot plays under their seat.
      east: abandoned_seat(:east, original)
    }

    events = [
      {:bidding_complete, :north, 6},
      {:bidding_complete, :east, 10}
    ]

    result = Stats.build_player_bidding(events, seats)

    assert result[a] == %{"attempts" => 2, "wins" => 1, "won_bid_sum" => 6}
    assert result[original] == %{"attempts" => 2, "wins" => 1, "won_bid_sum" => 10}
  end

  describe "tolerant base cases → %{}" do
    test "events == nil" do
      assert Stats.build_player_bidding(nil, %{north: human_seat(:north, Ecto.UUID.generate())}) ==
               %{}
    end

    test "events == []" do
      assert Stats.build_player_bidding([], %{north: human_seat(:north, Ecto.UUID.generate())}) ==
               %{}
    end

    test "seats == %{} (no bidding_complete resolvable)" do
      events = [{:bidding_complete, :north, 7}]
      assert Stats.build_player_bidding(events, %{}) == %{}
    end

    test "no bidding_complete present" do
      seats = %{north: human_seat(:north, Ecto.UUID.generate())}
      events = [{:bid_made, :north, 6}, {:player_passed, :east}]
      assert Stats.build_player_bidding(events, seats) == %{}
    end

    test "seats not a map" do
      assert Stats.build_player_bidding([{:bidding_complete, :north, 7}], nil) == %{}
    end
  end
end
