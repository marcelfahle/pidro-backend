defmodule PidroServerWeb.InvitePageControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.Event
  alias PidroServer.Repo

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  describe "GET /j/:code" do
    test "renders an open invite with canonical social metadata and no side effects", %{
      conn: conn
    } do
      {host, room} = host_and_room(%{display_name: "Marcel & friends"})
      invite = mint!(room, host)
      event_count = Repo.aggregate(Event, :count, :id)

      conn = get(conn, ~p"/j/#{invite.code}")
      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "Marcel & friends"
      assert LazyHTML.text(LazyHTML.query(document, "[data-seat-count]")) =~ "1 of 4"
      assert attribute(document, "link[rel=canonical]", "href") == canonical(invite.code)
      assert attribute(document, "meta[property='og:title']", "content") =~ "Marcel & friends"
      assert attribute(document, "meta[property='og:url']", "content") == canonical(invite.code)
      assert attribute(document, "meta[property='og:image']", "content") =~ "/images/invite/"
      assert attribute(document, "meta[name=apple-itunes-app]", "content") =~ "app-id=1137091987"
      assert attribute(document, "meta[name=robots]", "content") == "noindex, nofollow"
      refute html_response(conn, 200) =~ room.code
      assert Repo.aggregate(Event, :count, :id) == event_count
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [vary] = get_resp_header(conn, "vary")
      assert String.downcase(vary) == "user-agent"
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "connect-src http://localhost:4002"
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "crawler receives metadata and an inert minimal body", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      conn =
        conn
        |> put_req_header("user-agent", "facebookexternalhit/1.1")
        |> get(~p"/j/#{invite.code}")

      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert attribute(document, "meta[property='og:url']", "content") == canonical(invite.code)
      assert LazyHTML.query(document, "[data-crawler-preview]") |> LazyHTML.text() =~ "Pidro"
      assert LazyHTML.query(document, "[data-open-ios]") |> LazyHTML.to_tree() == []
      assert LazyHTML.query(document, "[data-invite-qr]") |> LazyHTML.to_tree() == []
      assert LazyHTML.query(document, "script[src]") |> LazyHTML.to_tree() == []
    end

    test "iOS gets an app action and Android gets an intent with Play fallback", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      ios =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)")
        |> get(~p"/j/#{invite.code}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert attribute(ios, "[data-open-ios]", "href") == "pidro-mobile://j/#{invite.code}"
      assert attribute(ios, "[data-ios-fallback] a", "href") =~ "apps.apple.com"
      assert attribute(ios, "script[src]", "src") =~ "/assets/js/invite.js"

      assert attribute(ios, "[data-store=apple]", "data-deferred-capture") ==
               "http://localhost:4002/j/#{invite.code}/deferred"

      assert attribute(ios, "[data-store=google]", "data-deferred-capture") == nil

      android =
        build_conn()
        |> put_req_header("user-agent", "Mozilla/5.0 (Linux; Android 15)")
        |> get(~p"/j/#{invite.code}")
        |> html_response(200)
        |> LazyHTML.from_document()

      intent = attribute(android, "[data-open-android]", "href")
      assert intent =~ "/j/#{invite.code}#Intent"
      assert intent =~ "package=com.oneapps.pidro"
      assert intent =~ "browser_fallback_url="
      assert attribute(android, "script[src]", "src") =~ "/assets/js/invite.js"

      assert attribute(android, "[data-store=google]", "data-deferred-capture") ==
               "http://localhost:4002/j/#{invite.code}/deferred"

      assert attribute(android, "[data-store=apple]", "data-deferred-capture") == nil
      assert LazyHTML.text(android) =~ "up to 30 minutes"

      assert attribute(android, "[data-invite-privacy]", "href") ==
               "https://www.pidro.online/privacy-policy"
    end

    test "desktop gets both stores and a QR for the canonical URL", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      document =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6)")
        |> get(~p"/j/#{invite.code}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert attribute(document, "[data-store=apple]", "href") =~ "apps.apple.com"
      assert attribute(document, "[data-store=google]", "href") =~ "play.google.com"
      assert attribute(document, "[data-invite-qr]", "src") =~ "data:image/svg+xml;base64,"
      assert attribute(document, "[data-invite-qr]", "data-payload") == canonical(invite.code)
      refute LazyHTML.text(document) =~ "Play in browser"
    end

    test "moved invite points at the successor without redirecting", %{conn: conn} do
      {host, old_room} = host_and_room()
      old = mint!(old_room, host)
      :ok = RoomManager.leave_room(host.id)
      {:ok, new_room} = RoomManager.create_room(host.id, %{name: "Again"})
      new = mint!(new_room, host)
      {:ok, _old} = Invites.supersede(old, new)

      conn = get(conn, ~p"/j/#{old.code}")
      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "new table"
      assert attribute(document, "[data-primary-action]", "href") == canonical(new.code)
      assert attribute(document, "[data-invite-qr]", "data-payload") == canonical(new.code)
      assert attribute(document, "[data-store=apple]", "data-deferred-capture") == nil
      assert get_resp_header(conn, "location") == []
    end

    test "inactive states never offer a join action", %{conn: conn} do
      {host, room} = host_and_room()
      {:ok, invite} = room |> mint!(host) |> Invites.revoke()

      document =
        conn |> get(~p"/j/#{invite.code}") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "no longer active"

      assert LazyHTML.query(document, "[data-open-ios], [data-open-android]")
             |> LazyHTML.to_tree() == []

      assert attribute(document, "[data-store=apple]", "href") =~ "apps.apple.com"
    end

    test "unknown code is a generic branded 404", %{conn: conn} do
      conn = get(conn, ~p"/j/ZZZZZZZZ")
      document = conn |> html_response(404) |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "invite"
      assert attribute(document, "meta[property='og:title']", "content") == "Come play Pidro"
      refute html_response(conn, 404) =~ "ZZZZZZZZ"
      assert attribute(document, "[data-store=apple]", "href") =~ "apps.apple.com"
    end

    test "limits each invite independently from the API preview and other invite codes", %{
      conn: conn
    } do
      with_limit(:invite_page, 1, 60_000)
      with_limit(:invite_preview, 0, 60_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)
      other = mint!(room, host)

      assert conn |> from_ip({10, 7, 0, 1}) |> get(~p"/j/#{invite.code}") |> response(200)

      denied = build_conn() |> from_ip({10, 7, 0, 2}) |> get(~p"/j/#{invite.code}")
      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
      assert [_retry_after] = get_resp_header(denied, "retry-after")

      assert build_conn() |> from_ip({10, 7, 0, 2}) |> get(~p"/j/#{other.code}") |> response(200)
    end
  end

  defp host_and_room(host_attrs \\ %{}) do
    host = AccountsFixtures.user_fixture(host_attrs)
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

  defp canonical(code), do: "http://localhost:4002/j/#{code}"

  defp attribute(document, selector, name) do
    case document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
