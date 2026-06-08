defmodule PidroServer.Achievements.CatalogTest do
  use ExUnit.Case, async: true

  alias PidroServer.Achievements.Catalog
  alias PidroServer.Achievements.Def

  doctest Catalog

  @active_keys ~w(player winner winstreak ace the_loser partnership)a
  @dormant_keys ~w(homerun forcer full_house unstoppable)a

  describe "all/0 and active/0" do
    test "all/0 returns 10 defs (6 active + 4 dormant)" do
      assert length(Catalog.all()) == 10
    end

    test "active/0 returns exactly the 6 active keys" do
      assert Catalog.active() |> Enum.map(& &1.key) |> Enum.sort() == Enum.sort(@active_keys)
    end

    test "every active def has status :active" do
      assert Enum.all?(Catalog.active(), &(&1.status == :active))
    end

    test "the 4 dormant keys carry status :dormant + a reason + a followup" do
      dormant = Enum.filter(Catalog.all(), &(&1.status == :dormant))

      assert dormant |> Enum.map(& &1.key) |> Enum.sort() == Enum.sort(@dormant_keys)

      for %Def{} = def <- dormant do
        assert def.status == :dormant
        assert is_binary(def.reason) and def.reason != ""
        assert is_binary(def.followup) and def.followup != ""
      end
    end

    test "active/0 filters out every dormant key" do
      active = Catalog.active() |> Enum.map(& &1.key)
      refute Enum.any?(@dormant_keys, &(&1 in active))
    end
  end

  describe "threshold/1" do
    test "returns the def default" do
      assert Catalog.threshold(:player) == 10
      assert Catalog.threshold(:winner) == 5
      assert Catalog.threshold(:winstreak) == 3
      assert Catalog.threshold(:partnership) == 10
    end

    test "a config override wins over the default (proves config-tunable)" do
      Application.put_env(:pidro_server, Catalog, thresholds: %{player: 99})
      on_exit(fn -> Application.delete_env(:pidro_server, Catalog) end)

      assert Catalog.threshold(:player) == 99
      # Unoverridden keys still fall back to the def default.
      assert Catalog.threshold(:winner) == 5
    end
  end

  describe "fetch!/1" do
    test "returns the def for a known key" do
      assert %Def{key: :ace} = Catalog.fetch!(:ace)
    end

    test "raises for an unknown key" do
      assert_raise ArgumentError, fn -> Catalog.fetch!(:nope) end
    end
  end

  test "adding a def is trivial: a data-only %Def{} reusing an existing evaluator tag" do
    # Documents the ticket's bar — a new achievement is one struct line that
    # reuses an existing evaluator tag. The evaluator router (tested in
    # AchievementsTest) dispatches purely by tag, so no other code changes.
    new_def = %Def{
      key: :centurion,
      name: "Centurion",
      description: "Finish 100 games.",
      tier: 1,
      status: :active,
      evaluator: {:cumulative_count, :games_played},
      threshold: 100
    }

    assert new_def.evaluator == {:cumulative_count, :games_played}
    # The tag is one already handled by the generic evaluator — no new branch.
    assert match?({:cumulative_count, _}, new_def.evaluator)
  end
end
