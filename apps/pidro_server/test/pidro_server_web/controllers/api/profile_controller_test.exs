defmodule PidroServerWeb.API.ProfileControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.Token
  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles
  alias PidroServer.Repo

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
      assert data["username"] == user.username
      assert data["display_name"] == user.display_name
      assert Map.has_key?(data, "avatar_url")
      assert Map.has_key?(data, "bio")
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

  describe "PATCH /api/v1/profile" do
    test "creates, normalizes, omits, and clears only the caller's bio", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{display_name: "Owner"})
      other = AccountsFixtures.user_fixture(%{display_name: "Other"})

      assert %{"data" => %{"bio" => "first\nsecond"}} =
               conn
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{
                 "bio" => "\uFEFF first\r\nsecond \u3000",
                 "user_id" => other.id,
                 "display_name" => "Hacked",
                 "email" => "private@example.com"
               })
               |> json_response(200)

      assert Repo.get!(PidroServer.Accounts.User, user.id).display_name == "Owner"
      assert Repo.get!(PidroServer.Accounts.User, other.id).bio == nil

      assert %{"data" => %{"bio" => "first\nsecond"}} =
               build_conn() |> auth(user) |> patch(~p"/api/v1/profile", %{}) |> json_response(200)

      assert %{"data" => %{"bio" => nil}} =
               build_conn()
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{"bio" => " \t\r\n\u00A0"})
               |> json_response(200)
    end

    test "counts Unicode scalars, preserves Unicode and rejects invalid values" do
      user = AccountsFixtures.user_fixture()
      zwj_sequence = "👩‍👩‍👧‍👦"
      combining = "e\u0301"

      for bio <- [
            String.duplicate("a", 280),
            String.duplicate("界", 280),
            String.duplicate("😀", 280)
          ] do
        assert %{"data" => %{"bio" => ^bio}} =
                 build_conn()
                 |> auth(user)
                 |> patch(~p"/api/v1/profile", %{"bio" => bio})
                 |> json_response(200)
      end

      preserved = "\u0085\u200B#{zwj_sequence}#{combining}\u0085\u200B"

      assert %{"data" => %{"bio" => ^preserved}} =
               build_conn()
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{"bio" => preserved})
               |> json_response(200)

      for invalid <- [String.duplicate("a", 281), "has\0nul", 12, true, %{}, []] do
        assert build_conn()
               |> auth(user)
               |> patch(~p"/api/v1/profile", %{"bio" => invalid})
               |> json_response(422)
      end

      refute PidroServer.Accounts.User.bio_changeset(user, %{bio: <<255>>}).valid?
    end
  end

  describe "GET /api/v1/profiles/:id" do
    test "returns the exact public allowlist to registered and guest callers" do
      owner = AccountsFixtures.user_fixture(%{display_name: "Public Name"})
      guest = AccountsFixtures.guest_fixture()
      {:ok, _} = Auth.update_bio(owner.id, %{bio: "Public bio"})

      for caller <- [AccountsFixtures.user_fixture(), guest] do
        data =
          build_conn()
          |> auth(caller)
          |> get(~p"/api/v1/profiles/#{owner.id}")
          |> json_response(200)
          |> Map.fetch!("data")

        assert Map.keys(data) |> Enum.sort() ==
                 ~w(avatar_url bio display_name user_id username)a
                 |> Enum.map(&Atom.to_string/1)
                 |> Enum.sort()

        assert data["user_id"] == owner.id
        assert data["username"] == owner.username
        assert data["display_name"] == "Public Name"
        assert data["bio"] == "Public bio"
        refute Map.has_key?(data, "email")
        refute Map.has_key?(data, "token")
      end
    end

    test "missing and malformed UUIDs are 404 and authentication is required", %{conn: conn} do
      caller = AccountsFixtures.user_fixture()

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert build_conn()
               |> auth(caller)
               |> get("/api/v1/profiles/#{id}")
               |> json_response(404)
      end

      assert conn |> get(~p"/api/v1/profiles/#{caller.id}") |> json_response(401)
    end

    test "guest upgrade preserves the bio on the same row" do
      guest = AccountsFixtures.guest_fixture()
      {:ok, _} = Auth.update_bio(guest.id, %{bio: "Keep me"})

      assert {:ok, upgraded} =
               Auth.upgrade_guest(guest, %{email: "upgrade@example.com", password: "long-enough"})

      assert upgraded.id == guest.id
      assert Repo.get!(PidroServer.Accounts.User, guest.id).bio == "Keep me"
    end
  end
end
