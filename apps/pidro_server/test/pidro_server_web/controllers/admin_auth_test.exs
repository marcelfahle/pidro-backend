defmodule PidroServerWeb.AdminAuthTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Admins
  alias PidroServer.AdminsFixtures

  test "admin root shows the login screen", %{conn: conn} do
    assert get(conn, ~p"/admin") |> html_response(200) =~ "Sign in with your admin account"
  end

  test "anonymous and player-authenticated requests cannot reach ops routes", %{conn: conn} do
    conn = get(conn, ~p"/admin/games")
    assert redirected_to(conn) == ~p"/admin/login"

    player = AccountsFixtures.user_fixture()
    player_token = Token.generate(player)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{player_token}")
      |> get(~p"/admin/games")

    assert redirected_to(conn) == ~p"/admin/login"
  end

  test "the former dev ops route is no longer available", %{conn: conn} do
    assert get(conn, "/dev/games") |> response(404)
  end

  test "an authenticated admin can reach the ops panel", %{conn: conn} do
    admin = AdminsFixtures.admin_fixture()
    conn = log_in_admin(conn, admin) |> get(~p"/admin/games")

    assert html_response(conn, 200) =~ "Development Games"
  end

  test "a temporary-password login is restricted to the mandatory change screen", %{conn: conn} do
    admin =
      AdminsFixtures.admin_fixture(%{
        password: "temporary password",
        force_password_change: true
      })

    conn =
      post(conn, ~p"/admin/login", %{
        "admin" => %{"email" => admin.email, "password" => "temporary password"}
      })

    assert redirected_to(conn) == ~p"/admin/admins"

    conn = recycle(conn)
    assert get(conn, ~p"/admin/games") |> redirected_to() == ~p"/admin/admins"

    conn = recycle(conn) |> get(~p"/admin/admins")
    assert html_response(conn, 200) =~ "Change your temporary password"
  end

  test "deleting an admin stops the next event on their open LiveView", %{conn: conn} do
    acting_admin = AdminsFixtures.admin_fixture()
    deleted_admin = AdminsFixtures.admin_fixture()

    {:ok, view, _html} = live(log_in_admin(conn, deleted_admin), ~p"/admin/games")
    assert {:ok, removed_admin} = Admins.delete_admin(acting_admin, deleted_admin.id)
    assert removed_admin.id == deleted_admin.id

    render_click(view, "toggle_sort")
    assert_redirect(view, ~p"/admin/login")
  end

  test "local development keeps the no-login bypass", %{conn: conn} do
    original = Application.get_env(:pidro_server, :dev_routes)
    Application.put_env(:pidro_server, :dev_routes, true)

    on_exit(fn -> Application.put_env(:pidro_server, :dev_routes, original) end)

    assert get(conn, ~p"/admin/games") |> html_response(200) =~ "Development Games"
  end
end
