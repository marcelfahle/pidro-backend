defmodule PidroServerWeb.Dev.GameDetailLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()

    on_exit(fn ->
      RoomManager.reset_for_test()
    end)

    :ok
  end

  test "renders recent users in the take-a-seat controls using username fallback", %{conn: conn} do
    host = AccountsFixtures.user_fixture(%{username: "debug_host"})
    recent_user = AccountsFixtures.user_fixture(%{username: "debug_recent"})
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Debug Table"})

    {:ok, _view, html} = live(conn, ~p"/dev/games/#{room.code}")

    assert html =~ "Take a Seat"
    assert html =~ recent_user.username
  end
end
