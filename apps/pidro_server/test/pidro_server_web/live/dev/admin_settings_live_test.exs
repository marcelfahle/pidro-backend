defmodule PidroServerWeb.Dev.AdminSettingsLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Admins
  alias PidroServer.AdminsFixtures

  setup :register_and_log_in_admin

  test "adds an admin and displays a usable temporary password once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/admins")

    html =
      render_submit(view, "add_admin", %{
        "admin" => %{"email" => "second.admin@example.com"}
      })

    assert html =~ "Temporary password for second.admin@example.com"

    temporary_password =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("code")
      |> LazyHTML.text()
      |> String.trim()

    admin = Admins.get_admin_by_email("second.admin@example.com")
    assert admin.force_password_change
    assert Admins.get_admin_by_email_and_password(admin.email, temporary_password)

    refute render_click(view, "dismiss_temporary_password") =~ temporary_password
  end

  test "removing an admin invalidates all of their sessions", %{conn: conn} do
    doomed_admin = AdminsFixtures.admin_fixture()
    token = Admins.generate_admin_session_token(doomed_admin)
    {:ok, view, _html} = live(conn, ~p"/admin/admins")

    render_click(view, "remove_admin", %{"id" => doomed_admin.id})

    assert is_nil(Admins.get_admin(doomed_admin.id))
    assert is_nil(Admins.get_admin_by_session_token(token))
  end

  test "the last admin cannot remove themselves", %{admin: admin, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/admins")

    html = render_click(view, "remove_admin", %{"id" => admin.id})

    assert html =~ "The last admin cannot remove themselves."
    assert Admins.get_admin(admin.id)
  end

  test "a forced-password admin cannot send a direct admin-management event", %{conn: conn} do
    admin =
      AdminsFixtures.admin_fixture(%{
        password: "temporary password",
        force_password_change: true
      })

    {:ok, view, _html} = live(log_in_admin(conn, admin), ~p"/admin/admins")

    html =
      render_hook(view, "add_admin", %{
        "admin" => %{"email" => "blocked.admin@example.com"}
      })

    assert html =~ "Change your temporary password before managing admins."
    refute Admins.get_admin_by_email("blocked.admin@example.com")
  end
end
