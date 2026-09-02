defmodule PidroServerWeb.API.AuthControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{Auth, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  describe "register" do
    test "ignores guest in the request body", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_guest",
            "email" => "register_guest@example.com",
            "password" => "password123",
            "guest" => true
          }
        })

      assert %{"user" => %{"username" => "register_guest", "guest" => false}} =
               json_response(conn, 201)["data"]

      refute Auth.get_user_by_username("register_guest").guest
    end

    test "stores a trimmed display_name", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_named",
            "email" => "register_named@example.com",
            "password" => "password123",
            "display_name" => "  Anna  "
          }
        })

      assert %{"user" => %{"display_name" => "Anna"}} = json_response(conn, 201)["data"]
    end

    test "rejects a 41-character display_name with a validation error", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_long",
            "email" => "register_long@example.com",
            "password" => "password123",
            "display_name" => String.duplicate("a", 41)
          }
        })

      assert %{"errors" => [%{"code" => "display_name", "detail" => detail}]} =
               json_response(conn, 422)

      assert detail =~ "at most 40"
    end
  end

  describe "login" do
    test "returns invalid credentials for a guest without a password", %{conn: conn} do
      {:ok, guest} =
        %User{}
        |> User.guest_changeset(%{username: "guest_login"})
        |> Repo.insert()

      assert is_nil(guest.password_hash)

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "username" => "guest_login",
          "password" => "anything"
        })

      assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} = json_response(conn, 401)
    end
  end

  describe "me" do
    test "includes a nil display_name for existing users", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> get(~p"/api/v1/auth/me")

      assert %{"user" => %{"id" => id, "display_name" => nil}} = json_response(conn, 200)["data"]
      assert id == user.id
    end
  end

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
end
