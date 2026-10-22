defmodule PidroServerWeb.API.GameReportControllerTest do
  use PidroServerWeb.ConnCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{GameReports, Repo}
  alias PidroServer.Accounts.Token
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Stats.GameStats

  setup do
    if is_nil(Process.whereis(RoomManager)), do: start_supervised!(RoomManager)
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    user = user_fixture()
    instance = Ecto.UUID.generate()

    Repo.insert!(%GameStats{
      room_code: "ABCDEF",
      game_instance_id: instance,
      player_ids: [user.id],
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    body = %{
      "room_code" => "ABCDEF",
      "game_instance_id" => instance,
      "app_version" => "1.2.3",
      "build" => "42",
      "platform" => "ios",
      "events" => [
        %{
          "type" => "tap",
          "code" => "ok",
          "action" => "bid",
          "offset_ms" => 0,
          "action_id" => "attempt-1",
          "state_revision" => 17
        }
      ]
    }

    %{user: user, body: body}
  end

  defp submit(user, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/game-reports", Jason.encode!(body))
  end

  test "persists only authoritative ownership and server metadata", %{user: user, body: body} do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {response, log} =
      ExUnit.CaptureLog.with_log([formatter: {PidroServer.DiagnosticsFormatter, %{}}], fn ->
        submit(user, body) |> json_response(201)
      end)

    report = GameReports.admin_get(response["data"]["id"])
    assert report.user_id == user.id
    assert report.events == body["events"]
    assert report.inserted_at
    assert report.id != body["game_instance_id"]
    assert Enum.any?(GameReports.admin_list(), &(&1.id == report.id))
    assert log =~ report.id
    assert log =~ "report_created"
    refute log =~ "attempt-1"
    refute log =~ "Bearer"
  end

  test "requires exact bearer auth", %{body: body} do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/game-reports", Jason.encode!(body))
           |> json_response(401)

    assert build_conn()
           |> put_req_header("authorization", "bearer invalid")
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/game-reports", Jason.encode!(body))
           |> json_response(401)
  end

  test "rejects spoofing, cards, credentials and unknown nested keys", %{user: user, body: body} do
    for key <- ~w(user_id token cards password) do
      assert submit(user, Map.put(body, key, user.id)) |> json_response(422)
      event = body["events"] |> hd() |> Map.put(key, "secret")
      assert submit(user, Map.put(body, "events", [event])) |> json_response(422)
    end

    assert GameReports.admin_list() == []
  end

  test "requires exact game membership, not room knowledge", %{user: user, body: body} do
    assert submit(user_fixture(), body) |> json_response(403)

    assert submit(user, Map.put(body, "game_instance_id", Ecto.UUID.generate()))
           |> json_response(403)

    assert submit(user, Map.put(body, "room_code", "REUSED")) |> json_response(403)
    assert GameReports.admin_list() == []
  end

  test "durable per-user quota is five per rolling hour", %{user: user, body: body} do
    for _ <- 1..5, do: assert(submit(user, body) |> json_response(201))
    conn = submit(user, body)
    assert json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") == ["3600"]
    assert length(GameReports.admin_list()) == 5
  end

  test "invalid-report spam is bounded before membership queries", %{user: user} do
    for _ <- 1..10, do: assert(submit(user, %{}) |> json_response(422))
    assert submit(user, %{}) |> json_response(429)
    assert GameReports.admin_list() == []
  end

  test "rejects out-of-range revisions, tokens and oversized strings", %{user: user, body: body} do
    event = hd(body["events"])

    for invalid <- [
          Map.put(event, "state_revision", -1),
          Map.put(event, "state_revision", 9_007_199_254_740_992),
          Map.put(event, "action_id", "eyJheader.eyJpayload.signature"),
          Map.put(event, "action_id", String.duplicate("x", 65)),
          Map.put(event, "code", "private free text")
        ] do
      assert submit(user, Map.put(body, "events", [invalid])) |> json_response(422)
    end

    assert submit(user, Map.put(body, "app_version", String.duplicate("1", 33)))
           |> json_response(422)

    assert GameReports.admin_list() == []
  end

  test "bounds raw body before JSON parsing and bounds event count", %{user: user, body: body} do
    assert submit(user, Map.put(body, "events", List.duplicate(hd(body["events"]), 101)))
           |> json_response(422)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/game-reports", String.duplicate("x", 32_769))

    assert json_response(conn, 413)
    assert GameReports.admin_list() == []
  end

  test "ops cleanup deletes only expired rows and honors batch bound", %{user: user, body: body} do
    for _ <- 1..3, do: assert(submit(user, body) |> json_response(201))
    [fresh | old] = GameReports.admin_list()

    for report <- old do
      report
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -31 * 86_400))
      |> Repo.update!()
    end

    assert {1, nil} = GameReports.cleanup(1)
    assert {1, nil} = GameReports.cleanup(1)
    assert {0, nil} = GameReports.cleanup()
    assert GameReports.admin_get(fresh.id)
  end

  test "supervised scheduled retention runs repeatedly against the real database", %{
    user: user,
    body: body
  } do
    id = submit(user, body) |> json_response(201) |> get_in(["data", "id"])

    pid =
      start_supervised!(
        {PidroServer.GameReports.Cleanup, [name: nil, enabled: true, interval_ms: 20]}
      )

    for _ <- 1..2 do
      GameReports.admin_get(id)
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -31 * 86_400))
      |> Repo.update!()

      assert wait_until_deleted(id, 100)
      assert Process.alive?(pid)

      if is_nil(GameReports.admin_get(id)) do
        Repo.insert!(%PidroServer.GameReports.Report{
          id: id,
          user_id: user.id,
          room_code: body["room_code"],
          game_instance_id: body["game_instance_id"],
          app_version: "1.2.3",
          build: "42",
          platform: "ios",
          events: body["events"]
        })
      end
    end

    assert GameReports.admin_get(id)
  end

  defp wait_until_deleted(_id, 0), do: false

  defp wait_until_deleted(id, attempts) do
    if GameReports.admin_get(id) do
      Process.sleep(10)
      wait_until_deleted(id, attempts - 1)
    else
      true
    end
  end

  test "current seated players only, wrong instances and missing games fail closed", %{
    user: user,
    body: body
  } do
    {:ok, room} = RoomManager.create_room(user.id, %{})

    for _ <- 1..3 do
      {:ok, _, _} = RoomManager.join_room(room.code, user_fixture().id)
    end

    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, snapshot} = GameAdapter.get_snapshot(room.code)
    body = %{body | "room_code" => room.code, "game_instance_id" => snapshot.game_instance_id}
    assert submit(user, body) |> json_response(201)
    outsider = user_fixture()
    {:ok, _} = RoomManager.join_spectator_room(room.code, outsider.id)
    assert submit(outsider, body) |> json_response(403)

    assert submit(user, Map.put(body, "game_instance_id", Ecto.UUID.generate()))
           |> json_response(403)

    :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
    assert submit(user, body) |> json_response(403)
  end

  test "database errors fail closed without inserting", %{user: user, body: body} do
    {:ok, room} = RoomManager.create_room(user.id, %{})
    for _ <- 1..3, do: RoomManager.join_room(room.code, user_fixture().id)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, before} = GameAdapter.get_snapshot(room.code)
    # Transaction-local relation rename forces the real quota query to fail,
    # while the membership query and bearer authentication still work.
    Repo.transaction(fn ->
      Repo.query!("ALTER TABLE game_reports RENAME TO unavailable_game_reports")
      assert submit(user, body) |> json_response(503)

      assert {:ok, _} =
               RoomManager.apply_player_action(room.code, user.id, :north, :select_dealer)

      assert {:ok, after_action} = GameAdapter.get_snapshot(room.code)
      assert after_action.state_revision > before.state_revision
      Repo.rollback(:expected)
    end)

    assert GameReports.admin_list() == []
  end
end
