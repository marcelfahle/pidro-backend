defmodule PidroServerWeb.Dev.HistoryLiveTest do
  use PidroServer.ArchiveCase, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn
  import PidroServerWeb.ConnCase
  import Ecto.Query

  alias PidroServer.{AccountsFixtures, GameArchive, GameReports, Repo, RoomFixtures}
  alias PidroServer.GameArchive.Archive
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Stats.GameStats

  @endpoint PidroServerWeb.Endpoint
  setup do
    admin_ids = Repo.all(from a in PidroServer.Admins.Admin, select: a.id)

    on_exit(fn ->
      Repo.delete_all(from a in PidroServer.Admins.Admin, where: a.id not in ^admin_ids)
    end)

    {:ok, conn: build_conn()}
  end

  setup :register_and_log_in_admin

  setup do
    RoomManager.reset_for_test()
    config = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(config,
        dealer_selection_delay_ms: 0,
        deal_transition_delay_ms: 0,
        turn_timer_bid_ms: 600_000,
        turn_timer_play_ms: 600_000
      )
    )

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, config)
    end)

    :ok
  end

  test "real create, deal, bid, report, leave remains inspectable without a room", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{display_name: "Joachim"})
    {:ok, room} = RoomManager.create_room(user.id, %{solo: true})

    for position <- [:east, :south, :west],
        do: BotManager.start_bot(room.code, position, :basic, 5_000)

    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    assert {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> Pidro.Server.get_state(pid).phase == :bidding end)
    live_snapshot = Pidro.Server.get_snapshot(pid)

    assert {:ok, _} =
             GameAdapter.apply_action(room.code, live_snapshot.state.current_turn, {:bid, 8})

    instance = live_snapshot.game_instance_id

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{PidroServer.Accounts.Token.generate(user)}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/game-reports", Jason.encode!(report_body(room.code, instance)))
      |> json_response(201)

    report_id = response["data"]["id"]
    assert :ok = RoomManager.leave_room(user.id)
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    refute Process.alive?(pid)

    {:ok, view, html} =
      live(conn, "/admin/history?player=Joachim&room_code=#{room.code}&status=closed")

    assert html =~ instance
    assert html =~ "Abandoned / closed"
    assert has_element?(view, "a[href='/admin/history/#{instance}']")

    {:ok, view, html} = live(conn, "/admin/history/#{instance}")
    assert html =~ "Joachim"
    assert html =~ "bid_made"
    assert html =~ "Last saved revision"
    assert has_element?(view, "a[href='/admin/reports/#{report_id}']")

    refute has_element?(
             view,
             "[phx-click=execute_action], [phx-click=play_card], [phx-click=select_position]"
           )

    assert html =~ "UTC"

    render_patch(view, "/admin/history/#{instance}?revision=0")
    assert render(view) =~ "revision 0"
    render_patch(view, "/admin/history/#{instance}?revision=999999")
    assert render(view) =~ "No saved snapshot at this revision"

    {:ok, report_view, html} = live(conn, "/admin/reports/#{report_id}")
    assert html =~ "Client-reported timeline"
    assert html =~ "Unverified claims"
    assert html =~ "Abandoned / closed"
    assert has_element?(report_view, "a[href='/admin/users/#{user.id}']")
    assert has_element?(report_view, "a[href='/admin/history/#{instance}']")
  end

  test "archives keep reused rooms distinct, paginate equal timestamps, and honor time boundaries",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    for n <- 1..26,
        do: checkpoint("instance-#{String.pad_leading(to_string(n), 2, "0")}", user.id)

    Repo.update_all(from(a in Archive, where: ^user.id in a.user_ids),
      set: [started_at: ~U[2026-10-22 12:00:00.000000Z]]
    )

    {:ok, view, html} =
      live(
        conn,
        "/admin/history?user_id=#{user.id}&from=2026-10-22T14:00:00%2B02:00&to=2026-10-22T12:00:01Z"
      )

    assert has_element?(view, "#history-results article:nth-child(25)")
    refute has_element?(view, "#history-results article:nth-child(26)")
    assert html =~ "instance-26"
    refute html =~ "instance-01"

    assert {:ok, _, older} =
             view |> element("a", "Older results") |> render_click() |> follow_redirect(conn)

    assert older =~ "instance-01"
    refute older =~ "instance-02"

    {:ok, _, html} = live(conn, "/admin/history?user_id=#{user.id}&to=2026-10-22T12:00:00Z")
    assert html =~ "No matching evidence"
    {:ok, _, html} = live(conn, "/admin/history?game_instance_id=instance-04")
    assert html =~ "instance-04"
    refute html =~ "instance-05"
  end

  test "invalid filters, malformed cursor and ambiguous player names do not widen search", %{
    conn: conn
  } do
    AccountsFixtures.user_fixture(%{display_name: "Same Name"})
    AccountsFixtures.user_fixture(%{display_name: "Same Name"})

    for query <- [
          "user_id=bad",
          "status=oops",
          "from=2026-10-22",
          "revision=-1",
          "user_id[]=bad",
          "from=2026-10-23T00:00:00Z&to=2026-10-22T00:00:00Z",
          "before_id=only-one",
          "player=Same%20Name"
        ] do
      {:ok, view, _} = live(conn, "/admin/history?" <> query)
      assert has_element?(view, "[role=alert]")
      refute has_element?(view, "#history-results")
    end

    for path <- ["/admin/reports", "/admin/history/summaries"] do
      {:ok, view, _} = live(conn, path <> "?before_id=not-uuid&before_at=2026-10-22T00:00:00Z")
      assert has_element?(view, "[role=alert]", "Invalid page cursor")
    end
  end

  test "outcome, partial coverage and absent or unsupported evidence are not replay claims", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    checkpoint("partial", user.id)
    checkpoint("interrupted", user.id)
    checkpoint("completed", user.id)

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "partial"),
      set: [evidence_status: "partial", missing_revision_count: 3, status: "closed"]
    )

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "interrupted"),
      set: [status: "interrupted", evidence_status: "uncertain"]
    )

    Repo.update_all(from(a in Archive, where: a.game_instance_id == "completed"),
      set: [status: "complete", format_version: 99]
    )

    for {id, label} <- [
          {"partial", "Partial archive"},
          {"interrupted", "not a known crash time"},
          {"completed", "Unsupported archive format"},
          {"missing", "No archive for this instance"}
        ] do
      {:ok, _, html} = live(conn, "/admin/history/#{id}")
      assert html =~ label
    end

    Repo.query!("ALTER TABLE game_archives RENAME TO temporarily_unavailable_archives")

    try do
      {:ok, view, html} = live(conn, "/admin/history")
      assert has_element?(view, "[role=alert]", "Evidence storage is unavailable")
      refute html =~ "No matching evidence"
    after
      Repo.query!("ALTER TABLE temporarily_unavailable_archives RENAME TO game_archives")
    end
  end

  test "report filters use exact instance, user, build and report ID; client text is escaped", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    checkpoint("reported-one", user.id)
    checkpoint("reported-two", user.id)
    {:ok, first} = GameReports.create(user.id, report_body("SAME", "reported-one"))
    {:ok, second} = GameReports.create(user.id, report_body("SAME", "reported-two"))

    {:ok, _, html} =
      live(
        conn,
        "/admin/reports?user_id=#{user.id}&game_instance_id=reported-one&build=42&report_id=#{first.id}"
      )

    assert html =~ first.id
    refute html =~ second.id
    # Defense-in-depth against legacy/untrusted persisted text, beyond ingestion validation.
    first
    |> Ecto.Changeset.change(
      events: [
        %{
          "type" => "<script>alert(1)</script>",
          "action" => "none",
          "code" => "failed",
          "offset_ms" => 0
        }
      ]
    )
    |> Repo.update!()

    {:ok, _, html} = live(conn, "/admin/reports/#{first.id}")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert(1)</script>"
  end

  test "saved seat states, cold players and scoring are faithfully projected", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    seats = %{
      north: %{user_id: user.id, occupant_type: :human, status: :reconnecting},
      east: %{occupant_type: :human, status: :grace},
      south: %{occupant_type: :human, status: :connected, substitute: true},
      west: %{occupant_type: :bot, status: :bot_substitute, substitute: false}
    }

    state = Pidro.Core.GameState.new(seed: 7) |> Map.put(:phase, :scoring)
    state = put_in(state.players.north.eliminated?, true)

    snapshot = %{
      game_instance_id: "saved-seats",
      state_revision: 0,
      state: state,
      presentation: %{},
      server_time_ms: System.system_time(:millisecond)
    }

    GameArchive.checkpoint!("SAME", seats, snapshot, %{
      kind: :start,
      engine_events: [],
      events_replaced: false
    })

    {:ok, view, _} = live(conn, "/admin/history/saved-seats")
    assert has_element?(view, ".watch-phase", "scoring")
    assert has_element?(view, "#watch-seat-north", "Reconnecting")
    assert has_element?(view, "#watch-seat-north", "Cold")
    assert has_element?(view, "#watch-seat-east", "Reconnecting")
    assert has_element?(view, "#watch-seat-south", "Connected")
    refute has_element?(view, "#watch-seat-south", "Bot covering")
    assert has_element?(view, "#watch-seat-west", "Bot covering")

    Repo.get!(Archive, "saved-seats")
    |> Ecto.Changeset.change(participants: %{}, participation_truncated: true)
    |> Repo.update!()

    html = render_patch(view, "/admin/history/saved-seats")
    assert html =~ "No initial seat evidence was captured"
    assert html =~ "Player search may omit later participants"
    assert has_element?(view, "#watch-seat-north", "unknown")
    refute has_element?(view, "#watch-seat-north", "Connected")
    refute has_element?(view, "#watch-seat-north", "Open")
  end

  test "legacy summaries never link a reused room without an instance", %{conn: conn} do
    summary =
      Repo.insert!(%GameStats{
        room_code: "SAME",
        completed_at: ~U[2025-10-01 12:00:00Z],
        final_scores: %{"north_south" => 62, "east_west" => 27}
      })

    {:ok, view, html} = live(conn, "/admin/history/summaries/#{summary.id}")
    assert html =~ "Summary-only"
    assert html =~ "No instance ID was recorded"
    assert html =~ "62"
    refute has_element?(view, "a[href='/admin/games/SAME']")
    {:ok, _, html} = live(conn, "/admin/history/summaries?room_code=SAME")
    assert html =~ summary.id
  end

  test "anonymous, player, temporary and revoked admin sessions cannot read private evidence", %{
    conn: conn,
    admin: admin
  } do
    for path <- [
          "/admin/history",
          "/admin/history/secret",
          "/admin/reports",
          "/admin/reports/#{Ecto.UUID.generate()}"
        ] do
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), path)
    end

    player_conn =
      build_conn()
      |> put_req_header(
        "authorization",
        "Bearer #{PidroServer.Accounts.Token.generate(AccountsFixtures.user_fixture())}"
      )

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(player_conn, "/admin/history")
    {:ok, view, _} = live(conn, "/admin/history")
    Repo.delete_all(from t in PidroServer.Admins.AdminToken, where: t.admin_id == ^admin.id)
    render_patch(view, "/admin/history?room_code=SAME")
    assert_redirect(view, "/admin/login")
    temporary = PidroServer.AdminsFixtures.admin_fixture(%{force_password_change: true})

    assert {:error, {:redirect, %{to: "/admin/admins"}}} =
             live(log_in_admin(build_conn(), temporary), "/admin/history")
  end

  defp checkpoint(id, user_id) do
    state = Pidro.Core.GameState.new(seed: 7)

    snapshot = %{
      game_instance_id: id,
      state_revision: 0,
      state: state,
      presentation: %{},
      server_time_ms: System.system_time(:millisecond)
    }

    GameArchive.checkpoint!(
      "SAME",
      %{north: %{user_id: user_id, occupant_type: :human}},
      snapshot,
      %{kind: :start, engine_events: [], events_replaced: false}
    )
  end

  defp report_body(room, instance),
    do: %{
      "room_code" => room,
      "game_instance_id" => instance,
      "app_version" => "1.2.3",
      "build" => "42",
      "platform" => "ios",
      "events" => [
        %{
          "type" => "timeout",
          "code" => "unavailable",
          "action" => "bid",
          "offset_ms" => 37,
          "state_revision" => 2
        }
      ]
    }

  defp wait(fun, attempts \\ 100)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait(fun, attempts - 1)
    end
  end
end
