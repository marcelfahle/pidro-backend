defmodule PidroServer.Rating.TierTest do
  # async: false — the "config override respected" tests mutate global
  # Application env, which other tests in this module read.
  use ExUnit.Case, async: false

  alias PidroServer.Rating
  alias PidroServer.Rating.Tier

  doctest PidroServer.Rating.Tier

  # Pick sigma below provisional_max_sigma (5.0) and solve mu for a target
  # ordinal: mu = ord + 3*sigma = ord + 15. Keeps band tests clear of the
  # provisional gate. games = 50 (>= min_games) keeps them cleared.
  @cleared_sigma 5.0
  @cleared_games 50

  defp mu_for(ord), do: ord + 3 * @cleared_sigma

  defp classify_at(ord) do
    Tier.classify(mu_for(ord), @cleared_sigma, @cleared_games)
  end

  describe "defaults / new player" do
    test "unrated profile (schema default sigma 8.333) is provisional" do
      assert Tier.classify(25.0, 8.333, 0) ==
               %{tier: :provisional, provisional: true}
    end

    test "exact Rating.default/0 sigma (25/3) is also provisional" do
      assert Tier.classify(25.0, 25 / 3, 0) ==
               %{tier: :provisional, provisional: true}
    end

    test "defaults/0 returns the documented map" do
      assert Tier.defaults() == %{
               provisional_min_games: 10,
               provisional_max_sigma: 6.5,
               bronze_min: 0.0,
               silver_min: 10.0,
               gold_min: 18.0,
               platinum_min: 26.0,
               master_min: 34.0
             }
    end
  end

  describe "provisional gate (OR-clear)" do
    test "sufficient games clears regardless of high sigma (the games-count driver)" do
      # The key fix: OpenSkill sigma converges slowly (floors ~6.06), so a player
      # with realistic high sigma must still reach a real band after min_games.
      assert %{provisional: false} = Tier.classify(40.0, 7.2, 10)
      assert %{provisional: false} = Tier.classify(40.0, 8.0, 50)
    end

    test "low sigma clears early even below min_games (fast-converger gate)" do
      assert %{provisional: false} = Tier.classify(40.0, 3.0, 4)
    end

    test "provisional only while BOTH too few games AND sigma still high" do
      # few games + high sigma -> provisional
      assert %{provisional: true} = Tier.classify(40.0, 7.0, 9)
      assert %{provisional: true} = Tier.classify(25.0, 6.5, 0)
    end

    test "games at min clears (>= min_games boundary) even with high sigma" do
      assert %{provisional: false} = Tier.classify(40.0, 7.5, 10)
    end

    test "sigma just below ceiling clears even with few games" do
      assert %{provisional: false} = Tier.classify(40.0, 6.499, 3)
    end

    test "sigma == ceiling with few games stays provisional (>= ceiling)" do
      assert %{provisional: true} = Tier.classify(40.0, 6.5, 3)
    end
  end

  describe "reaches a real band after enough rated games (regression: provisional must clear)" do
    test "a player with min_games and realistic slow-converging sigma lands in a band" do
      result = Tier.classify(30.0, 7.2, 10)
      refute result.provisional
      assert result.tier in [:bronze, :silver, :gold, :platinum, :master]
    end

    test "a strong record yields a higher band than a weak one (both cleared)" do
      strong = Tier.classify(40.0, 7.0, 15)
      weak = Tier.classify(20.0, 7.0, 15)
      refute strong.provisional
      refute weak.provisional
      # higher mu -> higher ordinal -> at least as high a band
      assert Rating.ordinal({40.0, 7.0}) > Rating.ordinal({20.0, 7.0})
    end
  end

  describe "band classification (cleared provisional)" do
    test "ordinal 0.0 -> bronze" do
      assert classify_at(0.0) == %{tier: :bronze, provisional: false}
    end

    test "ordinal -2.0 (slightly negative) -> bronze (catch-all floor)" do
      assert classify_at(-2.0) == %{tier: :bronze, provisional: false}
    end

    test "ordinal just below silver_min -> bronze" do
      assert classify_at(9.999) == %{tier: :bronze, provisional: false}
    end

    test "ordinal 10.0 (silver_min) -> silver (>= boundary)" do
      assert classify_at(10.0) == %{tier: :silver, provisional: false}
    end

    test "ordinal 15.0 -> silver" do
      assert classify_at(15.0) == %{tier: :silver, provisional: false}
    end

    test "ordinal 18.0 (gold_min) -> gold (boundary)" do
      assert classify_at(18.0) == %{tier: :gold, provisional: false}
    end

    test "ordinal 26.0 (platinum_min) -> platinum (boundary)" do
      assert classify_at(26.0) == %{tier: :platinum, provisional: false}
    end

    test "ordinal 34.0 (master_min) -> master (boundary)" do
      assert classify_at(34.0) == %{tier: :master, provisional: false}
    end

    test "ordinal 100.0 (well above) -> master" do
      assert classify_at(100.0) == %{tier: :master, provisional: false}
    end
  end

  describe "ordinal is mu - 3*sigma, not raw mu" do
    test "same mu, different cleared sigma land in different bands" do
      # Both cleared (sigma < 6.0). Same mu = 30.0.
      # high sigma (5.0): ordinal = 30 - 15 = 15.0 -> silver
      # low sigma (1.0):  ordinal = 30 - 3  = 27.0 -> platinum
      high_sigma = Tier.classify(30.0, 5.0, 50)
      low_sigma = Tier.classify(30.0, 1.0, 50)

      assert high_sigma == %{tier: :silver, provisional: false}
      assert low_sigma == %{tier: :platinum, provisional: false}
      refute high_sigma == low_sigma
    end
  end

  describe "classify/1 profile overload" do
    test "delegates to classify/3 with the rating_* keys" do
      assert Tier.classify(%{
               rating_mu: 40.0,
               rating_sigma: 5.0,
               rating_games_count: 50
             }) == Tier.classify(40.0, 5.0, 50)
    end

    test "unrated profile map is provisional" do
      assert Tier.classify(%{
               rating_mu: 25.0,
               rating_sigma: 8.333,
               rating_games_count: 0
             }) == %{tier: :provisional, provisional: true}
    end
  end

  describe "config override respected" do
    test "lowering master_min reclassifies a rating at that ordinal" do
      # ordinal 12.0 is :silver under defaults (silver_min 10.0).
      assert classify_at(12.0) == %{tier: :silver, provisional: false}

      prior = Application.get_env(:pidro_server, PidroServer.Rating.Tier)
      on_exit(fn -> restore_env(prior) end)

      Application.put_env(:pidro_server, PidroServer.Rating.Tier, master_min: 12.0)

      assert %{tier: :master, provisional: false} = classify_at(12.0)
    end

    test "lowering provisional_max_sigma makes a previously early-cleared rating provisional" do
      # With few games (< min_games), only the sigma gate can clear. sigma 5.0
      # clears under defaults (max_sigma 6.5)...
      assert %{provisional: false} = Tier.classify(40.0, 5.0, 4)

      prior = Application.get_env(:pidro_server, PidroServer.Rating.Tier)
      on_exit(fn -> restore_env(prior) end)

      # ...but tightening the sigma gate below 5.0 re-provisionalizes it (still few games).
      Application.put_env(:pidro_server, PidroServer.Rating.Tier, provisional_max_sigma: 2.0)

      assert %{tier: :provisional, provisional: true} =
               Tier.classify(40.0, 5.0, 4)
    end
  end

  defp restore_env(nil), do: Application.delete_env(:pidro_server, PidroServer.Rating.Tier)
  defp restore_env(prior), do: Application.put_env(:pidro_server, PidroServer.Rating.Tier, prior)
end
