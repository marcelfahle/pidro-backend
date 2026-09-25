defmodule Pidro.Integration.PairedSelfPlayTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Pidro.Bot.SelfPlay
  alias Mix.Tasks.Pidro.Selfplay, as: SelfplayTask

  test "Five records agree with engine winners observed as tricks finish" do
    test_pid = self()
    regular = SelfPlay.rulebook_policy()

    policy = fn view, legal ->
      action = regular.(view, legal)

      if view.phase == :playing and Pidro.Bot.Knowledge.seats_to_act(view) == [] do
        {:play_card, card} = action

        trick =
          view.current_trick ||
            %Pidro.Core.Types.Trick{number: view.trick_number, leader: view.position}

        trick = %{trick | plays: trick.plays ++ [{view.position, card}]}
        {:ok, winner, _} = Pidro.Game.Play.determine_trick_winner(trick, view.trump_suit)

        fives =
          for {owner, card} <- trick.plays,
              Pidro.Bot.Knowledge.five?(card, view.trump_suit),
              do: %{
                owner: Pidro.Core.Types.position_to_team(owner),
                winner: Pidro.Core.Types.position_to_team(winner)
              }

        send(test_pid, {:fives, fives})
      end

      action
    end

    result = SelfPlay.play_game(%{north_south: policy, east_west: policy}, seed: 74)
    assert result.outcome == :complete
    observed = collect_fives([])
    assert observed != []
    assert Enum.sort(result.fives) == Enum.sort(observed)
  end

  defp collect_fives(acc) do
    receive do
      {:fives, fives} -> collect_fives(fives ++ acc)
    after
      0 -> acc
    end
  end

  test "each pair uses the same deal with teams swapped, matching direct games" do
    a = SelfPlay.rulebook_policy(:regular)
    b = SelfPlay.rulebook_policy(:casual)
    summary = SelfPlay.run(pairs: 3, seed: 71, a: {:regular, a}, b: {:casual, b})

    assert summary.games == 6
    assert summary.complete == 6
    assert summary.pairs == 3
    assert summary.pair_results.complete == 3

    for {pair, i} <- Enum.with_index(summary.pair_results.results, 1) do
      seed = 71 * 100_000 + i
      assert pair.seed == seed
      first = SelfPlay.play_game(%{north_south: a, east_west: b}, seed: seed)
      second = SelfPlay.play_game(%{north_south: b, east_west: a}, seed: seed)

      labels = [
        %{north_south: :regular, east_west: :casual},
        %{north_south: :casual, east_west: :regular}
      ]

      assert pair.winners ==
               Enum.zip_with([first, second], labels, fn game, teams -> teams[game.winner] end)
    end
  end

  test "identical policies split every completed pair and conserve Five captures" do
    policy = SelfPlay.rulebook_policy()
    summary = SelfPlay.run(pairs: 8, seed: 72, a: {:a, policy}, b: {:b, policy})
    assert summary.pair_results.splits == 8
    assert summary.teams.a.wins == 8
    assert summary.teams.b.wins == 8
    assert summary.teams.a.fives_captured == summary.teams.b.fives_captured
    assert summary.teams.a.fives_lost == summary.teams.b.fives_taken
    assert summary.teams.b.fives_lost == summary.teams.a.fives_taken
    assert summary.teams.a.fives_captured > 0
  end

  test "paired summaries are independent of task concurrency apart from timing" do
    opts = [
      pairs: 10,
      seed: 73,
      a: {:regular, SelfPlay.rulebook_policy()},
      b: {:casual, SelfPlay.rulebook_policy(:casual)}
    ]

    one = SelfPlay.run(opts ++ [max_concurrency: 1])
    many = SelfPlay.run(opts ++ [max_concurrency: 4])
    assert Map.delete(one, :timing) == Map.delete(many, :timing)
  end

  test "failed games cannot count as complete pairs or splits" do
    bad = fn _, _ -> {:bid, 99} end
    result = SelfPlay.run(pairs: 2, a: {:bad, bad})
    assert result.illegal == 4
    assert result.pair_results.complete == 0
    assert result.pair_results.splits == 0
    assert result.pair_results.failed == 2
  end

  test "invalid evaluation sizes and duplicate labels fail instead of yielding misleading summaries" do
    for opts <- [
          [pairs: 0],
          [pairs: -1],
          [games: 0],
          [pairs: 1, games: 2],
          [a: {:same, SelfPlay.rulebook_policy()}, b: {:same, SelfPlay.random_policy()}]
        ] do
      assert_raise ArgumentError, fn -> SelfPlay.run(opts) end
    end
  end

  test "CLI accepts named profiles and pairs, rejects ambiguous or invalid runs" do
    output =
      capture_io(fn -> SelfplayTask.run(["--pairs", "2", "--a", "regular", "--b", "casual"]) end)

    assert output =~ "complete 4, illegal 0"
    assert output =~ "Pairs: 2"
    assert output =~ "Fives"

    capture_io(fn ->
      for args <- [
            ["--pairs", "0"],
            ["--pairs", "1", "--games", "2"],
            ["stray"],
            ["--a", "unknown"]
          ] do
        assert catch_exit(SelfplayTask.run(args)) == {:shutdown, 1}
      end
    end)
  end
end
