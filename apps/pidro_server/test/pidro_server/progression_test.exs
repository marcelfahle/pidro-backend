defmodule PidroServer.ProgressionTest do
  # async: false — the "config override respected" tests mutate global
  # Application env, which other tests in this module read.
  use ExUnit.Case, async: false

  alias PidroServer.Progression

  doctest PidroServer.Progression

  describe "xp_for_game/3" do
    test "loser earns team score, no bonus (legacy 54)" do
      assert Progression.xp_for_game(54, false) == 54
    end

    test "winner earns team score + 50 win bonus (legacy 116)" do
      assert Progression.xp_for_game(66, true) == 116
    end

    test "win_bonus opts override" do
      assert Progression.xp_for_game(10, true, win_bonus: 5) == 15
    end

    test "extra_bonus opts override (event lever)" do
      assert Progression.xp_for_game(10, false, extra_bonus: 7) == 17
      assert Progression.xp_for_game(10, true, extra_bonus: 7) == 67
    end

    test "negative team score clamps to a non-negative result" do
      assert Progression.xp_for_game(-5, false) == 0
      assert Progression.xp_for_game(-5, true) == 45
    end
  end

  describe "level_for_xp/1 (power-law curve milestones + cap)" do
    test "level_for_xp(0) == 1" do
      assert Progression.level_for_xp(0) == 1
    end

    test "milestone XP totals land on their level (80·level²)" do
      assert Progression.level_for_xp(2_000) == 5
      assert Progression.level_for_xp(8_000) == 10
      assert Progression.level_for_xp(32_000) == 20
      assert Progression.level_for_xp(200_000) == 50
      assert Progression.level_for_xp(450_000) == 75
      assert Progression.level_for_xp(800_000) == 100
    end

    test "first threshold boundary (level 2 begins at 320)" do
      assert Progression.level_for_xp(319) == 1
      assert Progression.level_for_xp(320) == 2
    end

    test "just below the cap is level 99" do
      assert Progression.level_for_xp(799_999) == 99
    end

    test "monotonic non-decreasing across a sweep" do
      levels = Enum.map(0..900_000//5_000, &Progression.level_for_xp/1)
      assert levels == Enum.sort(levels)
    end

    test "huge XP caps at max_level" do
      assert Progression.level_for_xp(1_000_000) == 100
      assert Progression.level_for_xp(1_000_000_000_000_000) == 100
    end
  end

  describe "thresholds/0" do
    test "ascending 99-entry list (level-2..100 boundaries) starting [320, 720, ...]" do
      thresholds = Progression.thresholds()
      assert length(thresholds) == 99
      assert Enum.take(thresholds, 5) == [320, 720, 1280, 2000, 2880]
      assert List.last(thresholds) == 800_000
      assert thresholds == Enum.sort(thresholds)
    end
  end

  describe "title_for_level/1" do
    test "highest title whose level <= given" do
      assert Progression.title_for_level(1) == "Rookie"
      assert Progression.title_for_level(4) == "Rookie"
      assert Progression.title_for_level(5) == "Apprentice"
      assert Progression.title_for_level(20) == "Veteran"
      assert Progression.title_for_level(100) == "Legend"
    end

    test "above all keys returns the top title; below lowest returns floor" do
      assert Progression.title_for_level(200) == "Legend"
      assert Progression.title_for_level(0) == "Rookie"
    end
  end

  describe "prestige_for_xp/1 (uncapped tail)" do
    test "0 below the L100 cap, including right at the boundary" do
      assert Progression.prestige_for_xp(799_999) == 0
      assert Progression.prestige_for_xp(800_000) == 0
    end

    test "one star per prestige_step (500k) past the cap" do
      assert Progression.prestige_for_xp(1_300_000) == 1
    end

    test "real Pidro 1 calibration values" do
      # Top player: 5.02M XP → Hall of Famer ★8.
      assert Progression.prestige_for_xp(5_020_512) == 8
      assert Progression.prestige_for_xp(1_941_660) == 2
    end
  end

  describe "prestige_progress/1" do
    test "nil below the cap (no ring to render)" do
      assert Progression.prestige_progress(0) == nil
      assert Progression.prestige_progress(799_999) == nil
    end

    test "{into, step} at/over the cap" do
      assert Progression.prestige_progress(800_000) == {0, 500_000}
      assert Progression.prestige_progress(1_300_000) == {0, 500_000}
      assert Progression.prestige_progress(1_050_000) == {250_000, 500_000}
      # 5.02M: 8 full steps past the cap → into = (5_020_512 - 800_000) rem 500_000.
      assert Progression.prestige_progress(5_020_512) == {220_512, 500_000}
    end
  end

  describe "next_level_at/1 + level_progress/1" do
    test "next_level_at" do
      assert Progression.next_level_at(0) == 320
      assert Progression.next_level_at(320) == 720
    end

    test "next_level_at at cap is :max" do
      assert Progression.next_level_at(800_000) == :max
      assert Progression.next_level_at(1_000_000_000_000_000) == :max
    end

    test "level_progress within a level" do
      assert Progression.level_progress(0) == {0, 320}
      # xp 320: lower = 320 (highest threshold <= 320), upper = 720.
      assert Progression.level_progress(320) == {0, 400}
    end

    test "level_progress span sums to the band width" do
      {into, span} = Progression.level_progress(1_000)
      assert into >= 0 and into < span
    end

    test "level_progress at cap is :max" do
      assert Progression.level_progress(800_000) == :max
      assert Progression.level_progress(1_000_000_000_000_000) == :max
    end
  end

  describe "defaults/0" do
    test "returns the documented map" do
      defaults = Progression.defaults()
      assert defaults.win_bonus == 50
      assert defaults.extra_bonus == 0
      assert defaults.max_level == 100
      assert defaults.curve_coefficient == 80
      assert defaults.curve_exponent == 2.0
      assert defaults.prestige_step == 500_000
      assert defaults.thresholds == nil
      assert defaults.titles[1] == "Rookie"
      assert defaults.titles[100] == "Legend"
    end
  end

  describe "config override respected" do
    test "win_bonus override proves runtime read" do
      assert Progression.xp_for_game(10, true) == 60

      prior = Application.get_env(:pidro_server, PidroServer.Progression)
      on_exit(fn -> restore_env(prior) end)
      Application.put_env(:pidro_server, PidroServer.Progression, win_bonus: 5)

      assert Progression.xp_for_game(10, true) == 15
    end

    test "titles override changes title_for_level" do
      assert Progression.title_for_level(10) == "Journeyman"

      prior = Application.get_env(:pidro_server, PidroServer.Progression)
      on_exit(fn -> restore_env(prior) end)

      Application.put_env(:pidro_server, PidroServer.Progression,
        titles: %{1 => "Newbie", 10 => "Pro"}
      )

      assert Progression.title_for_level(5) == "Newbie"
      assert Progression.title_for_level(10) == "Pro"
    end

    test "max_level override lowers the cap and thresholds length" do
      prior = Application.get_env(:pidro_server, PidroServer.Progression)
      on_exit(fn -> restore_env(prior) end)

      Application.put_env(:pidro_server, PidroServer.Progression,
        max_level: 3,
        curve_coefficient: 80,
        curve_exponent: 2.0
      )

      # thresholds returns boundaries for levels 2..max_level → 2 entries at max 3.
      assert length(Progression.thresholds()) == 2
      assert Progression.level_for_xp(1_000_000_000) == 3
    end

    test "explicit thresholds list wins verbatim" do
      prior = Application.get_env(:pidro_server, PidroServer.Progression)
      on_exit(fn -> restore_env(prior) end)
      Application.put_env(:pidro_server, PidroServer.Progression, thresholds: [100, 200, 300])

      assert Progression.thresholds() == [100, 200, 300]
      assert Progression.level_for_xp(99) == 1
      assert Progression.level_for_xp(100) == 2
      assert Progression.level_for_xp(300) == 4
    end
  end

  defp restore_env(nil), do: Application.delete_env(:pidro_server, PidroServer.Progression)
  defp restore_env(prior), do: Application.put_env(:pidro_server, PidroServer.Progression, prior)
end
