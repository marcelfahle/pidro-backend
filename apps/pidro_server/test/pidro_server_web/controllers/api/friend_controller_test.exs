defmodule PidroServerWeb.API.FriendControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import PidroServer.AccountsFixtures
  alias PidroServer.Accounts.Token
  alias PidroServer.Friends

  test "HTTP add, add back, list and remove share the full-list contract", %{conn: conn} do
    a = user_fixture(%{display_name: "Nora"})
    b = user_fixture(%{display_name: "Vera"})
    empty = %{"data" => %{"friends" => [], "added_you" => []}}
    assert conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200) == empty
    assert conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200) == empty
    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["added_you"] == [player(a)]

    response = conn |> auth(b) |> put(~p"/api/v1/friends/#{a.id}") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response == %{"data" => %{"friends" => [player(a)], "added_you" => []}}

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) ==
             %{"data" => %{"friends" => [player(b)], "added_you" => []}}

    assert conn |> auth(b) |> delete(~p"/api/v1/friends/#{a.id}") |> json_response(200) == empty
    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) == empty
  end

  test "guest callers are forbidden on every route; missing auth is unauthorized", %{conn: conn} do
    guest = guest_fixture()
    target = user_fixture()

    for {method, path} <- [
          {:get, "/api/v1/friends"},
          {:get, "/api/v1/friends/recent"},
          {:get, "/api/v1/users/search?q=nor"},
          {:put, "/api/v1/friends/#{target.id}"},
          {:delete, "/api/v1/friends/#{target.id}"}
        ] do
      assert conn |> auth(guest) |> dispatch(method, path) |> json_response(403) ==
               %{"error" => "ACCOUNT_REQUIRED"}

      assert conn |> dispatch(method, path) |> json_response(401)
    end
  end

  test "self and unavailable targets have the contract's status and error code", %{conn: conn} do
    user = user_fixture()
    guest = guest_fixture()

    for method <- [:put, :delete] do
      response =
        conn |> auth(user) |> dispatch(method, "/api/v1/friends/#{user.id}") |> json_response(400)

      assert response == %{"error" => "CANNOT_FRIEND_SELF"}
      assert_schema(response, "FriendError")

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert conn
               |> auth(user)
               |> dispatch(method, "/api/v1/friends/#{id}")
               |> json_response(404) ==
                 %{"error" => "USER_NOT_FOUND"}
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
               "error" => "QUERY_TOO_SHORT"
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
  defp dispatch(conn, :delete, path), do: delete(conn, path)

  defp player(user),
    do: %{
      "user_id" => user.id,
      "display_name" => user.display_name,
      "avatar_url" => nil,
      "presence" => "offline"
    }

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
