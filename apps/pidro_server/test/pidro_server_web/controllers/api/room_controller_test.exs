defmodule PidroServerWeb.API.RoomControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
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

    test "GET /rooms and POST /rooms/:code/join are never limited, even at limit 0", %{conn: conn} do
      with_all_limits(0)
      host = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert conn |> from_ip({10, 2, 0, 5}) |> get(~p"/api/v1/rooms") |> json_response(200)

      assert build_conn()
             |> from_ip({10, 2, 0, 5})
             |> get(~p"/api/v1/rooms")
             |> json_response(200)

      joined =
        build_conn()
        |> from_ip({10, 2, 0, 5})
        |> put_req_header("authorization", "Bearer #{Token.generate(joiner)}")
        |> post(~p"/api/v1/rooms/#{room.code}/join", %{})

      assert joined.status in 200..299
    end
  end

  defp create_room_as(conn, user, ip) do
    conn
    |> from_ip(ip)
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> post(~p"/api/v1/rooms", %{"name" => "Limited"})
  end
end
