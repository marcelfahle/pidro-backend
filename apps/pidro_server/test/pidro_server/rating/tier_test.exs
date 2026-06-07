defmodule PidroServer.Rating.TierTest do
  # async: false — the "config override respected" tests mutate global
  # Application env, which other tests in this module read.
  use ExUnit.Case, async: false

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
               provisional_max_sigma: 6.0,
               bronze_min: 0.0,
               silver_min: 10.0,
               gold_min: 18.0,
               platinum_min: 26.0,
               master_min: 34.0
             }
    end
  end

  describe "provisional gate" do
    test "sigma == max_sigma with sufficient games stays provisional (>= ceiling)" do
      assert Tier.classify(40.0, 6.0, 50) ==
               %{tier: :provisional, provisional: true}
    end

    test "sigma just below ceiling with sufficient games clears" do
      assert %{provisional: false} = Tier.classify(40.0, 5.999, 50)
    end

    test "games below min with low sigma stays provisional" do
      assert Tier.classify(40.0, 3.0, 9) ==
               %{tier: :provisional, provisional: true}
    end

    test "games at min with low sigma clears (>= min_games boundary)" do
      assert %{provisional: false} = Tier.classify(40.0, 3.0, 10)
    end

    test "AND-clear: only games >= 10 AND sigma < 6.0 clears" do
      # low games + low sigma -> provisional
      assert %{provisional: true} = Tier.classify(40.0, 3.0, 9)
      # high games + high sigma -> provisional
      assert %{provisional: true} = Tier.classify(40.0, 6.0, 50)
      # low games + high sigma -> provisional
      assert %{provisional: true} = Tier.classify(40.0, 6.0, 9)
      # passing corner: high games + low sigma -> cleared
      assert %{provisional: false} = Tier.classify(40.0, 3.0, 10)
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

    test "lowering provisional_max_sigma makes a previously-cleared rating provisional" do
      # sigma 5.0 clears under defaults (max_sigma 6.0).
      assert %{provisional: false} = Tier.classify(40.0, 5.0, 50)

      prior = Application.get_env(:pidro_server, PidroServer.Rating.Tier)
      on_exit(fn -> restore_env(prior) end)

      Application.put_env(:pidro_server, PidroServer.Rating.Tier, provisional_max_sigma: 2.0)

      assert %{tier: :provisional, provisional: true} =
               Tier.classify(40.0, 5.0, 50)
    end
  end

  defp restore_env(nil), do: Application.delete_env(:pidro_server, PidroServer.Rating.Tier)
  defp restore_env(prior), do: Application.put_env(:pidro_server, PidroServer.Rating.Tier, prior)
end
