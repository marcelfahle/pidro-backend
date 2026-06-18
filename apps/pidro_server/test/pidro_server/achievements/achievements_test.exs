defmodule PidroServer.AchievementsTest do
  use ExUnit.Case, async: true

  alias PidroServer.Achievements

  doctest Achievements

  # Build a game_view; defaults are a non-qualifying loss.
  defp gv(opts) do
    %{
      won?: Keyword.get(opts, :won?, false),
      team_score: Keyword.get(opts, :team_score, 0),
      opponent_score: Keyword.get(opts, :opponent_score, 30),
      partner_id: Keyword.get(opts, :partner_id, nil)
    }
  end

  defp ctx(opts) do
    %{
      user_id: "u1",
      aggregates: Keyword.get(opts, :aggregates, %{games_played: 0, wins: 0}),
      this_game: Keyword.get(opts, :this_game, nil),
      history: Keyword.get(opts, :history, [])
    }
  end

  defp keys(ctx), do: ctx |> Achievements.evaluate_active() |> Enum.map(fn {k, _t, _m} -> k end)

  describe "player (:cumulative_count games_played, 10)" do
    test "earns at 10, not at 9" do
      refute :player in keys(ctx(aggregates: %{games_played: 9, wins: 0}))
      assert :player in keys(ctx(aggregates: %{games_played: 10, wins: 0}))
      assert :player in keys(ctx(aggregates: %{games_played: 50, wins: 0}))
    end
  end

  describe "winner (:cumulative_count wins, 5)" do
    test "earns at 5, not at 4" do
      refute :winner in keys(ctx(aggregates: %{games_played: 20, wins: 4}))
      assert :winner in keys(ctx(aggregates: %{games_played: 20, wins: 5}))
    end
  end

  describe "winstreak (:win_streak, 3)" do
    test "earns at a run of 3, not a run of 2" do
      refute :winstreak in keys(ctx(history: [gv(won?: true), gv(won?: true)]))
      assert :winstreak in keys(ctx(history: [gv(won?: true), gv(won?: true), gv(won?: true)]))
    end

    test "a loss breaks the run" do
      history = [gv(won?: true), gv(won?: true), gv(won?: false), gv(won?: true), gv(won?: true)]
      refute :winstreak in keys(ctx(history: history))
    end

    test "3 in a row at the end earns" do
      history = [gv(won?: false), gv(won?: true), gv(won?: true), gv(won?: true)]
      assert :winstreak in keys(ctx(history: history))
    end

    test "3 in a row in the middle earns" do
      history = [
        gv(won?: false),
        gv(won?: true),
        gv(won?: true),
        gv(won?: true),
        gv(won?: false)
      ]

      assert :winstreak in keys(ctx(history: history))
    end

    test "non-consecutive wins separated by losses do not earn" do
      history = [gv(won?: true), gv(won?: false), gv(won?: true), gv(won?: false), gv(won?: true)]
      refute :winstreak in keys(ctx(history: history))
    end
  end

  describe "ace (:single_game_predicate opponent_at_or_below, 0)" do
    test "earns on a win where opponent finished <= 0" do
      assert :ace in keys(ctx(this_game: gv(won?: true, opponent_score: 0)))
      assert :ace in keys(ctx(this_game: gv(won?: true, opponent_score: -5)))
    end

    test "does not earn when opponent finished > 0 even on a win" do
      refute :ace in keys(ctx(this_game: gv(won?: true, opponent_score: 1)))
    end

    test "the user must be on the winning team" do
      refute :ace in keys(ctx(this_game: gv(won?: false, opponent_score: -10)))
    end

    test "rebuild path scans history (any game qualifies)" do
      history = [gv(won?: false, opponent_score: 40), gv(won?: true, opponent_score: -2)]
      assert :ace in keys(ctx(history: history))
    end
  end

  describe "the_loser (:single_game_predicate final_score_negative, 0)" do
    test "earns when own team final < 0" do
      assert :the_loser in keys(ctx(this_game: gv(team_score: -1)))
    end

    test "does not earn at 0 or positive" do
      refute :the_loser in keys(ctx(this_game: gv(team_score: 0)))
      refute :the_loser in keys(ctx(this_game: gv(team_score: 10)))
    end
  end

  describe "partnership (:same_partner_wins, 10)" do
    # Helpers to build histories of won/lost games with a given partner.
    defp won_with(partner, n), do: List.duplicate(gv(won?: true, partner_id: partner), n)
    defp lost_with(partner, n), do: List.duplicate(gv(won?: false, partner_id: partner), n)

    test "earns at 10 wins with the SAME partner, not at 9" do
      refute :partnership in keys(ctx(history: won_with("p_x", 9)))
      assert :partnership in keys(ctx(history: won_with("p_x", 10)))
      assert :partnership in keys(ctx(history: won_with("p_x", 25)))
    end

    test "does NOT earn when 10 wins are spread across DIFFERENT partners" do
      history = Enum.map(1..10, fn i -> gv(won?: true, partner_id: "p_#{i}") end)
      refute :partnership in keys(ctx(history: history))
    end

    test "takes the max over partners (8 with X + 10 with Y earns; mixed never sums)" do
      history = won_with("p_x", 8) ++ won_with("p_y", 10)
      assert :partnership in keys(ctx(history: history))

      history2 = won_with("p_x", 8) ++ won_with("p_y", 9)
      refute :partnership in keys(ctx(history: history2))
    end

    test "losses with a partner do not count" do
      history = won_with("p_x", 9) ++ lost_with("p_x", 5)
      refute :partnership in keys(ctx(history: history))
    end

    test "wins with no real partner (partner_id nil) do not count" do
      history = List.duplicate(gv(won?: true, partner_id: nil), 20)
      refute :partnership in keys(ctx(history: history))
    end
  end

  describe "dormant never auto-award" do
    test "a ctx that would trivially satisfy dormant intents yields no dormant keys" do
      # Huge counts, long streak, a shutout partnered win — nothing should
      # produce homerun/forcer/full_house/unstoppable since active/0 filters them.
      ctx =
        ctx(
          aggregates: %{games_played: 1000, wins: 1000},
          this_game: gv(won?: true, team_score: 62, opponent_score: -20, partner_id: "px"),
          history: List.duplicate(gv(won?: true, partner_id: "px"), 50)
        )

      earned = keys(ctx)
      refute Enum.any?(~w(homerun forcer full_house unstoppable)a, &(&1 in earned))
    end
  end
end
