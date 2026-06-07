defmodule PidroServer.Profiles.PostGameSummaryTest do
  @moduledoc """
  Unit tests for the pure post-game summary builder (PID-52). No DB.
  """

  use ExUnit.Case, async: true

  alias PidroServer.Profiles.PostGameSummary
  alias PidroServer.Progression

  doctest PostGameSummary

  # XP totals chosen against the legacy threshold list [83, 174, 276, ...]:
  # level 1 = [0, 82], level 2 = [83, 173], level 3 = [174, 275].
  defp before(opts \\ []) do
    %{
      veteran_xp: Keyword.get(opts, :veteran_xp, 0),
      rating_mu: Keyword.get(opts, :rating_mu, 25.0),
      rating_sigma: Keyword.get(opts, :rating_sigma, 8.333),
      rating_games_count: Keyword.get(opts, :rating_games_count, 0)
    }
  end

  defp casual_deltas(opts) do
    %{
      xp_earned: Keyword.get(opts, :xp_earned, 0),
      veteran_xp_after: Keyword.get(opts, :veteran_xp_after, 0),
      rated?: false,
      rating_after: nil,
      rating_count_after: nil,
      newly_earned_keys: Keyword.get(opts, :newly_earned_keys, [])
    }
  end

  defp rated_deltas(opts) do
    %{
      xp_earned: Keyword.get(opts, :xp_earned, 112),
      veteran_xp_after: Keyword.get(opts, :veteran_xp_after, 112),
      rated?: true,
      rating_after: Keyword.fetch!(opts, :rating_after),
      rating_count_after: Keyword.fetch!(opts, :rating_count_after),
      newly_earned_keys: Keyword.get(opts, :newly_earned_keys, [])
    }
  end

  describe "always-present XP/level fallback" do
    test "a casual loss with xp_earned: 0 still returns a complete Veteran block + rating nil" do
      summary = PostGameSummary.build(before(), casual_deltas(xp_earned: 0, veteran_xp_after: 0))

      assert summary.xp_earned == 0
      assert summary.veteran_xp == 0
      assert summary.veteran_level_before == 1
      assert summary.veteran_level == 1
      assert summary.leveled_up == false
      assert summary.veteran_title_before == "Rookie"
      assert summary.veteran_title == "Rookie"
      assert summary.title_changed == false
      assert summary.veteran_progress == %{into: 0, span: 83, max: false}
      assert summary.achievements_unlocked == []
      assert summary.rating == nil
      assert summary.rated == false
    end
  end

  describe "leveled_up" do
    test "crossing a threshold sets leveled_up: true and a higher level" do
      # 0 -> 180 crosses level 1 (<=82) and level 2 (<=173) into level 3.
      summary =
        PostGameSummary.build(before(veteran_xp: 0), casual_deltas(veteran_xp_after: 180))

      assert summary.veteran_level_before == 1
      assert summary.veteran_level == 3
      assert summary.leveled_up == true
    end

    test "a same-level game keeps leveled_up: false" do
      summary =
        PostGameSummary.build(before(veteran_xp: 10), casual_deltas(veteran_xp_after: 50))

      assert summary.veteran_level_before == 1
      assert summary.veteran_level == 1
      assert summary.leveled_up == false
    end
  end

  describe "title_changed" do
    test "crossing the level-20 title boundary flips title_changed and the title" do
      xp_l19 = level_floor_xp(19)
      xp_l20 = level_floor_xp(20)

      summary =
        PostGameSummary.build(
          before(veteran_xp: xp_l19),
          casual_deltas(veteran_xp_after: xp_l20)
        )

      assert summary.veteran_level_before == 19
      assert summary.veteran_level == 20
      assert summary.veteran_title_before == "Journeyman"
      assert summary.veteran_title == "Veteran"
      assert summary.title_changed == true
    end

    test "staying within a title band keeps title_changed: false" do
      summary =
        PostGameSummary.build(before(veteran_xp: 0), casual_deltas(veteran_xp_after: 90))

      assert summary.title_changed == false
    end
  end

  describe "rating block (rated only)" do
    test "tier move up: ordinal rises across a band cut" do
      # ordinal = mu - 3*sigma. before {20,5} -> 5 (bronze); after {40,5} -> 25 (gold).
      summary =
        PostGameSummary.build(
          before(rating_mu: 20.0, rating_sigma: 5.0, rating_games_count: 49),
          rated_deltas(rating_after: {40.0, 5.0}, rating_count_after: 50)
        )

      assert summary.rating.tier_before == :bronze
      assert summary.rating.tier_after == :gold
      assert summary.rating.direction == "up"
    end

    test "tier move down: ordinal falls" do
      # before {40,5} -> 25 (gold); after {20,5} -> 5 (bronze).
      summary =
        PostGameSummary.build(
          before(rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50),
          rated_deltas(rating_after: {20.0, 5.0}, rating_count_after: 51)
        )

      assert summary.rating.tier_before == :gold
      assert summary.rating.tier_after == :bronze
      assert summary.rating.direction == "down"
    end

    test "no tier move: same band, direction follows ordinal sign" do
      # before {40,5} -> 25 (gold); after {40.3,5} -> 25.3 (still gold).
      summary =
        PostGameSummary.build(
          before(rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50),
          rated_deltas(rating_after: {40.3, 5.0}, rating_count_after: 51)
        )

      assert summary.rating.tier_before == summary.rating.tier_after
      assert summary.rating.tier_after == :gold
      assert summary.rating.direction == "up"
    end

    test "provisional clears: before provisional, after cleared" do
      # before: count below min_games AND still-high sigma (provisional);
      # after: count crosses min_games -> cleared by the games-count gate even
      # though sigma is still high (realistic — OpenSkill sigma converges slowly).
      summary =
        PostGameSummary.build(
          before(rating_mu: 30.0, rating_sigma: 7.5, rating_games_count: 9),
          rated_deltas(rating_after: {30.5, 7.3}, rating_count_after: 10)
        )

      assert summary.rating.provisional_before == true
      assert summary.rating.provisional_after == false
    end
  end

  describe "casual omits tier" do
    test "rated?: false yields rating == nil with all Veteran fields present" do
      summary = PostGameSummary.build(before(), casual_deltas(veteran_xp_after: 45))

      assert summary.rating == nil
      assert summary.veteran_level == 1
      assert summary.veteran_title == "Rookie"
      assert is_map(summary.veteran_progress)
    end
  end

  describe "achievements_unlocked" do
    test "newly-earned keys join to the Catalog; unknown keys are dropped" do
      summary =
        PostGameSummary.build(
          before(),
          casual_deltas(newly_earned_keys: [:player, :winner, :not_a_real_key])
        )

      keys = Enum.map(summary.achievements_unlocked, & &1.key)
      assert "player" in keys
      assert "winner" in keys
      refute "not_a_real_key" in keys

      player = Enum.find(summary.achievements_unlocked, &(&1.key == "player"))
      assert player.name == "Player"
      assert player.tier == 1
    end

    test "no newly-earned keys yields an empty list" do
      summary = PostGameSummary.build(before(), casual_deltas(newly_earned_keys: []))
      assert summary.achievements_unlocked == []
    end
  end

  describe "veteran_progress normalization" do
    test ":max maps to %{into: 0, span: 0, max: true}" do
      max_xp = level_floor_xp(Progression.defaults().max_level)
      summary = PostGameSummary.build(before(), casual_deltas(veteran_xp_after: max_xp))
      assert summary.veteran_progress == %{into: 0, span: 0, max: true}
    end

    test "a finite progress maps to %{into, span, max: false}" do
      summary = PostGameSummary.build(before(), casual_deltas(veteran_xp_after: 0))
      assert summary.veteran_progress == %{into: 0, span: 83, max: false}
    end
  end

  describe "Jason encodability" do
    test "a rated summary encodes cleanly (no tuples leak; atoms become strings)" do
      summary =
        PostGameSummary.build(
          before(rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50),
          rated_deltas(
            rating_after: {41.0, 4.9},
            rating_count_after: 51,
            newly_earned_keys: [:winner]
          )
        )

      assert {:ok, json} = Jason.encode(summary)
      decoded = Jason.decode!(json)
      assert decoded["rating"]["tier_after"] in ~w(bronze silver gold platinum master)
      assert decoded["rating"]["direction"] in ~w(up down none)
      assert is_map(decoded["veteran_progress"])
      assert hd(decoded["achievements_unlocked"])["key"] == "winner"
    end

    test "a casual summary encodes cleanly with rating null" do
      summary = PostGameSummary.build(before(), casual_deltas(veteran_xp_after: 45))
      assert {:ok, json} = Jason.encode(summary)
      assert Jason.decode!(json)["rating"] == nil
    end
  end

  # The minimum XP that lands on a given level: the (level-1)th threshold, or 0
  # for level 1.
  defp level_floor_xp(1), do: 0
  defp level_floor_xp(level), do: Enum.at(Progression.thresholds(), level - 2)
end
