defmodule PidroServerWeb.API.BlockControllerTest do
  use PidroServerWeb.ConnCase, async: false

  import PidroServer.AccountsFixtures
  alias PidroServer.Accounts.Token
  alias PidroServer.{Blocks, Friends}
  alias PidroServer.Games.RoomManager

  @user_not_found %{
    "error" => "USER_NOT_FOUND",
    "error_code" => "user_not_found",
    "error_params" => %{}
  }

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  test "GET, PUT and DELETE return the private blocked-list contract", %{conn: conn} do
    a = user_fixture()
    b = user_fixture(%{display_name: "Nora"})
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(b.id, a.id)
    empty = %{"data" => %{"blocked" => []}}
    assert conn |> auth(a) |> get(~p"/api/v1/blocks") |> json_response(200) == empty

    for _ <- 1..2 do
      response = conn |> auth(a) |> put(~p"/api/v1/blocks/#{b.id}") |> json_response(200)
      assert_schema(response, "BlocksResponse")

      assert response == %{
               "data" => %{
                 "blocked" => [
                   %{"user_id" => b.id, "display_name" => "Nora", "avatar_url" => nil}
                 ]
               }
             }

      assert conn |> auth(a) |> get(~p"/api/v1/blocks") |> json_response(200) == response
    end

    assert conn |> auth(b) |> get(~p"/api/v1/blocks") |> json_response(200) == empty

    for {caller, target} <- [{a, b}, {b, a}] do
      assert conn |> auth(caller) |> put(~p"/api/v1/friends/#{target.id}") |> json_response(404) ==
               @user_not_found

      assert conn |> auth(caller) |> get(~p"/api/v1/friends") |> json_response(200) ==
               %{"data" => %{"friends" => [], "added_you" => []}}
    end

    assert conn |> auth(a) |> delete(~p"/api/v1/blocks/#{b.id}") |> json_response(200) == empty

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) ==
             %{"data" => %{"friends" => [], "added_you" => []}}
  end

  test "self is 400, guest callers 403, guest and missing targets 404, missing auth 401", %{
    conn: conn
  } do
    user = user_fixture()
    guest = guest_fixture()

    for {method, path} <- [
          {:get, "/api/v1/blocks"},
          {:put, "/api/v1/blocks/#{user.id}"},
          {:delete, "/api/v1/blocks/#{user.id}"}
        ] do
      assert conn |> auth(guest) |> dispatch(method, path) |> json_response(403) ==
               %{
                 "error" => "ACCOUNT_REQUIRED",
                 "error_code" => "account_required",
                 "error_params" => %{}
               }

      assert conn |> dispatch(method, path) |> json_response(401)
    end

    for method <- [:put, :delete] do
      response =
        conn |> auth(user) |> dispatch(method, "/api/v1/blocks/#{user.id}") |> json_response(400)

      assert response == %{
               "error" => "CANNOT_BLOCK_SELF",
               "error_code" => "cannot_block_self",
               "error_params" => %{}
             }

      assert_schema(response, "BlockError")

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert conn
               |> auth(user)
               |> dispatch(method, "/api/v1/blocks/#{id}")
               |> json_response(404) ==
                 @user_not_found
      end
    end
  end

  test "search and recent exclude both directions before the ten-result cap and restore on unblock",
       %{conn: conn} do
    caller = user_fixture(%{display_name: "Nora Caller"})
    outgoing = user_fixture(%{display_name: "Nora A"})
    incoming = user_fixture(%{display_name: "Nora B"})
    others = for n <- 1..10, do: user_fixture(%{display_name: "Nora C#{n}"})
    {:ok, _} = Blocks.block(caller.id, outgoing.id)
    {:ok, _} = Blocks.block(incoming.id, caller.id)

    %PidroServer.Stats.GameStats{}
    |> PidroServer.Stats.GameStats.changeset(%{
      room_code: "TEST",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      player_ids: Enum.map([caller, outgoing, incoming | others], & &1.id)
    })
    |> PidroServer.Repo.insert!()

    for path <- ["/api/v1/users/search?q=nor", "/api/v1/friends/recent"] do
      response = conn |> auth(caller) |> get(path) |> json_response(200)
      assert MapSet.new(response["data"]["users"], & &1["user_id"]) == MapSet.new(others, & &1.id)

      for other <- [outgoing, incoming] do
        response = conn |> auth(other) |> get(path) |> json_response(200)
        refute Enum.any?(response["data"]["users"], &(&1["user_id"] == caller.id))
      end
    end

    {:ok, _} = Blocks.unblock(caller.id, outgoing.id)

    response =
      conn
      |> auth(outgoing)
      |> get(~p"/api/v1/users/search?q=Nora%20Caller")
      |> json_response(200)

    assert [%{"user_id" => id, "relation" => "none"}] = response["data"]["users"]
    assert id == caller.id
    response = conn |> auth(caller) |> get(~p"/api/v1/friends/recent") |> json_response(200)
    assert hd(response["data"]["users"])["user_id"] == outgoing.id
  end

  test "host-level admission refuses either direction, including automatic seating, but not third-party tables",
       %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    third = user_fixture()
    {:ok, _} = Blocks.block(a.id, b.id)
    {:ok, a_room} = RoomManager.create_room(a.id)
    {:ok, b_room} = RoomManager.create_room(b.id)

    for {room, joining} <- [{a_room, b}, {b_room, a}], position <- [nil, "east", "north_south"] do
      params = if position, do: %{position: position}, else: %{}

      response =
        conn
        |> auth(joining)
        |> post(~p"/api/v1/rooms/#{room.code}/join", params)
        |> json_response(422)

      assert hd(response["errors"])["code"] == "SEAT_TAKEN"
      assert response["error_code"] == "seat_taken"
      assert response["error_params"] == %{}
      assert {:error, {:seat_taken, []}} = RoomManager.claim_seat(room.code, room.id, joining.id)
    end

    assert {:ok, unchanged} = RoomManager.get_room(a_room.code)
    assert unchanged.positions == a_room.positions
    assert {:ok, unchanged} = RoomManager.get_room(b_room.code)
    assert unchanged.positions == b_room.positions
    :ok = RoomManager.close_room(a_room.code)
    :ok = RoomManager.close_room(b_room.code)
    {:ok, room} = RoomManager.create_room(third.id)
    assert {:ok, _, _} = RoomManager.join_room(room.code, a.id)
    assert {:ok, _, _} = RoomManager.join_room(room.code, b.id)
  end

  test "a blocked watcher cannot take a substitute seat, and unblocking restores admission", %{
    conn: conn
  } do
    [host, leaver, south, west, watcher] = for _ <- 1..5, do: user_fixture()
    {:ok, room} = RoomManager.create_room(host.id)
    for user <- [leaver, south, west], do: RoomManager.join_room(room.code, user.id)
    PidroServer.RoomFixtures.ready_room(room.code)

    assert conn
           |> auth(watcher)
           |> post(~p"/api/v1/rooms/#{room.code}/watch")
           |> json_response(200)

    :ok = RoomManager.leave_room(leaver.id)
    {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)
    {:ok, _} = Blocks.block(watcher.id, host.id)

    response =
      conn |> auth(watcher) |> post(~p"/api/v1/rooms/#{room.code}/join") |> json_response(422)

    assert hd(response["errors"])["code"] == "SEAT_TAKEN"
    assert {:error, :seat_taken} = RoomManager.join_as_substitute(room.code, watcher)
    assert RoomManager.is_spectator?(room.code, watcher.id)
    {:ok, unchanged} = RoomManager.get_room(room.code)
    assert unchanged.seats.east.occupant_type == :vacant

    {:ok, _} = Blocks.unblock(watcher.id, host.id)
    assert {:ok, _, :east} = RoomManager.join_as_substitute(room.code, watcher)
  end

  test "the current Quick Game request creates its own bot table, never seats at a blocked host",
       %{conn: conn} do
    host = user_fixture()
    player = user_fixture()
    {:ok, other_room} = RoomManager.create_room(host.id)
    {:ok, _} = Blocks.block(host.id, player.id)

    response =
      conn
      |> auth(player)
      |> post(~p"/api/v1/rooms", %{
        rule_set: "finnish",
        seats: %{seat_2: "ai", seat_3: "ai", seat_4: "ai"}
      })
      |> json_response(201)

    room = response["data"]["room"]
    assert room["code"] != other_room.code
    assert room["host_id"] == player.id
    assert room["config"]["solo"]
    {:ok, unchanged} = RoomManager.get_room(other_room.code)
    assert unchanged.positions == other_room.positions
  end

  test "holds, bound mint/update/regenerate and redemption fail across either block; /me hides old holds",
       %{conn: conn} do
    for direction <- [:outgoing, :incoming] do
      host = user_fixture()
      friend = user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})

      response =
        conn
        |> auth(host)
        |> post(~p"/api/v1/rooms/#{room.code}/invites", %{position: "south"})
        |> json_response(201)

      code = response["data"]["invite"]["code"]
      me = conn |> auth(friend) |> get(~p"/api/v1/auth/me") |> json_response(200)
      assert [%{"code" => room_code}] = me["data"]["seat_invitations"]
      assert room_code == room.code
      {a, b} = if direction == :outgoing, do: {host, friend}, else: {friend, host}
      {:ok, _} = Blocks.block(a.id, b.id)

      me = conn |> auth(friend) |> get(~p"/api/v1/auth/me") |> json_response(200)
      assert me["data"]["seat_invitations"] == []

      response =
        conn
        |> auth(friend)
        |> post(~p"/api/v1/invites/#{code}/redeem", %{})
        |> json_response(409)

      assert hd(response["errors"])["code"] == "SEAT_TAKEN"

      for path <- ["/api/v1/rooms/#{room.code}/invites", "/api/v1/invites/#{code}/regenerate"] do
        assert conn |> auth(host) |> post(path, %{position: "south"}) |> json_response(404) ==
                 @user_not_found
      end

      assert {:ok, %{revoked_at: nil, redeem_count: 0}} = PidroServer.Invites.get_by_code(code)
      assert PidroServer.Invites.count_for_room(room.id) == 1
      assert conn |> auth(host) |> delete(~p"/api/v1/invites/#{code}") |> response(204)

      assert conn
             |> auth(host)
             |> post(~p"/api/v1/rooms/#{room.code}/invites", %{position: "south"})
             |> json_response(404) == @user_not_found

      assert conn
             |> auth(host)
             |> put(~p"/api/v1/rooms/#{room.code}/seats/east/hold", %{user_id: friend.id})
             |> json_response(404) == @user_not_found

      assert conn
             |> auth(host)
             |> delete(~p"/api/v1/rooms/#{room.code}/seats/south/hold")
             |> json_response(200)

      :ok = RoomManager.close_room(room.code)

      assert conn
             |> auth(host)
             |> post(~p"/api/v1/rooms", %{seats: %{seat_3: %{type: "held", user_id: friend.id}}})
             |> json_response(404) == @user_not_found

      assert RoomManager.seat_invitations(friend.id) == []
    end
  end

  test "failed block lookups refuse joins and holds without losing live rooms", %{conn: conn} do
    host = user_fixture()
    player = user_fixture()
    unrelated = user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: player.id}})
    {:ok, other} = RoomManager.create_room(unrelated.id)

    invite =
      conn
      |> auth(host)
      |> post(~p"/api/v1/rooms/#{room.code}/invites", %{position: "south"})
      |> json_response(201)

    code = invite["data"]["invite"]["code"]
    {:ok, room} = RoomManager.get_room(room.code)
    manager = Process.whereis(RoomManager)
    PidroServer.Repo.query!("ALTER TABLE blocks RENAME TO unavailable_blocks")

    response =
      conn |> auth(player) |> post(~p"/api/v1/rooms/#{room.code}/join") |> json_response(503)

    assert hd(response["errors"])["code"] == "PROFILE_UNAVAILABLE"
    assert response["error_code"] == "profile_unavailable"
    assert response["error_params"] == %{}
    assert {:error, :profile_unavailable} = RoomManager.claim_seat(room.code, room.id, player.id)

    assert {:error, :profile_unavailable} =
             RoomManager.set_seat_hold(room.code, host.id, :south, player.id)

    assert_raise Postgrex.Error, fn -> RoomManager.seat_invitations(player.id) end

    me = conn |> auth(player) |> get(~p"/api/v1/auth/me") |> json_response(503)
    assert hd(me["errors"])["code"] == "PROFILE_UNAVAILABLE"

    for path <- ["/api/v1/rooms/#{room.code}/invites", "/api/v1/invites/#{code}/regenerate"] do
      result = conn |> auth(host) |> post(path, %{position: "south"}) |> json_response(503)
      assert hd(result["errors"])["code"] == "PROFILE_UNAVAILABLE"
    end

    assert {:ok, %{revoked_at: nil}} = PidroServer.Invites.get_by_code(code)
    assert PidroServer.Invites.count_for_room(room.id) == 1
    assert Process.whereis(RoomManager) == manager
    assert {:ok, ^room} = RoomManager.get_room(room.code)
    assert {:ok, ^other} = RoomManager.get_room(other.code)
  end

  test "an already-seated invite retry remains idempotent after a block", %{conn: conn} do
    host = user_fixture()
    player = user_fixture()
    {:ok, room} = RoomManager.create_room(host.id)

    invite =
      conn
      |> auth(host)
      |> post(~p"/api/v1/rooms/#{room.code}/invites", %{position: "south"})
      |> json_response(201)

    code = invite["data"]["invite"]["code"]

    first =
      conn |> auth(player) |> post(~p"/api/v1/invites/#{code}/redeem", %{}) |> json_response(200)

    {:ok, _} = Blocks.block(host.id, player.id)

    repeated =
      conn |> auth(player) |> post(~p"/api/v1/invites/#{code}/redeem", %{}) |> json_response(200)

    assert repeated["data"]["position"] == first["data"]["position"]
    assert {:ok, %{redeem_count: 1}} = PidroServer.Invites.get_by_code(code)
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :put, path), do: put(conn, path)
  defp dispatch(conn, :delete, path), do: delete(conn, path)

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
