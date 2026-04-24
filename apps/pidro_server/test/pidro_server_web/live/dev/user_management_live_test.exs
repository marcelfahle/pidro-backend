defmodule PidroServerWeb.Dev.UserManagementLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Stats

  test "lists players with search filters and summary stats", %{conn: conn} do
    alpha = AccountsFixtures.user_fixture(%{username: "admin_alpha"})
    beta = AccountsFixtures.user_fixture(%{username: "admin_beta", guest: true})

    save_game(alpha, "ALFA1", "win")

    {:ok, view, html} = live(conn, ~p"/dev/users")

    assert html =~ "Pidro Ops"
    assert html =~ "Players"
    assert html =~ "admin_alpha"
    assert html =~ "admin_beta"
    assert html =~ "1 wins"

    html =
      render_change(view, "filter_users", %{
        "filters" => %{"search" => "admin_alpha", "guest" => "all", "sort" => "recent"}
      })

    assert html =~ "admin_alpha"
    refute html =~ "admin_beta"

    html =
      render_change(view, "filter_users", %{
        "filters" => %{"search" => "", "guest" => "guest", "sort" => "recent"}
      })

    assert html =~ "admin_beta"
    refute html =~ "admin_alpha"

    render_click(view, "request_delete", %{"id" => beta.id})
    assert render(view) =~ "Delete admin_beta?"

    render_click(view, "confirm_delete")
    refute Auth.get_user(beta.id)
  end

  test "shows player detail, history, and allows profile edits", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "detail_player"})
    save_game(user, "DETL1", "win")

    {:ok, view, html} = live(conn, ~p"/dev/users/#{user.id}")

    assert html =~ "detail_player"
    assert html =~ "Completed games"
    assert html =~ "DETL1"
    assert html =~ "WIN"

    render_submit(view, "save", %{
      "user" => %{
        "username" => "detail_renamed",
        "email" => "renamed@example.com",
        "guest" => "false"
      }
    })

    updated = Auth.get_user(user.id)
    assert updated.username == "detail_renamed"
    assert updated.email == "renamed@example.com"
    refute updated.guest

    assert render(view) =~ "detail_renamed"
  end

  test "deletes a player from the detail screen", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "delete_detail_player"})

    {:ok, view, _html} = live(conn, ~p"/dev/users/#{user.id}")

    render_click(view, "request_delete")
    assert render(view) =~ "Delete delete_detail_player?"

    render_click(view, "confirm_delete")
    assert_redirect(view, ~p"/dev/users")
    refute Auth.get_user(user.id)
  end

  defp save_game(user, room_code, result) do
    winner = if result == "win", do: "north_south", else: "east_west"

    {:ok, _game} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: %{"north_south" => 62, "east_west" => 41},
        duration_seconds: 900,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        player_ids: [user.id],
        player_results: %{
          user.id => %{
            "participation" => "played",
            "result" => result,
            "team" => "north_south",
            "position" => "north"
          }
        }
      })
  end
end
