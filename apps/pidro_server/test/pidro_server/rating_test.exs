defmodule PidroServer.RatingTest do
  use ExUnit.Case, async: true

  alias PidroServer.Rating

  doctest PidroServer.Rating

  # New-player default sigma (25/3). The default mu is exactly 25.0.
  @default_sigma 25 / 3

  describe "default/0" do
    test "returns {25.0, ~8.333} as floats" do
      {mu, sigma} = Rating.default()

      assert mu == 25.0
      assert is_float(mu)
      assert is_float(sigma)
      assert_in_delta sigma, @default_sigma, 1.0e-6
    end
  end

  describe "ordinal/1" do
    test "computes mu - 3 * sigma" do
      assert_in_delta Rating.ordinal({25.0, 8.333}), 25.0 - 3 * 8.333, 1.0e-9
    end

    test "higher mu at equal sigma yields higher ordinal" do
      assert Rating.ordinal({30.0, 5.0}) > Rating.ordinal({25.0, 5.0})
    end

    test "higher sigma at equal mu yields lower ordinal (uncertainty penalized)" do
      assert Rating.ordinal({25.0, 8.0}) < Rating.ordinal({25.0, 5.0})
    end
  end

  describe "rate/2 — single win monotonicity" do
    test "winners gain mu, losers lose mu, all sigma shrink" do
      r = Rating.default()
      {_, base_sigma} = r

      %{winners: winners, losers: losers} = Rating.rate([r, r], [r, r])

      assert length(winners) == 2
      assert length(losers) == 2

      Enum.each(winners, fn {mu, sigma} ->
        assert mu > 25.0
        assert sigma < base_sigma
      end)

      Enum.each(losers, fn {mu, sigma} ->
        assert mu < 25.0
        assert sigma < base_sigma
      end)
    end

    test "result map has winners/losers keys" do
      r = Rating.default()
      result = Rating.rate([r], [r])

      assert Map.keys(result) |> Enum.sort() == [:losers, :winners]
    end

    test "preserves positional order within each team" do
      a = {30.0, 5.0}
      b = {20.0, 5.0}

      %{winners: [{mu_a, _}, {mu_b, _}]} =
        Rating.rate([a, b], [Rating.default(), Rating.default()])

      # a started higher than b; that ordering must survive in the output.
      assert mu_a > mu_b
    end

    test "works for 1v1" do
      r = Rating.default()
      %{winners: [w], losers: [l]} = Rating.rate([r], [r])

      {wmu, _} = w
      {lmu, _} = l
      assert wmu > 25.0
      assert lmu < 25.0
    end

    test "works for asymmetric team sizes (1 vs 2)" do
      r = Rating.default()
      %{winners: [w], losers: [l1, l2]} = Rating.rate([r], [r, r])

      {wmu, _} = w
      assert wmu > 25.0
      assert match?({_, _}, l1)
      assert match?({_, _}, l2)
    end
  end

  describe "rate/2 — blowout == close" do
    test "margin is not an input, so identical ratings produce identical updates" do
      winners = [Rating.default(), {28.0, 6.0}]
      losers = [{22.0, 7.0}, Rating.default()]

      # There is no score-margin parameter: a 62-0 blowout and a 62-61 squeaker
      # between the same four ratings are literally the same call. Asserting
      # equality freezes the order-only property of the model.
      blowout = Rating.rate(winners, losers)
      close = Rating.rate(winners, losers)

      assert blowout == close
    end
  end

  describe "rate/2 — upset vs expected" do
    test "an upset moves mu more than an expected result" do
      strong = {35.0, 3.0}
      weak = {15.0, 3.0}

      %{winners: [{expected_mu, _}]} = Rating.rate([strong], [weak])
      %{winners: [{upset_mu, _}]} = Rating.rate([weak], [strong])

      expected_gain = expected_mu - 35.0
      upset_gain = upset_mu - 15.0

      assert expected_gain > 0
      assert upset_gain > 0
      assert upset_gain > expected_gain
    end
  end

  describe "rate/2 — sigma shrink over repeated games" do
    test "repeated wins shrink sigma monotonically with diminishing mu gains" do
      # Winner keeps beating a fixed-strength opponent; thread each output back in.
      games =
        Enum.scan(1..5, {Rating.default(), Rating.default()}, fn _i, {winner, _loser} ->
          %{winners: [new_winner], losers: [new_loser]} =
            Rating.rate([winner], [Rating.default()])

          {new_winner, new_loser}
        end)

      winner_ratings = Enum.map(games, fn {w, _} -> w end)
      mus = Enum.map(winner_ratings, fn {mu, _} -> mu end)
      sigmas = Enum.map(winner_ratings, fn {_, sigma} -> sigma end)

      # sigma strictly decreasing
      Enum.zip(sigmas, tl(sigmas))
      |> Enum.each(fn {prev, next} -> assert next < prev end)

      # mu strictly increasing
      Enum.zip(mus, tl(mus))
      |> Enum.each(fn {prev, next} -> assert next > prev end)

      # per-game mu gain diminishes
      gains =
        [{25.0, nil} | winner_ratings]
        |> Enum.map(fn {mu, _} -> mu end)
        |> then(fn series -> Enum.zip(series, tl(series)) end)
        |> Enum.map(fn {prev, next} -> next - prev end)

      Enum.zip(gains, tl(gains))
      |> Enum.each(fn {prev_gain, next_gain} -> assert next_gain < prev_gain end)
    end
  end

  describe "rate/2 — symmetry" do
    test "swapping winners/losers mirrors the mu deltas with identical sigma shrink" do
      a = Rating.default()
      b = Rating.default()

      %{winners: [{a_mu, a_sig}], losers: [{b_mu, b_sig}]} = Rating.rate([a], [b])
      %{winners: [{b2_mu, b2_sig}], losers: [{a2_mu, a2_sig}]} = Rating.rate([b], [a])

      # Winner gain when A wins mirrors winner gain when B wins (same start).
      assert_in_delta a_mu - 25.0, b2_mu - 25.0, 1.0e-9
      # Loser drop mirrors too.
      assert_in_delta 25.0 - b_mu, 25.0 - a2_mu, 1.0e-9
      # Sigma shrink is identical regardless of which side won.
      assert_in_delta a_sig, b2_sig, 1.0e-9
      assert_in_delta b_sig, a2_sig, 1.0e-9
    end
  end

  describe "rate/2 — determinism" do
    test "identical inputs return byte-identical tuples" do
      winners = [Rating.default(), {28.0, 6.0}]
      losers = [{22.0, 7.0}, Rating.default()]

      assert Rating.rate(winners, losers) == Rating.rate(winners, losers)
    end
  end
end
