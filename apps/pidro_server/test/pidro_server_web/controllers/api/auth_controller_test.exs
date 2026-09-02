defmodule PidroServerWeb.API.AuthControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import ExUnit.CaptureLog

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures

  describe "password reset" do
    test "request returns a generic response and debug reset url for existing users", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture(%{username: "mfahle", email: "mfahle@example.com"})

      conn =
        post(conn, ~p"/api/v1/auth/password-reset", %{
          "identifier" => user.username
        })

      assert %{
               "message" =>
                 "If an account exists for that username or email, a reset link has been sent.",
               "reset_token" => token,
               "reset_url" => reset_url
             } = json_response(conn, 200)["data"]

      assert is_binary(token)
      assert reset_url =~ "/reset-password?token="
    end

    test "request does not reveal missing users", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/password-reset", %{
          "identifier" => "missing"
        })

      assert %{
               "message" =>
                 "If an account exists for that username or email, a reset link has been sent."
             } = json_response(conn, 200)["data"]

      refute Map.has_key?(json_response(conn, 200)["data"], "reset_token")
    end

    test "confirm resets password and signs user in", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{username: "mfahle"})
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert %{"token" => auth_token, "user" => %{"username" => "mfahle"}} =
               json_response(conn, 200)["data"]

      assert is_binary(auth_token)
      assert {:ok, _user} = Auth.authenticate_user("mfahle", "new password!")
      assert {:error, :invalid_credentials} = Auth.authenticate_user("mfahle", "hello world!")
    end

    test "confirm rejects reused tokens", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert json_response(conn, 200)

      conn =
        post(build_conn(), ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "another password!"
        })

      assert %{"errors" => [%{"code" => "INVALID_OR_EXPIRED_PASSWORD_RESET_TOKEN"}]} =
               json_response(conn, 422)
    end
  end

  describe "rate limiting" do
    # Shares the node-wide Hammer ETS table (reset by RateLimitCase before each
    # test); the module is already async: false.
    test "AE1: the second login from one IP inside the window is 429 with Retry-After", %{
      conn: conn
    } do
      with_limit(:login, 1, 60_000)
      user = AccountsFixtures.user_fixture()
      params = %{"username" => user.username, "password" => "hello world!"}

      assert conn
             |> from_ip({10, 1, 0, 1})
             |> post(~p"/api/v1/auth/login", params)
             |> json_response(200)

      denied = build_conn() |> from_ip({10, 1, 0, 1}) |> post(~p"/api/v1/auth/login", params)

      assert %{"errors" => [%{"code" => "RATE_LIMITED", "title" => "Too Many Requests"}]} =
               json_response(denied, 429)

      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert String.to_integer(retry_after) in 1..60
    end

    test "AE12: the identifier bucket is shared across case, whitespace and IPs for an unknown account",
         %{conn: conn} do
      with_limit(:password_reset_identifier, 1, 3_600_000)

      assert conn
             |> from_ip({10, 1, 0, 2})
             |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "Anna@x.test"})
             |> json_response(200)

      denied =
        build_conn()
        |> from_ip({10, 1, 0, 3})
        |> post(~p"/api/v1/auth/password-reset", %{"identifier" => " anna@x.test "})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end

    test "AE12: the identifier bucket is shared the same way for an existing account", %{
      conn: conn
    } do
      with_limit(:password_reset_identifier, 1, 3_600_000)
      AccountsFixtures.user_fixture(%{username: "anna", email: "anna@x.test"})

      assert conn
             |> from_ip({10, 1, 0, 4})
             |> post(~p"/api/v1/auth/password-reset", %{"identifier" => "Anna@x.test"})
             |> json_response(200)

      denied =
        build_conn()
        |> from_ip({10, 1, 0, 5})
        |> post(~p"/api/v1/auth/password-reset", %{"identifier" => " anna@x.test "})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end

    test "a missing or non-binary identifier skips the identifier bucket, never 500s and still counts against the IP bucket",
         %{conn: conn} do
      with_limit(:password_reset, 1, 900_000)
      with_limit(:password_reset_identifier, 1, 3_600_000)

      log =
        capture_log(fn ->
          missing = conn |> from_ip({10, 1, 0, 6}) |> post(~p"/api/v1/auth/password-reset", %{})
          assert missing.status in [200, 422]

          listy =
            build_conn()
            |> from_ip({10, 1, 0, 7})
            |> post(~p"/api/v1/auth/password-reset", %{"identifier" => ["a"]})

          assert listy.status in [200, 422]
        end)

      refute log =~ "[error]"

      # The IP bucket counted the first request although the identifier bucket was skipped.
      denied =
        build_conn() |> from_ip({10, 1, 0, 6}) |> post(~p"/api/v1/auth/password-reset", %{})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end

    test "password-reset/confirm is limited per IP", %{conn: conn} do
      with_limit(:password_reset_confirm, 1, 900_000)
      params = %{"token" => "not-a-real-token", "password" => "new password!"}

      assert conn
             |> from_ip({10, 1, 0, 8})
             |> post(~p"/api/v1/auth/password-reset/confirm", params)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 1, 0, 8})
             |> post(~p"/api/v1/auth/password-reset/confirm", params)
             |> json_response(429)
    end

    test "register is limited per IP", %{conn: conn} do
      with_limit(:register, 1, 600_000)
      params = %{"user" => %{"username" => "rl", "email" => "bad", "password" => "x"}}

      assert conn
             |> from_ip({10, 1, 0, 9})
             |> post(~p"/api/v1/auth/register", params)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 1, 0, 9})
             |> post(~p"/api/v1/auth/register", params)
             |> json_response(429)
    end
  end
end
