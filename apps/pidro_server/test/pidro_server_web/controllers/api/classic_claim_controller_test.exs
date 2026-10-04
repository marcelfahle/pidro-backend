defmodule PidroServerWeb.API.ClassicClaimControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{ClassicClaims, ClassicClaimTicket, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  test "verifies Classic ownership and returns a user-bound preview ticket", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture()

    Req.Test.expect(PidroServer.Accounts.ClassicClient, fn classic_conn ->
      {:ok, body, classic_conn} = Plug.Conn.read_body(classic_conn)

      assert Jason.decode!(body) == %{
               "login" => "old@example.com",
               "password" => "classic-password"
             }

      # Real /internal/claims/verify_password payload shape (pidro_api).
      Req.Test.json(classic_conn, %{
        "classic" => %{
          "id" => 70_000,
          "username" => "Veteran",
          "member_since" => "2011-01-02T00:00:00Z",
          "xp" => 500,
          "level" => 14,
          "games" => %{"legacy_played_games" => 0, "total_game" => 88}
        }
      })
    end)

    data =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
      |> post(~p"/api/v1/classic/verify", %{
        method: "password",
        login: "old@example.com",
        password: "classic-password"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert is_binary(data["ticket"])
    assert is_binary(data["expires_at"])

    assert data["classic"] == %{
             "name" => "Veteran",
             "games_played" => 88,
             "level" => 14,
             "member_since" => "2011-01-02T00:00:00Z",
             "name_allowed" => true
           }

    assert Repo.get_by!(PidroServer.Accounts.ClassicClaimTicket, classic_user_id: 70_000).bound_user_id ==
             guest.id
  end

  test "a malformed Apple token is a retryable authentication failure", %{conn: conn} do
    malformed =
      Base.url_encode64("1", padding: false) <>
        "." <> Base.url_encode64("{}", padding: false) <> ".AA"

    assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} =
             conn
             |> post(~p"/api/v1/classic/verify", %{
               method: "apple",
               identity_token: malformed,
               install_id: "malformed-apple"
             })
             |> json_response(401)

    assert Repo.aggregate(PidroServer.Accounts.ClassicClaimTicket, :count) == 0
  end

  test "claims onto the authenticated user and returns a usable session", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture()

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_001,
        method: :apple,
        provider_id: "controller-apple-sub",
        user_id: guest.id,
        legacy_data: %{classic_user_id: 70_001, xp: 75}
      })

    data =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
      |> post(~p"/api/v1/classic/claim", %{ticket: ticket})
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["user"]["id"] == guest.id
    assert is_binary(data["token"])
    assert Repo.get!(User, guest.id).classic_user_id == 70_001
  end

  test "stores a declaration on a newly created Classic account", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_101,
        method: :facebook,
        provider_id: "age-facebook-id",
        install_id: "age-install",
        legacy_data: %{
          classic_user_id: 70_101,
          classic_username: "Age Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    user =
      conn
      |> post(~p"/api/v1/classic/claim", %{
        ticket: ticket,
        install_id: "age-install",
        account: %{username: "age_veteran"},
        age_band: "18_plus",
        terms_version: "1"
      })
      |> json_response(200)
      |> get_in(["data", "user"])

    assert user["age_band"] == "18_plus"
    assert user["terms_version"] == "1"

    persisted = Repo.get!(User, user["id"])
    assert persisted.age_band == "18_plus"
    assert persisted.terms_version == "1"
    assert %DateTime{} = persisted.age_declared_at
    assert %DateTime{} = persisted.terms_accepted_at
  end

  test "refuses or validates a declaration without redeeming the Classic ticket", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_102,
        method: :facebook,
        provider_id: "blocked-facebook-id",
        install_id: "blocked-install",
        legacy_data: %{
          classic_user_id: 70_102,
          classic_username: "Blocked Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    base = %{
      ticket: ticket,
      install_id: "blocked-install",
      account: %{username: "must_stay_missing"}
    }

    assert %{"errors" => [%{"code" => "AGE_NOT_ELIGIBLE"}]} =
             conn
             |> post(~p"/api/v1/classic/claim", Map.put(base, :age_band, "under_13"))
             |> json_response(403)

    assert %{"errors" => [%{"code" => "terms_version"}]} =
             build_conn()
             |> post(~p"/api/v1/classic/claim", Map.put(base, :terms_version, ""))
             |> json_response(422)

    refute Repo.get_by(User, username: "must_stay_missing")
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 70_102).redeemed_by_id == nil
  end

  test "rejects a malformed Bearer header before touching an install-bound ticket", %{conn: conn} do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_002,
        method: :facebook,
        provider_id: "controller-facebook-id",
        install_id: "install-70",
        legacy_data: %{classic_user_id: 70_002, xp: 75}
      })

    assert json_response(
             conn
             |> put_req_header("authorization", "not-a-bearer")
             |> post(~p"/api/v1/classic/claim", %{
               ticket: ticket,
               install_id: "install-70",
               account: %{username: "must_not_exist"}
             }),
             401
           )

    refute Repo.get_by(User, username: "must_not_exist")
  end

  test "rejects a non-object account without redeeming the ticket", %{conn: conn} do
    guest = AccountsFixtures.guest_fixture(%{display_name: "Original Guest"})

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_004,
        method: :password,
        user_id: guest.id,
        legacy_data: %{
          classic_user_id: 70_004,
          classic_username: "Classic Veteran",
          classic_name_allowed: true,
          xp: 75
        }
      })

    assert %{
             "errors" => [
               %{"code" => "account", "detail" => "must be an object"}
             ]
           } =
             conn
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/classic/claim", %{ticket: ticket, account: []})
             |> json_response(422)

    persisted = Repo.get!(User, guest.id)
    assert persisted.classic_user_id == nil
    assert persisted.display_name == "Original Guest"
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 70_004).redeemed_by_id == nil
  end

  test "an already claimed Classic account returns the exact sign-in path", %{conn: conn} do
    owner =
      %User{}
      |> User.social_registration_changeset(%{username: "controller_owner"})
      |> Repo.insert!()

    owner
    |> User.classic_claim_changeset(%{
      classic_user_id: 70_003,
      classic_claimed_at: DateTime.utc_now(),
      apple_sub: "owner-apple-sub"
    })
    |> Repo.update!()

    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 70_003,
        method: :facebook,
        provider_id: "different-facebook-id",
        install_id: "install-owner",
        legacy_data: %{
          xp: 10,
          classic_username: "Fuckface",
          classic_name_allowed: false
        }
      })

    assert %{
             "errors" => [
               %{
                 "code" => "ALREADY_CLAIMED",
                 "action" => %{
                   "type" => "sign_in",
                   "method" => "apple",
                   "endpoint" => "/api/v1/auth/apple"
                 }
               }
             ]
           } =
             conn
             |> post(~p"/api/v1/classic/claim", %{
               ticket: ticket,
               install_id: "install-owner",
               account: %{username: "not_created"}
             })
             |> json_response(409)

    refute Repo.get_by(User, username: "not_created")
  end
end
