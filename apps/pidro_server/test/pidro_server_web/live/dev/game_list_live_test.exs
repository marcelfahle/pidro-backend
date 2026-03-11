defmodule PidroServerWeb.Dev.GameListLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Games.{Lifecycle, RoomManager}

  setup do
    original = Application.get_env(:pidro_server, Lifecycle, [])

    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()

    on_exit(fn ->
      Application.put_env(:pidro_server, Lifecycle, original)
      RoomManager.reset_for_test()
    end)

    :ok
  end

  test "renders pacing controls and saves runtime values", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dev/games")

    assert html =~ "Game Pacing"
    assert html =~ "Save Pacing"

    params = %{
      "pacing" => %{
        "bot_delay_ms" => "2400",
        "bot_delay_variance_ms" => "500",
        "bot_min_delay_ms" => "700",
        "trick_transition_delay_ms" => "1600",
        "hand_transition_delay_ms" => "3500"
      }
    }

    _ = render_change(view, "update_pacing_form", params)
    assert render(view) =~ "Bots will act between 1900ms and 2900ms"

    _ = render_submit(view, "save_pacing", params)

    assert render(view) =~ "Bots will act between 1900ms and 2900ms"
    assert Lifecycle.config(:bot_delay_ms) == 2400
    assert Lifecycle.config(:bot_delay_variance_ms) == 500
    assert Lifecycle.config(:hand_transition_delay_ms) == 3500
  end

  test "reset restores lifecycle defaults from the dev panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dev/games")

    _ =
      render_submit(view, "save_pacing", %{
        "pacing" => %{
          "bot_delay_ms" => "3000",
          "bot_delay_variance_ms" => "200",
          "bot_min_delay_ms" => "900",
          "trick_transition_delay_ms" => "2100",
          "hand_transition_delay_ms" => "4100"
        }
      })

    _ = render_click(view, "reset_pacing")

    defaults = Lifecycle.defaults()
    assert render(view) =~ "Bots will act between 700ms and 2300ms"
    assert Lifecycle.config(:bot_delay_ms) == defaults.bot_delay_ms
    assert Lifecycle.config(:trick_transition_delay_ms) == defaults.trick_transition_delay_ms
  end

  test "ignores online count updates from lobby pubsub", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dev/games")

    assert html =~ "Game Pacing"

    send(
      view.pid,
      {:online_count_updated, %{count: 1, breakdown: %{playing: 1, spectating: 0, lobby: 0}}}
    )

    assert render(view) =~ "Game Pacing"
  end
end
