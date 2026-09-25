defmodule PidroServerWeb.API.RoomControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.{BotManager, BotSupervisor}
  alias PidroServer.Games.{RoomCodes, RoomManager}
  alias PidroServer.Games.Room.Config

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  describe "PID-79 explicit admission" do
    test "REST Join promotes a watcher only after an opened seat is explicitly claimed", %{
      conn: conn
    } do
      [host, leaver, south, west, watcher] =
        Enum.map(1..5, fn _ -> AccountsFixtures.guest_fixture() end)

      {:ok, room} = RoomManager.create_room(host.id)

      for user <- [leaver, south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))

      PidroServer.RoomFixtures.ready_room(room.code)
      auth = put_req_header(conn, "authorization", "Bearer #{Token.generate(watcher)}")
      assert json_response(post(auth, ~p"/api/v1/rooms/#{room.code}/watch"), 200)
      assert json_response(post(auth, ~p"/api/v1/rooms/#{room.code}/watch"), 200)
      assert RoomManager.is_spectator?(room.code, watcher.id)
      :ok = RoomManager.leave_room(leaver.id)
      {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)

      # A stale URL may not remove this account's current watch.
      assert json_response(delete(auth, ~p"/api/v1/rooms/OLD1/unwatch"), 404)
      assert RoomManager.is_spectator?(room.code, watcher.id)
      response = post(auth, ~p"/api/v1/rooms/#{room.code}/join") |> json_response(200)
      assert response["data"]["assigned_position"] == "east"
      assert response["data"]["room"]["positions"]["east"] == watcher.id
      refute watcher.id in response["data"]["room"]["spectator_ids"]
      assert response["data"]["room"]["available_positions"] == []
      refute RoomManager.is_spectator?(room.code, watcher.id)
    end
  end

  describe "leave/2" do
    test "returns 204 and transfers the running seat to a bot", %{conn: conn} do
      [host, leaver, south, west] = Enum.map(1..4, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, room} = RoomManager.create_room(host.id, %{})
      assert {:ok, _, position} = RoomManager.join_room(room.code, leaver.id)

      for user <- [south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))

      PidroServer.RoomFixtures.ready_room(room.code)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(leaver)}")
        |> delete(~p"/api/v1/rooms/#{room.code}/leave")

      assert response(conn, 204)
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].status == :bot_substitute
      assert Process.alive?(updated.seats[position].bot_pid)
    end
  end

  describe "create/2" do
    test "AE3: three ai seats answer 201 with a solo config, three bot seats, and no lobby listing",
         %{conn: conn} do
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
      assert room.config.solo == true

      assert data["room"]["config"] == %{
               "name" => "Solo Table",
               "bot_difficulty" => "basic",
               "solo" => true
             }

      for position <- [:east, :south, :west] do
        assert room.seats[position].occupant_type == :bot
      end

      assert BotManager.list_bots(code) |> Map.keys() |> Enum.sort() == [:east, :south, :west]

      listed =
        build_conn()
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])
        |> Enum.map(& &1["code"])

      refute code in listed
    end

    for {label, legacy_value, extra_params} <- [
          {"omitted", :basic, %{}},
          {"random", :random, %{"bot_difficulty" => "random"}},
          {"basic", :basic, %{"bot_difficulty" => "basic"}},
          {"smart", :smart, %{"bot_difficulty" => "smart"}}
        ] do
      test "an all-AI create with difficulty #{label} uses the one rulebook", %{conn: conn} do
        user = AccountsFixtures.user_fixture()

        params =
          Map.merge(
            %{"seats" => %{"seat_2" => "ai", "seat_3" => "ai", "seat_4" => "ai"}},
            unquote(Macro.escape(extra_params))
          )

        data =
          conn
          |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
          |> post(~p"/api/v1/rooms", params)
          |> json_response(201)
          |> Map.fetch!("data")

        assert {:ok, room} = RoomManager.get_room(data["code"])

        assert room.config == %Config{
                 name: nil,
                 bot_difficulty: unquote(legacy_value),
                 solo: true
               }

        bots = for {_, %{occupant_type: :bot, bot_pid: pid}} <- room.seats, do: pid
        assert length(bots) == 3

        for pid <- bots,
            do:
              assert(
                :sys.get_state(pid).strategy == PidroServer.Games.Bots.Strategies.RulebookStrategy
              )
      end
    end

    test "AE4: a named room with one bot seat reports name, difficulty and not solo", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      data =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{
          "name" => "Friday",
          "seats" => %{"seat_2" => "ai"},
          "bot_difficulty" => "smart"
        })
        |> json_response(201)
        |> Map.fetch!("data")

      expected = %{"name" => "Friday", "bot_difficulty" => "smart", "solo" => false}
      assert data["room"]["config"] == expected
      refute Map.has_key?(data["room"], "metadata")

      # The room show endpoint reports the same object.
      shown = conn |> get(~p"/api/v1/rooms/#{data["code"]}") |> json_response(200)
      assert shown["data"]["room"]["config"] == expected

      assert {:ok, room} = RoomManager.get_room(data["code"])
      assert room.seats.east.occupant_type == :bot
    end

    test "a 61-character name is a 422 naming name, and no room is created", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{"name" => String.duplicate("n", 61)})
        |> json_response(422)

      assert %{
               "errors" => [
                 %{
                   "code" => "name",
                   "title" => "Name",
                   "detail" => "must be at most 60 characters"
                 }
               ]
             } = response

      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
    end

    test "AE1: a create with settings is a 422 naming settings, and the host is mapped to no room",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "name" => "Legacy client",
          "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false}
        })
        |> json_response(422)

      assert %{
               "errors" => [
                 %{"code" => "settings", "title" => "Settings", "detail" => detail} | _
               ]
             } = response

      assert detail == "is not an accepted field"
      assert_no_room_for(user)
    end

    test "AE2: bot_difficulty expert is a 422 naming bot_difficulty, and no bot process was started",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      bots_before = bot_pids()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "seats" => %{"seat_2" => "ai"},
          "bot_difficulty" => "expert"
        })
        |> json_response(422)

      assert %{"errors" => [%{"code" => "bot_difficulty"} | _]} = response
      assert MapSet.subset?(bot_pids(), bots_before)
      assert_no_room_for(user)
    end

    test "AE2: one ai seat and no difficulty answers 201 with a config difficulty of basic", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      data =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"seats" => %{"seat_3" => "ai"}})
        |> data(201)

      assert data["room"]["config"]["bot_difficulty"] == "basic"
      assert data["room"]["config"]["solo"] == false

      # The bot sits where the seat plan says and runs the config's difficulty.
      assert %{south: %{strategy: :basic}} = bots = BotManager.list_bots(data["code"])
      assert Map.keys(bots) == [:south]
    end

    test "a create wrapped in room is a 422 naming room", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"room" => %{"name" => "Wrapped"}})
        |> json_response(422)

      assert %{"errors" => [%{"code" => "room"}]} = response
      assert_no_room_for(user)
    end

    test "a create with seats.seat_5 is a 422 naming seats.seat_5", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"seats" => %{"seat_2" => "ai", "seat_5" => "ai"}})
        |> json_response(422)

      assert %{
               "errors" => [
                 %{
                   "code" => "seats.seat_5",
                   "title" => "Seats seat 5",
                   "detail" => "is not an accepted field"
                 }
               ]
             } = response

      assert_no_room_for(user)
    end

    test "settings and an unknown difficulty together are a 422 with two entries naming both", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "name" => "Legacy client",
          "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false},
          "bot_difficulty" => "expert"
        })
        |> json_response(422)

      assert %{"errors" => [_first, _second] = errors} = response
      assert errors |> Enum.map(& &1["code"]) |> Enum.sort() == ["bot_difficulty", "settings"]
      assert_no_room_for(user)
    end

    test "an unknown query-string parameter beside a valid body answers 201", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms?#{[ref: "campaign"]}", %{"name" => "From a link"})

      assert data(conn, 201)["room"]["config"]["name"] == "From a link"

      # The query-string key reaches the merged params but not the parsed body.
      assert conn.params["ref"] == "campaign"
      assert conn.body_params == %{"name" => "From a link"}
    end

    test "an empty body answers 201 with the default config", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = conn |> as_user(user) |> post(~p"/api/v1/rooms")

      assert data(conn, 201)["room"]["config"] == %{
               "name" => nil,
               "bot_difficulty" => "basic",
               "solo" => false
             }

      assert conn.body_params == %{}
    end

    test "an empty application/json body answers 201 with the default config", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", "")

      assert data(conn, 201)["room"]["config"]["bot_difficulty"] == "basic"
      assert conn.body_params == %{}
    end

    test "a raw JSON object body is parsed from string-keyed body_params", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      body =
        Jason.encode!(%{
          name: "Raw",
          seats: %{seat_2: "ai", seat_4: "open"},
          bot_difficulty: "random"
        })

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", body)

      data = data(conn, 201)

      assert conn.body_params == %{
               "name" => "Raw",
               "seats" => %{"seat_2" => "ai", "seat_4" => "open"},
               "bot_difficulty" => "random"
             }

      assert data["room"]["config"] == %{
               "name" => "Raw",
               "bot_difficulty" => "random",
               "solo" => false
             }

      assert %{east: %{strategy: :random}} = BotManager.list_bots(data["code"])
    end

    test "a non-object JSON body is a 422 naming body, not a 500", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", ~s(["name", "settings"]))

      assert %{"errors" => [%{"code" => "body", "detail" => "must be a JSON object"}]} =
               json_response(conn, 422)

      assert conn.body_params == %{"_json" => ["name", "settings"]}
      assert_no_room_for(user)
    end

    # Plug wraps only non-object JSON as `_json`, so a `_json` key holding an
    # object is one the caller sent. It is an unknown field like any other.
    test "a literal _json wrapper is rejected naming _json and creates no room", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", ~s({"_json": {"name": "Friday"}}))

      assert %{"errors" => [%{"code" => "_json", "detail" => "is not an accepted field"}]} =
               json_response(conn, 422)

      assert conn.body_params == %{"_json" => %{"name" => "Friday"}}
      assert_no_room_for(user)
    end

    test "a rejected create leaves the caller's existing room mapping untouched", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Held"})

      # A held seat is what a valid create would evict (it closes the old room).
      :ok = RoomManager.handle_player_disconnect(room.code, host.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      response =
        conn
        |> as_user(host)
        |> post(~p"/api/v1/rooms", %{"name" => "Next", "settings" => %{"private" => true}})
        |> json_response(422)

      assert %{"errors" => [%{"code" => "settings"}]} = response

      assert {:ok, held} = RoomManager.get_room(room.code)
      assert held.host_id == host.id
      assert held.positions.north == host.id
      assert mapped_room_code(host) == room.code
      refute_receive {:room_closed, _code}, 100
      assert [%{code: code}] = RoomManager.list_rooms(:all)
      assert code == room.code
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
        RoomManager.create_room(solo_host.id, %{name: "Solo", solo: true})

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

  describe "lobby/2" do
    test "excludes solo rooms from every lobby category", %{conn: conn} do
      solo_host = AccountsFixtures.user_fixture()
      public_host = AccountsFixtures.user_fixture()
      viewer = AccountsFixtures.user_fixture()

      {:ok, solo_room} = RoomManager.create_room(solo_host.id, %{name: "Solo", solo: true})
      {:ok, public_room} = RoomManager.create_room(public_host.id, %{name: "Public"})

      lobby =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(viewer)}")
        |> get(~p"/api/v1/lobby")
        |> json_response(200)
        |> Map.fetch!("data")

      codes = lobby |> Map.values() |> List.flatten() |> Enum.map(& &1["code"])
      open_table = Enum.find(lobby["open_tables"], &(&1["code"] == public_room.code))

      assert public_room.code in codes
      refute solo_room.code in codes

      assert open_table["config"] == %{
               "name" => "Public",
               "bot_difficulty" => "basic",
               "solo" => false
             }
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

  describe "seat_bot/2" do
    test "the host seats a bot in an open seat at the room's difficulty", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat", bot_difficulty: :smart})

      assert %{"room" => %{"positions" => %{"east" => bot_id}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> data(200)

      assert bot_id == "bot_#{room.code}_east"
      {:ok, seated} = RoomManager.get_room(room.code)
      assert %{occupant_type: :bot, status: :connected, bot_pid: pid} = seated.seats.east
      assert Process.alive?(pid)
      assert %{east: %{strategy: :smart}} = BotManager.list_bots(room.code)
    end

    test "a slot left behind by a bot that is gone does not block the seat", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _}
      :ets.insert(:pidro_bots, {{room.code, :east}, gone})

      assert %{"room" => %{"positions" => %{"east" => "bot_" <> _}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> data(200)

      assert Process.alive?(BotManager.bot_pid(room.code, :east))
    end

    test "a slot held by a live bot is another request's seat, and that bot is left alone", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      other = spawn(fn -> Process.sleep(:infinity) end)
      :ets.insert(:pidro_bots, {{room.code, :east}, other})

      on_exit(fn ->
        :ets.delete(:pidro_bots, {room.code, :east})
        if Process.alive?(other), do: Process.exit(other, :kill)
      end)

      assert %{"errors" => [%{"code" => "SEAT_NOT_VACANT"}]} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> json_response(422)

      assert Process.alive?(other)
      assert BotManager.bot_pid(room.code, :east) == other
    end

    test "a non-host gets 403, a taken seat 422 SEAT_NOT_VACANT and a playing room 409", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "south"})
               |> json_response(403)

      assert %{"errors" => [%{"code" => "SEAT_NOT_VACANT"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "south"})
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

  # The room code RoomManager tracks the user in, or nil.
  defp mapped_room_code(user), do: :sys.get_state(RoomManager).player_rooms[user.id]

  defp assert_no_room_for(user) do
    assert mapped_room_code(user) == nil
    assert {:error, :not_in_room} = RoomManager.leave_room(user.id)
    refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
  end

  # Every bot process alive under the bot supervisor, whatever room it serves.
  defp bot_pids do
    BotSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> MapSet.new()
  end

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
