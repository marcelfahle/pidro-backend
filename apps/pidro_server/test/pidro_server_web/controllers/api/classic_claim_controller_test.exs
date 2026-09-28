defmodule PidroServerWeb.API.ClassicClaimControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{ClassicClaims, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

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

  test "an already claimed Classic account returns the exact sign-in path", %{conn: conn} do
    owner = AccountsFixtures.user_fixture()

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
        method: :apple,
        provider_id: "owner-apple-sub",
        install_id: "install-owner",
        legacy_data: %{xp: 10}
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
