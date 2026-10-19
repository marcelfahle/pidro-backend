defmodule PidroServerWeb.API.FriendControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import PidroServer.AccountsFixtures
  alias PidroServer.Accounts.Token
  alias PidroServer.Friends
  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.Presence

  test "Classic count includes only distinct outgoing friends who have not claimed", %{conn: conn} do
    a = user_fixture()
    b = user_fixture()

    assert {:ok, %{ticket: ticket}} =
             PidroServer.Accounts.ClassicClaims.issue_ticket(%{
               classic_user_id: 30_001,
               method: :password,
               user_id: a.id,
               legacy_data: %{
                 friend_ids: [30_002, 30_002, 30_003],
                 friended_by_ids: [30_004],
                 blocked_ids: [30_005]
               }
             })

    assert {:ok, _} = PidroServer.Accounts.ClassicClaims.redeem(ticket, a, %{})
    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["classic"] == %{"not_here" => 2}

    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    refute Map.has_key?(response["data"], "classic")

    assert {:ok, %{ticket: ticket}} =
             PidroServer.Accounts.ClassicClaims.issue_ticket(%{
               classic_user_id: 30_002,
               method: :password,
               user_id: b.id,
               legacy_data: %{}
             })

    assert {:ok, _} = PidroServer.Accounts.ClassicClaims.redeem(ticket, b, %{})
    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert response["data"]["classic"] == %{"not_here" => 1}
    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["classic"] == %{"not_here" => 0}
    assert response["data"]["added_you"] == [player(a)]
  end

  test "HTTP add, add back, list and remove share the full-list contract", %{conn: conn} do
    a = user_fixture(%{display_name: "Nora"})
    b = user_fixture(%{display_name: "Vera"})

    empty = %{
      "data" => %{"friends" => [], "added_you" => [], "requested" => [], "requests_waiting" => 0}
    }

    response = conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200)
    assert_schema(response, "FriendsResponse")

    assert %{"friends" => [], "added_you" => [], "requested" => [sent], "requests_waiting" => 0} =
             response["data"]

    assert Map.delete(sent, "requested_at") == player(b)
    assert {:ok, _, _} = DateTime.from_iso8601(sent["requested_at"])
    assert conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200) == response
    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["added_you"] == [player(a)]
    assert response["data"]["requests_waiting"] == 1

    response = conn |> auth(b) |> put(~p"/api/v1/friends/#{a.id}") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response == put_in(empty, ["data", "friends"], [player(a)])

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) ==
             put_in(empty, ["data", "friends"], [player(b)])

    assert conn |> auth(b) |> delete(~p"/api/v1/friends/#{a.id}") |> json_response(200) == empty
    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) == empty
  end

  test "table company is an extra field; presence stays in the old three-value enum",
       %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(b.id, a.id)
    {:ok, room} = RoomManager.create_room(b.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Presence.track(self(), "game:" <> room.code, b.id, %{})

    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert [entry] = response["data"]["friends"]
    assert entry["table_company"] == "bots"
    # An old build ignores the new key and sees exactly the entry it always decoded.
    assert Map.delete(entry, "table_company") == %{player(b) | "presence" => "at_table"}
  end

  test "HTTP ignore hides a request from the recipient only, and un-ignore restores it",
       %{conn: conn} do
    a = user_fixture(%{display_name: "Nora"})
    b = user_fixture(%{display_name: "Vera"})
    sent = conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200)

    hidden = %{
      "data" => %{"friends" => [], "added_you" => [], "requested" => [], "requests_waiting" => 0}
    }

    for _ <- 1..2 do
      response = conn |> auth(b) |> post(~p"/api/v1/friends/#{a.id}/ignore") |> json_response(200)
      assert_schema(response, "FriendsResponse")
      assert response == hidden
    end

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) == sent

    response = conn |> auth(b) |> delete(~p"/api/v1/friends/#{a.id}/ignore") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["added_you"] == [player(a)]
    assert response["data"]["requests_waiting"] == 1
  end

  test "guest callers are forbidden on every route; missing auth is unauthorized", %{conn: conn} do
    guest = guest_fixture()
    target = user_fixture()

    for {method, path} <- [
          {:get, "/api/v1/friends"},
          {:get, "/api/v1/friends/recent"},
          {:get, "/api/v1/users/search?q=nor"},
          {:put, "/api/v1/friends/#{target.id}"},
          {:delete, "/api/v1/friends/#{target.id}"},
          {:post, "/api/v1/friends/#{target.id}/ignore"},
          {:delete, "/api/v1/friends/#{target.id}/ignore"}
        ] do
      assert conn |> auth(guest) |> dispatch(method, path) |> json_response(403) ==
               %{
                 "error" => "ACCOUNT_REQUIRED",
                 "error_code" => "account_required",
                 "error_params" => %{}
               }

      assert conn |> dispatch(method, path) |> json_response(401) == %{
               "errors" => %{"detail" => "Unauthorized"},
               "error_code" => "unauthorized",
               "error_params" => %{}
             }
    end
  end

  test "self and unavailable targets have the contract's status and error code", %{conn: conn} do
    user = user_fixture()
    guest = guest_fixture()

    for {method, suffix} <- [put: "", delete: "", post: "/ignore", delete: "/ignore"] do
      response =
        conn
        |> auth(user)
        |> dispatch(method, "/api/v1/friends/#{user.id}#{suffix}")
        |> json_response(400)

      assert response == %{
               "error" => "CANNOT_FRIEND_SELF",
               "error_code" => "cannot_friend_self",
               "error_params" => %{}
             }

      assert_schema(response, "FriendError")

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert conn
               |> auth(user)
               |> dispatch(method, "/api/v1/friends/#{id}#{suffix}")
               |> json_response(404) ==
                 %{
                   "error" => "USER_NOT_FOUND",
                   "error_code" => "user_not_found",
                   "error_params" => %{}
                 }
      end
    end
  end

  test "search and recent expose discovery entries, and short queries fail", %{conn: conn} do
    user = user_fixture()
    nora = user_fixture(%{display_name: "Nora"})
    {:ok, _} = Friends.add(nora.id, user.id)
    response = conn |> auth(user) |> get(~p"/api/v1/users/search?q=nor") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")
    assert response == %{"data" => %{"users" => [Map.put(player(nora), "relation", "added_you")]}}

    for path <- [
          "/api/v1/users/search",
          "/api/v1/users/search?q=no",
          "/api/v1/users/search?q[]=nor"
        ] do
      assert conn |> auth(user) |> get(path) |> json_response(400) == %{
               "error" => "QUERY_TOO_SHORT",
               "error_code" => "query_too_short",
               "error_params" => %{}
             }
    end

    response = conn |> auth(user) |> get(~p"/api/v1/friends/recent") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")
    assert response == %{"data" => %{"users" => []}}

    %PidroServer.Stats.GameStats{}
    |> PidroServer.Stats.GameStats.changeset(%{
      room_code: "TEST",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      player_ids: [user.id, nora.id]
    })
    |> PidroServer.Repo.insert!()

    response = conn |> auth(user) |> get(~p"/api/v1/friends/recent") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")
    assert response == %{"data" => %{"users" => [Map.put(player(nora), "relation", "added_you")]}}
  end

  test "search and add limits are independent per user and preserve existing 429s", %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    with_limit(:user_search, 1, 60_000)
    with_limit(:friend_add, 1, 3_600_000)

    for {method, path} <- [
          {:get, "/api/v1/users/search?q=nor"},
          {:put, "/api/v1/friends/#{b.id}"}
        ] do
      assert conn |> auth(a) |> dispatch(method, path) |> json_response(200)
      denied = conn |> auth(a) |> dispatch(method, path)

      assert [%{"code" => "RATE_LIMITED"}] =
               json_response(denied, 429)["errors"] |> Enum.map(&Map.take(&1, ["code"]))

      assert [_] = get_resp_header(denied, "retry-after")
    end

    assert conn |> auth(b) |> get(~p"/api/v1/users/search?q=nor") |> json_response(200)
    assert conn |> auth(b) |> put(~p"/api/v1/friends/#{a.id}") |> json_response(200)
    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert conn |> auth(a) |> delete(~p"/api/v1/friends/#{b.id}") |> json_response(200)
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :put, path), do: put(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path)
  defp dispatch(conn, :delete, path), do: delete(conn, path)

  defp player(user),
    do: %{
      "user_id" => user.id,
      "display_name" => user.display_name || user.username,
      "avatar_url" => nil,
      "presence" => "offline"
    }

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
