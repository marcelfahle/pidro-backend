defmodule PidroServer.PlaystyleTest do
  # async: false — the config-override tests mutate global Application env.
  use ExUnit.Case, async: false

  alias PidroServer.Playstyle

  doctest PidroServer.Playstyle

  @delta 1.0e-9

  describe "bidding_win_rate/2" do
    test "attempts == 0 is :insufficient" do
      assert Playstyle.bidding_win_rate(0, 0) == :insufficient
    end

    test "wins / attempts" do
      assert Playstyle.bidding_win_rate(0, 4) == 0.0
      assert Playstyle.bidding_win_rate(1, 4) == 0.25
      assert Playstyle.bidding_win_rate(2, 4) == 0.5
      assert Playstyle.bidding_win_rate(4, 4) == 1.0
    end
  end

  describe "needle/1 anchors + clamps (defaults low 0.10 / center 0.25 / high 0.40)" do
    test "the three required anchors" do
      assert Playstyle.needle(0.10) == 0.0
      assert Playstyle.needle(0.25) == 0.5
      assert Playstyle.needle(0.40) == 1.0
    end

    test "below-low and above-high clamp" do
      assert Playstyle.needle(0.0) == 0.0
      assert Playstyle.needle(1.0) == 1.0
    end

    test "segment midpoints" do
      assert_in_delta Playstyle.needle(0.175), 0.25, @delta
      assert_in_delta Playstyle.needle(0.325), 0.75, @delta
    end

    test ":insufficient maps to center 0.5" do
      assert Playstyle.needle(:insufficient) == 0.5
    end

    test "every output is within 0.0..1.0" do
      for rate <- [-1.0, 0.0, 0.05, 0.10, 0.175, 0.25, 0.325, 0.40, 0.8, 1.0, 2.0] do
        n = Playstyle.needle(rate)
        assert n >= 0.0 and n <= 1.0
      end
    end
  end

  describe "needle/1 under config override (non-midpoint center)" do
    setup do
      # center 0.30 is NOT the arithmetic midpoint of [0.10, 0.50] (which is 0.30
      # would be... pick 0.20 to be clearly off-midpoint of [0.10, 0.50]).
      Application.put_env(:pidro_server, Playstyle, low: 0.10, center: 0.20, high: 0.50)
      on_exit(fn -> Application.delete_env(:pidro_server, Playstyle) end)
      :ok
    end

    test "the three anchors track the new config" do
      assert Playstyle.needle(0.10) == 0.0
      assert_in_delta Playstyle.needle(0.20), 0.5, @delta
      assert Playstyle.needle(0.50) == 1.0
    end

    test "a point in the lower segment honors the moved center" do
      # midpoint of [0.10, 0.20] → 0.25 on the needle.
      assert_in_delta Playstyle.needle(0.15), 0.25, @delta
    end
  end

  describe "label/1 bands (defaults careful_max 0.34 / aggressive_min 0.66)" do
    test "careful band" do
      assert Playstyle.label(0.0) == :careful
      assert Playstyle.label(0.33) == :careful
    end

    test "balanced band" do
      assert Playstyle.label(0.34) == :balanced
      assert Playstyle.label(0.5) == :balanced
      assert Playstyle.label(0.65) == :balanced
    end

    test "aggressive band" do
      assert Playstyle.label(0.66) == :aggressive
      assert Playstyle.label(1.0) == :aggressive
    end

    test "cutoffs follow config overrides" do
      Application.put_env(:pidro_server, Playstyle, careful_max: 0.5, aggressive_min: 0.9)
      on_exit(fn -> Application.delete_env(:pidro_server, Playstyle) end)

      assert Playstyle.label(0.49) == :careful
      assert Playstyle.label(0.5) == :balanced
      assert Playstyle.label(0.89) == :balanced
      assert Playstyle.label(0.9) == :aggressive
    end
  end

  describe "avg_winning_bid/2" do
    test "count == 0 is nil" do
      assert Playstyle.avg_winning_bid(0, 0) == nil
      assert Playstyle.avg_winning_bid(99, 0) == nil
    end

    test "sum / count" do
      assert Playstyle.avg_winning_bid(30, 4) == 7.5
      assert Playstyle.avg_winning_bid(48, 6) == 8.0
    end
  end

  describe "defaults/0" do
    test "returns the documented keys" do
      keys = Playstyle.defaults() |> Map.keys() |> Enum.sort()
      assert keys == [:aggressive_min, :careful_max, :center, :high, :low]
    end
  end

  describe "degenerate config guard" do
    test "center == low does not raise" do
      Application.put_env(:pidro_server, Playstyle, low: 0.25, center: 0.25, high: 0.40)
      on_exit(fn -> Application.delete_env(:pidro_server, Playstyle) end)

      # A rate between (collapsed) low/center and high stays clamped, no crash.
      n = Playstyle.needle(0.30)
      assert n >= 0.0 and n <= 1.0
    end

    test "center == high does not raise" do
      Application.put_env(:pidro_server, Playstyle, low: 0.10, center: 0.40, high: 0.40)
      on_exit(fn -> Application.delete_env(:pidro_server, Playstyle) end)

      n = Playstyle.needle(0.30)
      assert n >= 0.0 and n <= 1.0
    end
  end
end
