defmodule PidroServerWeb.API.InviteControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.{Codes, Event, Invite, Redemption}
  alias PidroServer.Repo

  @code_format ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/
  @day_in_seconds 24 * 60 * 60

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  # ==================== Helpers ====================

  defp authed(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
  end

  # A registered host seated north in a fresh waiting room.
  defp host_and_room(host_attrs \\ %{}) do
    host = AccountsFixtures.user_fixture(host_attrs)
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
    {host, room}
  end

  defp mint!(room, host, attrs \\ %{}) do
    {:ok, invite} =
      Invites.create_invite(
        Map.merge(
          %{room_id: room.id, room_code: room.code, host_user_id: host.id},
          Map.new(attrs)
        )
      )

    invite
  end

  defp seat!(room, user) do
    {:ok, room, _position} = RoomManager.join_room(room.code, user.id)
    room
  end

  # Four positions taken while one seat is held keeps the room `:waiting`, so
  # the invite reads `full` rather than `started`.
  defp fill_with_held_seat!(room) do
    a = AccountsFixtures.user_fixture()
    b = AccountsFixtures.user_fixture()
    c = AccountsFixtures.user_fixture()
    seat!(room, a)
    seat!(room, b)
    :ok = RoomManager.handle_player_disconnect(room.code, a.id)
    seat!(room, c)
    {:ok, room} = RoomManager.get_room(room.code)
    assert room.status == :waiting
    room
  end

  defp expire!(invite) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    invite |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
  end

  defp preview(conn, code), do: conn |> get(~p"/api/v1/invites/#{code}") |> json_response(200)

  defp redeem(conn, user, code, body \\ %{}) do
    conn |> authed(user) |> post(~p"/api/v1/invites/#{code}/redeem", body)
  end

  defp mint(conn, user, room_code, body \\ %{}) do
    conn |> authed(user) |> post(~p"/api/v1/rooms/#{room_code}/invites", body)
  end

  defp events(invite, kind) do
    Repo.all(from(e in Event, where: e.invite_id == ^invite.id and e.kind == ^kind))
  end

  defp redemptions(invite) do
    Repo.all(from(r in Redemption, where: r.invite_id == ^invite.id))
  end

  defp data(conn, status), do: json_response(conn, status)["data"]

  # ==================== Mint ====================

  describe "POST /rooms/:code/invites" do
    test "AE1: the host gets 201 with the R1 fields and a second mint returns the same code with the new hint",
         %{conn: conn} do
      {host, room} = host_and_room()

      response =
        conn
        |> mint(host, room.code, %{"seat_hint" => "partner", "label" => "Anna"})
        |> json_response(201)

      assert %{"invite" => invite} = response["data"]
      assert invite["code"] =~ @code_format
      assert String.ends_with?(invite["url"], invite["code"])
      assert invite["share_text"] =~ Codes.dashed(invite["code"])
      assert invite["seat_hint"] == "partner"
      assert invite["label"] == "Anna"
      assert invite["state"] == "open"
      refute Map.has_key?(invite, "room_code")

      {:ok, expires_at, _offset} = DateTime.from_iso8601(invite["expires_at"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), @day_in_seconds, 30

      {:ok, stored} = Invites.get_by_code(invite["code"])
      assert [%Event{kind: "created"}] = events(stored, "created")

      {:ok, noted} = RoomManager.get_room(room.code)
      assert DateTime.compare(noted.invite_live_until, expires_at) == :eq

      second =
        build_conn()
        |> mint(host, room.code, %{"seat_hint" => "east"})
        |> json_response(200)

      assert second["data"]["invite"]["code"] == invite["code"]
      assert second["data"]["invite"]["seat_hint"] == "east"
      assert second["data"]["invite"]["label"] == "Anna"
      assert Invites.count_for_room(room.id) == 1
    end

    test "a non-host gets 403", %{conn: conn} do
      {_host, room} = host_and_room()
      other = AccountsFixtures.user_fixture()
      seat!(room, other)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn |> mint(other, room.code) |> json_response(403)
    end

    test "a playing room gets 409 ROOM_NOT_WAITING", %{conn: conn} do
      {host, room} = host_and_room()
      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               conn |> mint(host, room.code) |> json_response(409)
    end

    test "an unknown room gets 404", %{conn: conn} do
      {host, _room} = host_and_room()
      assert conn |> mint(host, "ZZZZ") |> json_response(404)
    end

    test "the 21st invite for one room gets 409 INVITE_LIMIT", %{conn: conn} do
      {host, room} = host_and_room()

      for _ <- 1..20 do
        {:ok, _revoked} = room |> mint!(host) |> Invites.revoke()
      end

      assert %{"errors" => [%{"code" => "INVITE_LIMIT"}]} =
               conn |> mint(host, room.code) |> json_response(409)

      assert Invites.count_for_room(room.id) == 20
    end

    test "an invalid seat_hint is 422 on seat_hint", %{conn: conn} do
      {host, room} = host_and_room()

      assert %{"errors" => [%{"code" => "seat_hint"}]} =
               conn |> mint(host, room.code, %{"seat_hint" => "up"}) |> json_response(422)
    end

    test "supersedes with a code the caller did not host gets 403", %{conn: conn} do
      {other_host, other_room} = host_and_room()
      foreign = mint!(other_room, other_host)
      {host, room} = host_and_room()

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> mint(host, room.code, %{"supersedes" => foreign.code})
               |> json_response(403)

      assert Invites.count_for_room(room.id) == 0
    end

    test "AE8: play again forwards the old code while the new table waits", %{conn: conn} do
      {host, old_room} = host_and_room()
      old = mint!(old_room, host, %{seat_hint: "partner", label: "Anna"})
      # The old table is over: the host leaves it (closing it) and opens a new one.
      :ok = RoomManager.leave_room(host.id)
      {:ok, new_room} = RoomManager.create_room(host.id, %{name: "Again"})

      assert %{"invite" => %{"code" => new_code}} =
               conn
               |> mint(host, new_room.code, %{"supersedes" => old.code})
               |> data(201)

      assert %{"invite" => %{"state" => "moved", "next_code" => ^new_code}} =
               preview(build_conn(), old.code)["data"]

      guest = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "INVITE_MOVED", "next_code" => ^new_code}]} =
               build_conn() |> redeem(guest, old.code) |> json_response(410)
    end
  end

  # ==================== Preview ====================

  describe "GET /invites/:code" do
    test "open: the R4 fields without a room code", %{conn: conn} do
      {host, room} = host_and_room(%{display_name: "Marcel"})
      invite = mint!(room, host, %{seat_hint: "partner", label: "Anna"})

      assert %{"invite" => preview} = preview(conn, invite.code)["data"]

      assert preview["code"] == invite.code
      assert preview["state"] == "open"
      assert preview["host"] == "Marcel"
      assert preview["seats_taken"] == 1
      assert preview["seats_total"] == 4
      assert preview["seat_hint"] == "partner"
      assert preview["label"] == "Anna"
      assert preview["expires_at"] == DateTime.to_iso8601(invite.expires_at)
      refute Map.has_key?(preview, "room_code")
      refute Map.has_key?(preview, "next_code")
    end

    test "falls back to the host's username and accepts a dashed lower-case code", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      dashed = invite.code |> Codes.dashed() |> String.downcase()

      assert %{"invite" => %{"host" => host_name, "code" => code}} =
               preview(conn, dashed)["data"]

      assert host_name == host.username
      assert code == invite.code
    end

    test "full", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      fill_with_held_seat!(room)

      assert %{"invite" => %{"state" => "full", "seats_taken" => 4}} =
               preview(conn, invite.code)["data"]
    end

    test "locked", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      {:ok, _room} = RoomManager.set_locked(room.code, host.id, true)

      assert %{"invite" => %{"state" => "locked"}} = preview(conn, invite.code)["data"]
    end

    test "started", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"invite" => %{"state" => "started"}} = preview(conn, invite.code)["data"]
    end

    test "closed, with zero seats taken", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      :ok = RoomManager.close_room(room.code)

      assert %{"invite" => %{"state" => "closed", "seats_taken" => 0}} =
               preview(conn, invite.code)["data"]
    end

    test "expired", %{conn: conn} do
      {host, room} = host_and_room()
      invite = room |> mint!(host) |> expire!()

      assert %{"invite" => %{"state" => "expired"}} = preview(conn, invite.code)["data"]
    end

    test "revoked", %{conn: conn} do
      {host, room} = host_and_room()
      {:ok, invite} = room |> mint!(host) |> Invites.revoke()

      assert %{"invite" => %{"state" => "revoked"}} = preview(conn, invite.code)["data"]
    end

    test "moved carries next_code and outranks closed", %{conn: conn} do
      {host, old_room} = host_and_room()
      old = mint!(old_room, host)
      :ok = RoomManager.leave_room(host.id)
      {:ok, new_room} = RoomManager.create_room(host.id, %{name: "Again"})
      new = mint!(new_room, host)
      {:ok, _old} = Invites.supersede(old, new)

      assert %{"invite" => %{"state" => "moved", "next_code" => next_code}} =
               preview(conn, old.code)["data"]

      assert next_code == new.code
    end

    test "an unknown code is 404", %{conn: conn} do
      assert conn |> get(~p"/api/v1/invites/ZZZZZZZZ") |> json_response(404)
      assert conn |> get(~p"/api/v1/invites/nope") |> json_response(404)
    end

    test "invite_preview at limit 1: the second preview from one address is 429", %{conn: conn} do
      with_limit(:invite_preview, 1, 60_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)

      assert conn
             |> from_ip({10, 6, 0, 1})
             |> get(~p"/api/v1/invites/#{invite.code}")
             |> json_response(200)

      denied =
        build_conn() |> from_ip({10, 6, 0, 1}) |> get(~p"/api/v1/invites/#{invite.code}")

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
      assert [_retry_after] = get_resp_header(denied, "retry-after")

      assert build_conn()
             |> from_ip({10, 6, 0, 2})
             |> get(~p"/api/v1/invites/#{invite.code}")
             |> json_response(200)
    end
  end

  # ==================== Redeem ====================

  describe "POST /invites/:code/redeem" do
    test "AE2: a guest without position takes the hinted seat and the ledger is written", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      invite = mint!(room, host, %{seat_hint: "partner", label: "Anna"})
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})

      response =
        conn
        |> redeem(anna, invite.code, %{"platform" => "ios", "source" => "wa"})
        |> json_response(200)

      assert %{"room" => room_json, "position" => "south", "hint_honored" => true} =
               response["data"]

      assert room_json["code"] == room.code
      assert room_json["locked"] == false
      assert room_json["seats"]["south"]["user_id"] == anna.id
      assert room_json["seats"]["south"]["display_name"] == "Anna"

      assert [%Redemption{position: "south", platform: "ios", source: "wa", user_id: user_id}] =
               redemptions(invite)

      assert user_id == anna.id
      assert [%Event{kind: "seat_claimed", platform: "ios"}] = events(invite, "seat_claimed")
      assert Repo.get!(Invite, invite.id).redeem_count == 1
    end

    test "AE3: when the hinted seat is taken the next open seat is used with hint_honored false",
         %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host, %{seat_hint: "partner"})
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})

      assert %{"position" => "south"} = conn |> redeem(anna, invite.code) |> data(200)

      assert %{"position" => position, "hint_honored" => false} =
               build_conn() |> redeem(ben, invite.code) |> data(200)

      assert position in ["east", "west"]
    end

    test "AE4: an explicit taken seat is 409 SEAT_TAKEN with next_open and no seat changes", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      invite = mint!(room, host, %{seat_hint: "partner"})
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      assert conn |> redeem(anna, invite.code) |> json_response(200)

      assert %{"errors" => [%{"code" => "SEAT_TAKEN", "next_open" => ["east", "west"]}]} =
               build_conn()
               |> redeem(ben, invite.code, %{"position" => "south"})
               |> json_response(409)

      {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.positions == %{north: host.id, east: nil, south: anna.id, west: nil}
      assert redemptions(invite) |> length() == 1
    end

    test "an explicit open seat is honoured", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host, %{seat_hint: "partner"})
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})

      assert %{"position" => "west", "hint_honored" => true} =
               conn |> redeem(ben, invite.code, %{"position" => "west"}) |> data(200)
    end

    test "position 'up' is 422 INVALID_POSITION", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})

      assert %{"errors" => [%{"code" => "INVALID_POSITION"}]} =
               conn |> redeem(ben, invite.code, %{"position" => "up"}) |> json_response(422)

      assert redemptions(invite) == []
    end

    test "full is 409 TABLE_FULL", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      fill_with_held_seat!(room)
      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "TABLE_FULL"}]} =
               conn |> redeem(late, invite.code) |> json_response(409)
    end

    test "AE12: locked is 423 TABLE_LOCKED", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      {:ok, _room} = RoomManager.set_locked(room.code, host.id, true)
      chris = AccountsFixtures.guest_fixture(%{display_name: "Chris"})

      assert %{"errors" => [%{"code" => "TABLE_LOCKED"}]} =
               conn |> redeem(chris, invite.code) |> json_response(423)
    end

    test "started is 410 TABLE_STARTED", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      :ok = RoomManager.update_room_status(room.code, :playing)
      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "TABLE_STARTED"}]} =
               conn |> redeem(late, invite.code) |> json_response(410)
    end

    test "closed is 410 TABLE_CLOSED", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      :ok = RoomManager.close_room(room.code)
      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "TABLE_CLOSED"}]} =
               conn |> redeem(late, invite.code) |> json_response(410)
    end

    test "expired is 410 INVITE_EXPIRED", %{conn: conn} do
      {host, room} = host_and_room()
      invite = room |> mint!(host) |> expire!()
      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "INVITE_EXPIRED"}]} =
               conn |> redeem(late, invite.code) |> json_response(410)
    end

    test "AE7: revoked is 410 INVITE_REVOKED", %{conn: conn} do
      {host, room} = host_and_room()
      {:ok, invite} = room |> mint!(host) |> Invites.revoke()
      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "INVITE_REVOKED"}]} =
               conn |> redeem(late, invite.code) |> json_response(410)
    end

    test "an unknown code is 404", %{conn: conn} do
      late = AccountsFixtures.guest_fixture()
      assert conn |> redeem(late, "ZZZZZZZZ") |> json_response(404)
    end

    test "AE11: a kicked caller is 403 KICKED", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      assert %{"position" => position} = conn |> redeem(ben, invite.code) |> data(200)

      {:ok, _room} =
        RoomManager.kick_player(room.code, host.id, String.to_existing_atom(position))

      assert %{"errors" => [%{"code" => "KICKED"}]} =
               build_conn() |> redeem(ben, invite.code) |> json_response(403)
    end

    test "a caller already seated gets 200 with the same seat and no new redemption", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      invite = mint!(room, host, %{seat_hint: "partner"})
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})

      assert %{"position" => "south"} = conn |> redeem(anna, invite.code) |> data(200)

      assert %{"position" => "south", "hint_honored" => true} =
               build_conn() |> redeem(anna, invite.code) |> data(200)

      assert redemptions(invite) |> length() == 1
      assert events(invite, "seat_claimed") |> length() == 1
      assert Repo.get!(Invite, invite.id).redeem_count == 1
    end

    test "typed and deferred sources are stored, with code_typed emitted once on a typed claim",
         %{
           conn: conn
         } do
      {host, room} = host_and_room()
      typed_invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})

      assert %{"position" => _position} =
               conn
               |> redeem(anna, typed_invite.code, %{"platform" => "ios", "source" => "typed"})
               |> data(200)

      assert [%Redemption{source: "typed"}] = redemptions(typed_invite)
      assert [_event] = events(typed_invite, "code_typed")

      assert build_conn()
             |> redeem(anna, typed_invite.code, %{"platform" => "ios", "source" => "typed"})
             |> json_response(200)

      assert [_event] = events(typed_invite, "code_typed")

      deferred_invite = mint!(room, host)
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})

      assert build_conn()
             |> redeem(ben, deferred_invite.code, %{
               "platform" => "android",
               "source" => "deferred"
             })
             |> json_response(200)

      assert [%Redemption{source: "deferred"}] = redemptions(deferred_invite)
      assert events(deferred_invite, "code_typed") == []
    end

    test "invite_redeem at limit 1: the same user's second redeem is 429", %{conn: conn} do
      with_limit(:invite_redeem, 1, 60_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})

      assert conn |> from_ip({10, 6, 0, 3}) |> redeem(anna, invite.code) |> json_response(200)

      assert build_conn()
             |> from_ip({10, 6, 0, 4})
             |> redeem(anna, invite.code)
             |> json_response(429)
    end
  end

  # ==================== Revoke ====================

  describe "DELETE /invites/:code" do
    test "the host gets 204, the invite reads revoked and the room's invite window is cleared",
         %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      :ok = RoomManager.note_invite(room.code, invite.expires_at)

      conn = conn |> authed(host) |> delete(~p"/api/v1/invites/#{invite.code}")
      assert response(conn, 204)

      assert %{"invite" => %{"state" => "revoked"}} = preview(build_conn(), invite.code)["data"]
      assert [%Event{kind: "revoked"}] = events(invite, "revoked")

      {:ok, cleared} = RoomManager.get_room(room.code)
      assert is_nil(cleared.invite_live_until)
    end

    test "a non-host gets 403 and the invite stays open", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      other = AccountsFixtures.user_fixture()

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> authed(other)
               |> delete(~p"/api/v1/invites/#{invite.code}")
               |> json_response(403)

      assert %{"invite" => %{"state" => "open"}} = preview(build_conn(), invite.code)["data"]
    end
  end

  # ==================== Regenerate ====================

  describe "POST /invites/:code/regenerate" do
    test "AE7: 201 with a new open code, the old code revoked and both events written", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      old = mint!(room, host, %{seat_hint: "partner", label: "Anna"})

      assert %{"invite" => %{"code" => new_code, "state" => "open"} = new} =
               conn
               |> authed(host)
               |> post(~p"/api/v1/invites/#{old.code}/regenerate")
               |> data(201)

      assert new_code != old.code
      assert new["seat_hint"] == "partner"
      assert new["label"] == "Anna"

      assert %{"invite" => %{"state" => "revoked"} = old_preview} =
               preview(build_conn(), old.code)["data"]

      refute Map.has_key?(old_preview, "next_code")

      late = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "INVITE_REVOKED"}]} =
               build_conn() |> redeem(late, old.code) |> json_response(410)

      {:ok, new_invite} = Invites.get_by_code(new_code)
      assert [%Event{kind: "revoked"}] = events(old, "revoked")
      assert [%Event{kind: "created"}] = events(new_invite, "created")

      {:ok, noted} = RoomManager.get_room(room.code)
      assert DateTime.compare(noted.invite_live_until, new_invite.expires_at) == :eq
    end

    test "a non-host gets 403", %{conn: conn} do
      {host, room} = host_and_room()
      old = mint!(room, host)
      other = AccountsFixtures.user_fixture()

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> authed(other)
               |> post(~p"/api/v1/invites/#{old.code}/regenerate")
               |> json_response(403)
    end

    test "invite_mint at limit 1: regenerate shares the mint bucket", %{conn: conn} do
      with_limit(:invite_mint, 1, 60_000)
      {host, room} = host_and_room()
      old = mint!(room, host)

      assert conn
             |> authed(host)
             |> post(~p"/api/v1/invites/#{old.code}/regenerate")
             |> json_response(201)

      assert build_conn() |> mint(host, room.code) |> json_response(429)
    end
  end
end
