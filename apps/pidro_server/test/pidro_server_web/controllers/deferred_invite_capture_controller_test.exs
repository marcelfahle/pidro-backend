defmodule PidroServerWeb.DeferredInviteCaptureControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.DeferredMatcher
  alias PidroServer.Invites.Event
  alias PidroServer.Repo

  @valid_params %{
    "platform" => "ios",
    "os_major" => "18",
    "screen_class" => "compact",
    "locale" => "en-US",
    "timezone" => "Europe/Madrid"
  }

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    restart_matcher()

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      restart_matcher()
    end)

    :ok
  end

  test "captures a valid direct store click, records one safe event, and returns no body", %{
    conn: conn
  } do
    invite = open_invite!()

    conn =
      conn
      |> from_ip({203, 0, 113, 41})
      |> put_req_header("origin", "http://localhost:4002")
      |> put_req_header("sec-fetch-site", "same-site")
      |> post(~p"/j/#{invite.code}/deferred", @valid_params)

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:4002"]

    assert [%Event{kind: "store_clicked", platform: "ios", ua_class: "mobile"}] =
             Repo.all(from event in Event, where: event.invite_id == ^invite.id)

    signature = Map.put(normalized_params(@valid_params), :ip, "203.0.113.41")
    assert {:ok, code} = DeferredMatcher.consume([signature])
    assert code == invite.code
  end

  test "duplicate capture neither extends the hint nor duplicates the event", %{conn: conn} do
    invite = open_invite!()

    capture(conn, invite.code, {203, 0, 113, 42}, @valid_params)
    capture(build_conn(), invite.code, {203, 0, 113, 42}, @valid_params)

    assert Repo.aggregate(
             from(event in Event,
               where: event.invite_id == ^invite.id and event.kind == "store_clicked"
             ),
             :count,
             :id
           ) == 1
  end

  test "moved codes store the successor and invalid or unknown input stays empty", %{conn: conn} do
    {host, old_room} = host_and_room!()
    old = mint!(old_room, host)
    :ok = RoomManager.leave_room(host.id)
    {:ok, new_room} = RoomManager.create_room(host.id, %{name: "Again"})
    new = mint!(new_room, host)
    {:ok, _old} = Invites.supersede(old, new)

    assert conn |> capture(old.code, {203, 0, 113, 43}, @valid_params) |> response(204) == ""

    signature = Map.put(normalized_params(@valid_params), :ip, "203.0.113.43")
    assert {:ok, code} = DeferredMatcher.consume([signature])
    assert code == new.code

    assert build_conn()
           |> capture("ZZZZZZZZ", {203, 0, 113, 44}, @valid_params)
           |> response(204) == ""

    assert build_conn()
           |> capture(new.code, {203, 0, 113, 45}, %{@valid_params | "timezone" => ""})
           |> response(204) == ""
  end

  test "inactive invites do not create a hint or event", %{conn: conn} do
    invite = open_invite!()
    {:ok, invite} = Invites.revoke(invite)

    assert conn |> capture(invite.code, {203, 0, 113, 49}, @valid_params) |> response(204) == ""

    signature = Map.put(normalized_params(@valid_params), :ip, "203.0.113.49")
    assert :none = DeferredMatcher.consume([signature])
    assert Repo.aggregate(Event, :count, :id) == 0
  end

  test "rejects other browser origins and missing-origin cross-site requests", %{conn: conn} do
    invite = open_invite!()

    denied =
      conn
      |> from_ip({203, 0, 113, 46})
      |> put_req_header("origin", "https://attacker.example")
      |> post(~p"/j/#{invite.code}/deferred", @valid_params)

    assert response(denied, 403) == ""
    assert get_resp_header(denied, "access-control-allow-origin") == []

    denied_missing =
      build_conn()
      |> from_ip({203, 0, 113, 47})
      |> put_req_header("sec-fetch-site", "cross-site")
      |> post(~p"/j/#{invite.code}/deferred", @valid_params)

    assert response(denied_missing, 403) == ""

    allowed_same_origin =
      build_conn()
      |> from_ip({203, 0, 113, 48})
      |> put_req_header("sec-fetch-site", "same-origin")
      |> post(~p"/j/#{invite.code}/deferred", @valid_params)

    assert response(allowed_same_origin, 204) == ""
  end

  defp capture(conn, code, ip, params) do
    conn
    |> from_ip(ip)
    |> put_req_header("origin", "http://localhost:4002")
    |> put_req_header("sec-fetch-site", "same-site")
    |> post(~p"/j/#{code}/deferred", params)
  end

  defp normalized_params(params) do
    %{
      platform: String.downcase(params["platform"]),
      os_major: params["os_major"],
      screen_class: params["screen_class"],
      locale: String.downcase(params["locale"]),
      timezone: String.downcase(params["timezone"])
    }
  end

  defp open_invite! do
    {host, room} = host_and_room!()
    mint!(room, host)
  end

  defp host_and_room! do
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
    {host, room}
  end

  defp mint!(room, host) do
    {:ok, invite} =
      Invites.create_invite(%{
        room_id: room.id,
        room_code: room.code,
        host_user_id: host.id
      })

    invite
  end

  defp restart_matcher do
    case Supervisor.terminate_child(PidroServer.Supervisor, DeferredMatcher) do
      :ok -> Supervisor.restart_child(PidroServer.Supervisor, DeferredMatcher)
      {:error, :not_found} -> :ok
    end

    :ok
  end
end
