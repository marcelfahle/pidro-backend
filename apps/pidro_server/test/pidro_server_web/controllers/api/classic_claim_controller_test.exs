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
end
