defmodule PidroServer.Profiles.LegacyImportTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Profiles
  alias PidroServer.Profiles.LegacyProgression
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Progression
  alias PidroServer.Progression.Heritage
  alias PidroServer.Rating
  alias PidroServer.Rating.Tier
  alias PidroServer.Repo

  defp insert_user do
    {:ok, user} =
      PidroServer.Accounts.Auth.register_user(%{
        username: "user_#{System.unique_integer([:positive])}",
        password: "password123"
      })

    user
  end

  defp profile(user_id), do: Repo.get_by!(PlayerProfile, user_id: user_id)

  describe "LegacyProgression struct" do
    test "fills defaults from a partial map" do
      assert %LegacyProgression{
               xp: 100,
               badges: [],
               premium: false,
               founding_member: false,
               playstyle: nil
             } = struct(LegacyProgression, %{xp: 100})
    end
  end

  describe "import_legacy_progression/2 — veteran XP/level mapping" do
    test "maps XP -> level via the shared curve, keeps XP verbatim" do
      user = insert_user()

      # 32_000 XP lands on the L20 milestone under the re-paced power-law curve.
      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 32_000})
      assert p.veteran_xp == 32_000
      assert p.veteran_level == Progression.level_for_xp(32_000)
      assert p.veteran_level == 20
    end

    test "xp: 0 -> level 1" do
      user = insert_user()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 0})
      assert p.veteran_xp == 0
      assert p.veteran_level == 1
    end
  end

  describe "import_legacy_progression/2 — heritage flags" do
    test "badges -> legacy_accolades; founding_member + played_pidro_one + legacy_level" do
      user = insert_user()

      assert {:ok, p} =
               Profiles.import_legacy_progression(user.id, %{
                 xp: 174,
                 badges: ["champion_2019", "marathon"],
                 founding_member: true
               })

      assert p.heritage_flags["played_pidro_one"] == true
      assert p.heritage_flags["legacy_accolades"] == ["champion_2019", "marathon"]
      assert p.heritage_flags["founding_member"] == true
      assert p.heritage_flags["legacy_level"] == Progression.level_for_xp(174)
    end

    test "premium: true -> legacy_premium flag + renders in Heritage.display" do
      user = insert_user()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 50, premium: true})
      assert p.heritage_flags["legacy_premium"] == true

      assert Enum.any?(
               Heritage.display(p.heritage_flags),
               &(&1.key == :legacy_premium and &1.value == true)
             )
    end

    test "premium: false -> flag false, no premium badge" do
      user = insert_user()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 50, premium: false})
      assert p.heritage_flags["legacy_premium"] == false
      refute Enum.any?(Heritage.display(p.heritage_flags), &(&1.key == :legacy_premium))
    end
  end

  describe "import_legacy_progression/2 — playstyle" do
    test "populated absolutely when present (count == wins)" do
      user = insert_user()

      assert {:ok, p} =
               Profiles.import_legacy_progression(user.id, %{
                 xp: 50,
                 playstyle: %{bidding_attempts: 40, bidding_wins: 12, won_bid_sum: 96}
               })

      assert p.playstyle_bidding_attempts == 40
      assert p.playstyle_bidding_wins == 12
      assert p.avg_winning_bid_sum == 96
      assert p.avg_winning_bid_count == 12
    end

    test "left at 0 when nil (no crash)" do
      user = insert_user()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 50, playstyle: nil})
      assert p.playstyle_bidding_attempts == 0
      assert p.playstyle_bidding_wins == 0
      assert p.avg_winning_bid_sum == 0
      assert p.avg_winning_bid_count == 0
    end
  end

  describe "import_legacy_progression/2 — skill stays provisional (no seed)" do
    test "rating left at default + count 0; Tier.classify -> :provisional" do
      user = insert_user()
      {default_mu, default_sigma} = Rating.default()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 9_999})
      assert p.rating_mu == default_mu
      assert p.rating_sigma == default_sigma
      assert p.rating_games_count == 0

      assert Tier.classify(%{
               rating_mu: p.rating_mu,
               rating_sigma: p.rating_sigma,
               rating_games_count: p.rating_games_count
             }) == %{tier: :provisional, provisional: true}
    end
  end

  describe "import_legacy_progression/2 — idempotency" do
    test "re-run returns :already_migrated and does not clobber the row" do
      user = insert_user()

      assert {:ok, first} =
               Profiles.import_legacy_progression(user.id, %{
                 xp: 174,
                 badges: ["a"],
                 premium: true,
                 founding_member: true,
                 playstyle: %{bidding_attempts: 40, bidding_wins: 12, won_bid_sum: 96}
               })

      snapshot = profile(user.id)

      # A second call with DIFFERENT data must short-circuit and write nothing.
      assert {:ok, :already_migrated} =
               Profiles.import_legacy_progression(user.id, %{
                 xp: 1,
                 badges: ["totally", "different"],
                 premium: false,
                 founding_member: false,
                 playstyle: %{bidding_attempts: 1, bidding_wins: 1, won_bid_sum: 1}
               })

      after_row = profile(user.id)

      # Byte-identical: nothing clobbered.
      assert after_row == snapshot
      assert after_row.veteran_xp == first.veteran_xp
      assert after_row.heritage_flags == first.heritage_flags
      assert after_row.playstyle_bidding_attempts == 40
    end
  end

  describe "import_legacy_progression/2 — input forms" do
    test "tolerates only xp given (plain map)" do
      user = insert_user()

      assert {:ok, p} = Profiles.import_legacy_progression(user.id, %{xp: 500})
      assert p.heritage_flags["legacy_accolades"] == []
      assert p.heritage_flags["founding_member"] == false
      assert p.heritage_flags["legacy_premium"] == false
      assert p.playstyle_bidding_attempts == 0
      assert p.rating_games_count == 0
    end

    test "accepts a %LegacyProgression{} struct" do
      user = insert_user()

      assert {:ok, p} =
               Profiles.import_legacy_progression(user.id, %LegacyProgression{
                 xp: 174,
                 badges: ["x"]
               })

      assert p.veteran_xp == 174
      assert p.heritage_flags["legacy_accolades"] == ["x"]
    end

    test "accepts a %User{} or a user id and produces the same row" do
      user_a = insert_user()
      user_b = insert_user()

      assert {:ok, by_user} = Profiles.import_legacy_progression(user_a, %{xp: 174})
      assert {:ok, by_id} = Profiles.import_legacy_progression(user_b.id, %{xp: 174})

      assert by_user.veteran_xp == by_id.veteran_xp
      assert by_user.veteran_level == by_id.veteran_level
      assert by_user.heritage_flags["played_pidro_one"] == true
      assert by_id.heritage_flags["played_pidro_one"] == true
    end
  end

  describe "get_profile_for_screen/1 — lands already showing" do
    test "shows veteran level/title, heritage badges, playstyle, provisional tier" do
      user = insert_user()

      assert {:ok, _} =
               Profiles.import_legacy_progression(user.id, %{
                 xp: 174,
                 badges: ["champion_2019"],
                 premium: true,
                 founding_member: true,
                 playstyle: %{bidding_attempts: 40, bidding_wins: 12, won_bid_sum: 96}
               })

      assert {:ok, screen} = Profiles.get_profile_for_screen(user.id)

      assert screen.veteran_level == Progression.level_for_xp(174)
      assert is_binary(screen.veteran_title) and screen.veteran_title != ""

      keys = Enum.map(screen.heritage, & &1.key)
      assert :played_pidro_one in keys
      assert :legacy_level in keys
      assert :legacy_accolades in keys
      assert :legacy_premium in keys
      assert :founding_member in keys

      assert is_number(screen.avg_winning_bid)
      assert is_number(screen.aggression_needle)

      assert Tier.classify(%{
               rating_mu: screen.rating_mu,
               rating_sigma: screen.rating_sigma,
               rating_games_count: screen.rating_games_count
             }) == %{tier: :provisional, provisional: true}
    end
  end
end
