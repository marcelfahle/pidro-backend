defmodule PidroServerWeb.Dev.GameDetailLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.BotBrain
  alias PidroServer.Games.Bots.Strategies.RulebookStrategy
  alias PidroServer.Games.{GameAdapter, RoomManager}

  setup :register_and_log_in_admin

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    :ok
  end

  test "renders recent users in the take-a-seat controls using username fallback", %{conn: conn} do
    host = AccountsFixtures.user_fixture(%{username: "debug_host"})
    recent_user = AccountsFixtures.user_fixture(%{username: "debug_recent"})
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Debug Table"})

    {:ok, _view, html} = live(conn, ~p"/admin/games/#{room.code}")

    assert html =~ "Take a Seat"
    assert html =~ recent_user.username
  end

  test "renders an ownerless room", %{conn: conn} do
    host = AccountsFixtures.user_fixture(%{username: "departed_host"})
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Ownerless Table"})
    set_room_owner(room.code, nil)

    {:ok, _view, html} = live(conn, ~p"/admin/games/#{room.code}")

    assert html =~ "No owner"
  end

  describe "bot reasoning" do
    setup do
      original = Application.get_env(:pidro_server, PidroServer.Games.Lifecycle, [])

      Application.put_env(
        :pidro_server,
        PidroServer.Games.Lifecycle,
        Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
      )

      on_exit(fn ->
        Application.put_env(:pidro_server, PidroServer.Games.Lifecycle, original)
      end)

      [host | others] = for _ <- 1..4, do: AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Reasons"})
      for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, game} = GameAdapter.get_state(room.code)

      if game.phase == :dealer_selection,
        do: {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

      wait_for_bidding(room.code)
      %{room: room}
    end

    defp wait_for_bidding(room_code, attempts \\ 400) do
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding, current_turn: turn}} when turn != nil ->
          :ok

        _ when attempts > 0 ->
          Process.sleep(5)
          wait_for_bidding(room_code, attempts - 1)

        other ->
          flunk("bidding never started: #{inspect(other, limit: 3)}")
      end
    end

    defp bot_move(room_code) do
      {:ok, game} = GameAdapter.get_state(room_code)

      :ok =
        BotBrain.execute_move(
          %{room_code: room_code, position: game.current_turn, strategy: RulebookStrategy},
          "Test"
        )

      game.current_turn
    end

    test "a bot move publishes one reason on its own topic and none on the game topic", %{
      room: room
    } do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room.code))
      {:ok, before} = GameAdapter.get_state(room.code)

      position = bot_move(room.code)

      assert_receive {:bot_reasoning, code, %{position: ^position, reason: reason} = payload}
      assert code == room.code
      assert payload.event_index == length(before.events)
      assert reason =~ ~r/^[A-Z][^.]*\.$/
      refute_receive {:bot_reasoning, _, _}, 100
    end

    test "a failed action publishes nothing", %{room: room} do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room.code))
      {:ok, game} = GameAdapter.get_state(room.code)

      ExUnit.CaptureLog.capture_log(fn ->
        BotBrain.execute_move(
          %{room_code: room.code, position: game.current_turn, strategy: RulebookStrategy},
          "Test",
          fn _code, _position, _action -> {:error, :rejected} end
        )
      end)

      refute_receive {:bot_reasoning, _, _}, 100
    end

    test "shows each reason before the event its move produced, only while the toggle is on",
         %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/admin/games/#{room.code}")

      first = bot_move(room.code)
      second = bot_move(room.code)
      html = render(view)

      first_reason = :binary.match(html, "#{position_name(first)} (Bot) chose")
      second_reason = :binary.match(html, "#{position_name(second)} (Bot) chose")
      assert first_reason != :nomatch and second_reason != :nomatch
      assert first_reason < first_action(html, first)
      assert first_action(html, first) < second_reason
      assert second_reason < first_action(html, second)

      html = view |> element("input[phx-click=toggle_bot_reasoning]") |> render_click()
      refute html =~ "(Bot) chose"

      html = view |> element("input[phx-click=toggle_bot_reasoning]") |> render_click()
      assert html =~ "(Bot) chose"
    end

    test "undo removes the reason for the undone move and keeps earlier ones",
         %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/admin/games/#{room.code}")

      first = bot_move(room.code)
      second = bot_move(room.code)
      assert render(view) =~ "#{position_name(second)} (Bot) chose"

      html = view |> element("button[phx-click=undo_last_action]") |> render_click()

      assert html =~ "#{position_name(first)} (Bot) chose"
      refute html =~ "#{position_name(second)} (Bot) chose"
    end

    test "a page opened mid-game renders without earlier reasons", %{conn: conn, room: room} do
      bot_move(room.code)
      {:ok, view, html} = live(conn, ~p"/admin/games/#{room.code}")

      refute html =~ "(Bot) chose"
      assert Process.alive?(view.pid)

      bot_move(room.code)
      assert render(view) =~ "(Bot) chose"
    end

    # The first bid or pass line for the seat in the event log.
    defp first_action(html, position) do
      name = position_name(position)

      [" passed", " bid "]
      |> Enum.map(&:binary.match(html, name <> &1))
      |> Enum.reject(&(&1 == :nomatch))
      |> Enum.min()
    end

    defp position_name(position),
      do: position |> Atom.to_string() |> String.capitalize()
  end

  defp set_room_owner(room_code, host_id) do
    :sys.replace_state(RoomManager, fn state ->
      update_in(state.rooms[room_code], &%{&1 | host_id: host_id})
    end)
  end
end
