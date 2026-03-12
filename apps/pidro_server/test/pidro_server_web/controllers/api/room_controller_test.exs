defmodule PidroServerWeb.API.RoomControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
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

      code = json_response(conn, 201)["data"]["code"]
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

      assert public_room.code in codes
      refute solo_room.code in codes
    end
  end
end
