defmodule PidroServerWeb.Plugs.AuthenticateTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{Auth, Token}
  alias PidroServer.AccountsFixtures
  alias PidroServerWeb.Endpoint
  alias PidroServerWeb.Plugs.Authenticate

  # Same salt as `PidroServer.Accounts.Token`, used to mint legacy and
  # expired tokens the public API cannot produce.
  @signing_salt "pidro_auth_salt"
  @thirty_one_days 86_400 * 31

  setup do
    user = AccountsFixtures.user_fixture()
    %{user: user, token: Token.generate(user)}
  end

  defp call(conn), do: Authenticate.call(conn, Authenticate.init([]))

  defp with_bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp assert_unauthorized(conn) do
    assert conn.halted
    assert conn.status == 401
    assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    refute Map.has_key?(conn.assigns, :current_user)
  end

  describe "a valid token" do
    test "assigns the current user", %{conn: conn, user: user, token: token} do
      conn = conn |> with_bearer(token) |> call()

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "accepts a legacy bare-id token for a version-0 user", %{conn: conn, user: user} do
      legacy = Phoenix.Token.sign(Endpoint, @signing_salt, user.id)
      conn = conn |> with_bearer(legacy) |> call()

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end

  describe "missing or malformed headers" do
    test "no authorization header", %{conn: conn} do
      conn |> call() |> assert_unauthorized()
    end

    test "wrong scheme", %{conn: conn, token: token} do
      conn |> put_req_header("authorization", "Token #{token}") |> call() |> assert_unauthorized()
    end

    test "bearer without a token", %{conn: conn} do
      conn |> put_req_header("authorization", "Bearer") |> call() |> assert_unauthorized()
    end

    test "bearer with extra segments", %{conn: conn, token: token} do
      conn
      |> put_req_header("authorization", "Bearer #{token} extra")
      |> call()
      |> assert_unauthorized()
    end
  end

  describe "bad tokens" do
    test "invalid token", %{conn: conn} do
      conn |> with_bearer("not-a-token") |> call() |> assert_unauthorized()
    end

    test "tampered token", %{conn: conn, token: token} do
      conn |> with_bearer(String.reverse(token)) |> call() |> assert_unauthorized()
    end

    test "expired token", %{conn: conn, user: user} do
      expired =
        Phoenix.Token.sign(Endpoint, @signing_salt, %{id: user.id, v: 0},
          signed_at: System.system_time(:second) - @thirty_one_days
        )

      conn |> with_bearer(expired) |> call() |> assert_unauthorized()
    end

    test "token for a deleted user", %{conn: conn, user: user, token: token} do
      {:ok, _deleted} = Auth.delete_user(user)

      conn |> with_bearer(token) |> call() |> assert_unauthorized()
    end
  end

  describe "revocation" do
    test "a bumped version rejects the old token and accepts a fresh one", %{
      conn: conn,
      user: user,
      token: token
    } do
      assert conn |> with_bearer(token) |> call() |> Map.fetch!(:halted) == false

      {:ok, bumped} = Auth.bump_token_version(user)

      build_conn() |> with_bearer(token) |> call() |> assert_unauthorized()

      fresh = build_conn() |> with_bearer(Token.generate(bumped)) |> call()
      refute fresh.halted
      assert fresh.assigns.current_user.id == user.id
      assert fresh.assigns.current_user.token_version == 1
    end

    test "a bumped version rejects a legacy bare-id token", %{conn: conn, user: user} do
      legacy = Phoenix.Token.sign(Endpoint, @signing_salt, user.id)
      {:ok, _bumped} = Auth.bump_token_version(user)

      conn |> with_bearer(legacy) |> call() |> assert_unauthorized()
    end
  end
end
