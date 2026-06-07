defmodule PidroServerWeb.API.ProfileControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles

  defp auth(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
  end

  describe "show/2" do
    test "authed request returns all profile sections", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      for key <- [
            "user_id",
            "games_played",
            "wins",
            "losses",
            "win_rate",
            "first_seen_at",
            "account_age_days",
            "skill",
            "veteran",
            "heritage",
            "playstyle",
            "achievements",
            "achievements_catalog"
          ] do
        assert Map.has_key?(data, key), "expected key #{key} in profile payload"
      end

      assert Map.has_key?(data["skill"], "tier")
      assert Map.has_key?(data["skill"], "provisional")
      assert data["veteran"]["level"] != nil
      assert Map.has_key?(data["playstyle"], "avg_winning_bid")
    end

    test "raw rating internals are ABSENT from the payload (security contract)", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      refute Map.has_key?(data, "rating_mu")
      refute Map.has_key?(data, "rating_sigma")
      refute Map.has_key?(data, "rating_games_count")
      refute Map.has_key?(data, "heritage_flags")
      refute Map.has_key?(data, "playstyle_bidding_wins")
      refute Map.has_key?(data, "playstyle_bidding_attempts")

      # Not smuggled inside the skill object either.
      refute Map.has_key?(data["skill"], "rating_mu")
      refute Map.has_key?(data["skill"], "rating_sigma")
      refute Map.has_key?(data["skill"], "rating_games_count")
    end

    test "skill exposes a tier string in the enum and a boolean provisional", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      skill = json_response(conn, 200)["data"]["skill"]

      assert skill["tier"] in ["provisional", "bronze", "silver", "gold", "platinum", "master"]
      assert is_boolean(skill["provisional"])
    end

    test "unauthenticated request returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/profile")
      assert json_response(conn, 401)
    end

    test "fresh / never-played user gets sane defaults and provisional skill", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      assert data["games_played"] == 0
      assert data["win_rate"] == 0.0
      assert data["skill"] == %{"tier" => "provisional", "provisional" => true}
      assert data["heritage"] == []
      assert data["playstyle"]["bidding_win_rate"] == nil
      assert data["playstyle"]["aggression_insufficient"] == true
      assert data["achievements"] == []
    end

    test "migrated user shows veteran progression and heritage badges", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.import_legacy_progression(user, %{
          xp: 9_999,
          founding_member: true
        })

      conn = conn |> auth(user) |> get(~p"/api/v1/profile")
      data = json_response(conn, 200)["data"]

      assert data["veteran"]["level"] > 0
      assert data["veteran"]["xp"] == 9_999
      assert data["veteran"]["title"] != nil

      heritage_keys = Enum.map(data["heritage"], & &1["key"])
      assert "played_pidro_one" in heritage_keys
      assert "founding_member" in heritage_keys

      # Migration seeds no rating, so skill stays provisional.
      assert data["skill"]["provisional"] == true
    end
  end
end
