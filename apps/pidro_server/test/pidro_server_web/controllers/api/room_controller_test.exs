defmodule PidroServerWeb.API.RoomControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.{RoomCodes, RoomManager}

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  describe "leave/2" do
    test "returns 204 and transfers the running seat to a bot", %{conn: conn} do
      [host, leaver, south, west] = Enum.map(1..4, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, room} = RoomManager.create_room(host.id, %{})
      for user <- [leaver, south, west], do: RoomManager.join_room(room.code, user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(leaver)}")
        |> delete(~p"/api/v1/rooms/#{room.code}/leave")

      assert response(conn, 204)
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats.east.status == :bot_substitute
      assert Process.alive?(updated.seats.east.bot_pid)
    end
  end

  describe "create/2" do
    test "marks all-AI tables as single-player rooms", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{
          "name" => "Solo Table",
          "seats" => %{
            "seat_2" => "ai",
            "seat_3" => "ai",
            "seat_4" => "ai"
          },
          "bot_difficulty" => "basic"
        })

      data = json_response(conn, 201)["data"]
      code = data["code"]

      assert data["room"]["seats"]["north"]["username"] == user.username

      assert data["room"]["seats"]
             |> Map.values()
             |> Enum.filter(&(&1["occupant_type"] == "bot"))
             |> Enum.all?(&(&1["username"] == "Bot"))

      assert {:ok, room} = RoomManager.get_room(code)
      assert room.metadata.single_player == true
    end

    test "returns 503 ROOM_CODE_EXHAUSTED when no free room code can be allocated", %{
      conn: conn
    } do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      # Every draw yields the code already held by another room
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      holder = AccountsFixtures.user_fixture()
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room(holder.id, %{name: "Held"})

      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{"name" => "Crowded"})

      assert %{"errors" => [%{"code" => "ROOM_CODE_EXHAUSTED"}]} = json_response(conn, 503)

      assert {:ok, held} = RoomManager.get_room("ZZZZ")
      assert held.host_id == holder.id
    end
  end

  describe "index/2" do
    test "excludes single-player rooms from the public lobby list", %{conn: conn} do
      solo_host = AccountsFixtures.user_fixture()
      public_host = AccountsFixtures.user_fixture()

      {:ok, solo_room} =
        RoomManager.create_room(solo_host.id, %{name: "Solo", single_player: true})

      {:ok, public_room} = RoomManager.create_room(public_host.id, %{name: "Public"})

      rooms =
        conn
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])

      codes = Enum.map(rooms, & &1["code"])
      serialized_public_room = Enum.find(rooms, &(&1["code"] == public_room.code))

      assert public_room.code in codes
      refute solo_room.code in codes
      assert serialized_public_room["seats"]["north"]["username"] == public_host.username
    end
  end

  describe "rate limiting" do
    # Shares the node-wide Hammer ETS table (reset by RateLimitCase before each
    # test); the module is already async: false.
    test "room_create at limit 1: the same user's second POST /rooms is 429, another user is allowed",
         %{conn: conn} do
      with_limit(:room_create, 1, 60_000)
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()

      assert conn |> create_room_as(user, {10, 2, 0, 1}) |> json_response(201)

      # A different address does not help: the bucket is the user id.
      denied = build_conn() |> create_room_as(user, {10, 2, 0, 2})
      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
      assert [_retry_after] = get_resp_header(denied, "retry-after")

      assert build_conn() |> create_room_as(other, {10, 2, 0, 1}) |> json_response(201)
    end

    test "room_lookup at limit 1: the second GET /rooms/:code from one IP is 429 whether or not the code exists",
         %{conn: conn} do
      with_limit(:room_lookup, 1, 60_000)
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Lookup"})

      assert conn
             |> from_ip({10, 2, 0, 3})
             |> get(~p"/api/v1/rooms/#{room.code}")
             |> json_response(200)

      assert build_conn()
             |> from_ip({10, 2, 0, 3})
             |> get(~p"/api/v1/rooms/ZZZZ")
             |> json_response(429)

      assert build_conn()
             |> from_ip({10, 2, 0, 4})
             |> get(~p"/api/v1/rooms/ZZZZ")
             |> json_response(404)

      assert build_conn()
             |> from_ip({10, 2, 0, 4})
             |> get(~p"/api/v1/rooms/#{room.code}")
             |> json_response(429)
    end

    test "GET /rooms is never limited, even at limit 0", %{conn: conn} do
      with_all_limits(0)
      host = AccountsFixtures.user_fixture()
      {:ok, _room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert conn |> from_ip({10, 2, 0, 5}) |> get(~p"/api/v1/rooms") |> json_response(200)

      assert build_conn()
             |> from_ip({10, 2, 0, 5})
             |> get(~p"/api/v1/rooms")
             |> json_response(200)
    end

    test "room_join at limit 1: the same user's second POST /rooms/:code/join is 429 (R28)", %{
      conn: conn
    } do
      with_limit(:room_join, 1, 60_000)
      host = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert conn
             |> from_ip({10, 2, 0, 6})
             |> as_user(joiner)
             |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
             |> json_response(200)

      # A different address does not help: the bucket is the user id.
      denied =
        build_conn()
        |> from_ip({10, 2, 0, 7})
        |> as_user(joiner)
        |> post(~p"/api/v1/rooms/#{room.code}/join", %{})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end
  end

  describe "index/2 with invites" do
    test "R24: a room with a live invite stays in the public list", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
      {:ok, invite} = create_invite(room, host)
      :ok = RoomManager.note_invite(room.code, invite.expires_at)

      rooms =
        conn
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])

      assert listed = Enum.find(rooms, &(&1["code"] == room.code))
      assert listed["locked"] == false
    end
  end

  describe "seat/2" do
    test "the host moves a player to a vacant seat and the room carries locked and display names",
         %{conn: conn} do
      host = AccountsFixtures.user_fixture(%{display_name: "Marcel"})
      guest = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, guest.id)

      response =
        conn
        |> as_user(host)
        |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
          "position" => "west",
          "user_id" => guest.id
        })
        |> json_response(200)

      assert %{"room" => room_json} = response["data"]
      assert room_json["locked"] == false
      assert room_json["positions"]["west"] == guest.id
      assert room_json["positions"]["east"] == nil
      assert room_json["seats"]["west"]["display_name"] == "Ben"
      assert room_json["seats"]["west"]["username"] == guest.username
      assert room_json["seats"]["north"]["display_name"] == "Marcel"
    end

    test "a seated non-host may move only themselves", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      mover = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, mover.id)
      {:ok, _room, :south} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(mover)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
                 "position" => "west",
                 "user_id" => other.id
               })
               |> json_response(403)

      assert %{"room" => %{"positions" => %{"west" => west}}} =
               build_conn()
               |> as_user(mover)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{"position" => "west"})
               |> data(200)

      assert west == mover.id
    end

    test "a taken target seat is 422 SEAT_TAKEN and a bad position is 422 INVALID_POSITION", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      guest = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, guest.id)

      assert %{"errors" => [%{"code" => "SEAT_TAKEN"}]} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
                 "position" => "east",
                 "user_id" => host.id
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "INVALID_POSITION"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{"position" => "up"})
               |> json_response(422)
    end
  end

  describe "lock/2" do
    test "AE12: a locked table refuses joins with 423 until the host unlocks it", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      chris = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Locked"})

      assert %{"room" => %{"locked" => true}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> data(200)

      assert %{"errors" => [%{"code" => "TABLE_LOCKED"}]} =
               build_conn()
               |> as_user(chris)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
               |> json_response(423)

      assert %{"room" => %{"locked" => false}} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => false})
               |> data(200)

      assert build_conn()
             |> as_user(chris)
             |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
             |> json_response(200)
    end

    test "a non-host gets 403, a playing room 409 ROOM_NOT_WAITING and a non-boolean 422", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Locked"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> json_response(403)

      assert build_conn()
             |> as_user(host)
             |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => "yes"})
             |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> json_response(409)
    end
  end

  describe "kick/2" do
    test "AE11: the host kicks a seat, it is vacant, and the kicked user cannot join again", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      ben = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Kick"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, ben.id)

      assert %{"room" => %{"positions" => %{"east" => nil}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "east"})
               |> data(200)

      assert %{"errors" => [%{"code" => "KICKED"}]} =
               build_conn()
               |> as_user(ben)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
               |> json_response(403)
    end

    test "a non-host gets 403, the host's own seat 422 SEAT_NOT_KICKABLE and a playing room 409",
         %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Kick"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "north"})
               |> json_response(403)

      assert %{"errors" => [%{"code" => "SEAT_NOT_KICKABLE"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "north"})
               |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "east"})
               |> json_response(409)
    end
  end

  describe "join/2 contract" do
    test "a taken explicit seat still answers 422 SEAT_TAKEN", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Join"})

      assert %{"errors" => [%{"code" => "SEAT_TAKEN"}]} =
               conn
               |> as_user(joiner)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{"position" => "north"})
               |> json_response(422)
    end
  end

  defp as_user(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
  end

  defp data(conn, status), do: json_response(conn, status)["data"]

  defp create_invite(room, host) do
    PidroServer.Invites.create_invite(%{
      room_id: room.id,
      room_code: room.code,
      host_user_id: host.id
    })
  end

  defp create_room_as(conn, user, ip) do
    conn
    |> from_ip(ip)
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> post(~p"/api/v1/rooms", %{"name" => "Limited"})
  end
end
