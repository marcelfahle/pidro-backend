defmodule PidroServerWeb.API.AuthControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{Auth, Token, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.Event
  alias PidroServer.Repo

  defmodule ProviderVerifier do
    @behaviour PidroServer.Accounts.ProviderVerifier

    @impl true
    def verify(:apple, "apple-token"), do: {:ok, "apple-sub"}
    def verify(:facebook, "facebook-token"), do: {:ok, "facebook-id"}
    def verify(_provider, _token), do: {:error, :invalid_credentials}
  end

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

    test "rejects a 21-character display_name with a validation error", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "register_long",
            "email" => "register_long@example.com",
            "password" => "password123",
            "display_name" => String.duplicate("a", 21)
          }
        })

      assert %{"errors" => [%{"code" => "display_name", "detail" => detail}]} =
               json_response(conn, 422)

      assert detail =~ "at most 20"
    end

    test "a reserved public name has the machine-readable reservation code", %{conn: conn} do
      assert {:ok, _} =
               PidroServer.Accounts.ClassicNameReservations.import([
                 %{id: 701, username: "Classic Hero"}
               ])

      response =
        conn
        |> post(~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "newcomer",
            "display_name" => " classic   hero ",
            "email" => "reserved@example.com",
            "password" => "password123"
          }
        })
        |> json_response(422)

      assert %{
               "code" => "classic_name_reserved",
               "title" => "Display name",
               "detail" =>
                 "This name belongs to a Classic player. Claim your Classic profile or choose another name."
             } in response["errors"]
    end

    test "reservation metadata only overrides its own error code", %{conn: conn} do
      long_name = "Classic Hero Too Long"

      assert {:ok, _} =
               PidroServer.Accounts.ClassicNameReservations.import([
                 %{id: 702, username: long_name}
               ])

      errors =
        conn
        |> post(~p"/api/v1/auth/register", %{
          "user" => %{
            "username" => "another_newcomer",
            "display_name" => long_name,
            "email" => "mixed-errors@example.com",
            "password" => "password123"
          }
        })
        |> json_response(422)
        |> Map.fetch!("errors")

      assert Enum.any?(errors, &match?(%{"code" => "classic_name_reserved"}, &1))
      assert Enum.any?(errors, &match?(%{"code" => "display_name"}, &1))
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

  describe "provider login" do
    setup do
      previous = Application.get_env(:pidro_server, :provider_verifier)
      Application.put_env(:pidro_server, :provider_verifier, ProviderVerifier)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:pidro_server, :provider_verifier, previous),
          else: Application.delete_env(:pidro_server, :provider_verifier)
      end)
    end

    test "Apple and Facebook return the linked account, never an email match", %{conn: conn} do
      apple =
        AccountsFixtures.user_fixture()
        |> Ecto.Changeset.change(apple_sub: "apple-sub")
        |> Repo.update!()

      facebook =
        AccountsFixtures.user_fixture()
        |> Ecto.Changeset.change(facebook_id: "facebook-id")
        |> Repo.update!()

      assert %{"user" => %{"id" => apple_id}, "token" => _token} =
               conn
               |> post(~p"/api/v1/auth/apple", %{identity_token: "apple-token"})
               |> json_response(200)
               |> Map.fetch!("data")

      assert apple_id == apple.id

      assert %{"user" => %{"id" => facebook_id}, "token" => _token} =
               build_conn()
               |> post(~p"/api/v1/auth/facebook", %{access_token: "facebook-token"})
               |> json_response(200)
               |> Map.fetch!("data")

      assert facebook_id == facebook.id

      assert %{"errors" => [%{"code" => "INVALID_CREDENTIALS"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/apple", %{identity_token: "wrong"})
               |> json_response(401)
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

  describe "token revocation" do
    test "a bumped version yields 401 for the old token and 200 for a fresh one", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      old_token = Token.generate(user)

      assert json_response(me(conn, old_token), 200)

      {:ok, bumped} = Auth.bump_token_version(user)

      assert %{"errors" => %{"detail" => "Unauthorized"}} =
               json_response(me(build_conn(), old_token), 401)

      assert %{"user" => %{"id" => id}} =
               json_response(me(build_conn(), Token.generate(bumped)), 200)["data"]

      assert id == user.id
    end

    test "a completed password reset revokes the old token and the returned token works", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture(%{username: "reset_revokes"})
      old_token = Token.generate(user)
      assert json_response(me(conn, old_token), 200)

      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      conn =
        post(build_conn(), ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => reset_token,
          "password" => "new password!"
        })

      assert %{"token" => new_token, "user" => %{"username" => "reset_revokes"}} =
               json_response(conn, 200)["data"]

      assert json_response(me(build_conn(), old_token), 401)

      assert %{"user" => %{"id" => id}} =
               json_response(me(build_conn(), new_token), 200)["data"]

      assert id == user.id
      assert {:ok, %{v: 1}} = Token.verify(new_token)
    end
  end

  defp me(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(~p"/api/v1/auth/me")
  end

  defp data(conn, status), do: json_response(conn, status)["data"]

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

  describe "login with email" do
    test "R14: the username field accepts the account's email address", %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{email: "marcel@example.com"})

      conn =
        post(conn, ~p"/api/v1/auth/login", %{
          "username" => "Marcel@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"user" => %{"id" => id}, "token" => token} = json_response(conn, 200)["data"]
      assert id == user.id
      assert json_response(me(build_conn(), token), 200)
      assert %DateTime{} = Repo.get!(User, user.id).last_seen_at
    end
  end

  describe "guest" do
    setup :start_room_manager

    test "201 creates a direct guest without an invitation", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "creation_token" => Ecto.UUID.generate(),
          "install_id" => "device-direct",
          "platform" => "android"
        })
        |> json_response(201)

      assert %{"user" => user, "token" => token} = response["data"]
      refute Map.has_key?(response["data"], "state")
      assert user["guest"]
      assert user["display_name"] == "Anna"
      assert %{"user" => %{"id" => id}} = json_response(me(build_conn(), token), 200)["data"]
      assert id == user["id"]
    end

    test "201 generates a public name when direct creation omits it", %{conn: conn} do
      creation_token = Ecto.UUID.generate()
      params = %{"creation_token" => creation_token, "install_id" => "device-generated"}

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert first["user"]["display_name"] =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
      assert second["user"]["id"] == first["user"]["id"]
      assert second["user"]["display_name"] == first["user"]["display_name"]
    end

    test "201 generates a public name when direct creation supplies null", %{conn: conn} do
      assert %{"user" => %{"display_name" => display_name}} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => nil,
                 "creation_token" => Ecto.UUID.generate()
               })
               |> data(201)

      assert display_name =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "a direct retry returns the same guest instead of creating another", %{conn: conn} do
      creation_token = Ecto.UUID.generate()

      params = %{
        "display_name" => "Anna",
        "creation_token" => creation_token,
        "install_id" => "device-retry"
      }

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert second["user"]["id"] == first["user"]["id"]
      assert json_response(me(build_conn(), second["token"]), 200)
      assert Repo.aggregate(from(u in User, where: u.install_id == "device-retry"), :count) == 1
    end

    test "a creation token cannot recover an account after it is upgraded", %{conn: conn} do
      creation_token = Ecto.UUID.generate()
      params = %{"display_name" => "Anna", "creation_token" => creation_token}

      %{"user" => %{"id" => id}, "token" => token} =
        conn |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert build_conn()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post(~p"/api/v1/auth/upgrade", %{
               "email" => "anna@example.com",
               "password" => "password123"
             })
             |> json_response(200)

      assert %{"errors" => [%{"code" => "CREATION_CONFLICT"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", params)
               |> json_response(409)

      refute Repo.get!(User, id).guest
      assert Repo.aggregate(User, :count) == 1
    end

    test "direct entry requires a valid creation token", %{conn: conn} do
      assert %{"errors" => [%{"code" => "creation_token"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{"display_name" => "Anna"})
               |> json_response(422)

      assert %{"errors" => [%{"code" => "creation_token"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "creation_token" => "not-a-uuid"
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "creation_token"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "creation_token" => "sixteen-byte-key"
               })
               |> json_response(422)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "a supplied invalid invite never falls back to direct entry", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "creation_token" => Ecto.UUID.generate(),
               "invite_code" => "ZZZZZZZZ"
             })
             |> json_response(404)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "201 with a guest user, a working token and the invite state", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      response =
        conn
        |> post(~p"/api/v1/auth/guest", %{
          "display_name" => "Anna",
          "invite_code" => invite.code,
          "install_id" => "device-1",
          "platform" => "ios"
        })
        |> json_response(201)

      assert %{"user" => user, "token" => token, "state" => "open"} = response["data"]
      assert user["guest"] == true
      assert user["display_name"] == "Anna"
      assert user["username"] =~ ~r/\Aguest_/
      refute Map.has_key?(user, "install_id")

      assert %{"user" => %{"id" => id}} = json_response(me(build_conn(), token), 200)["data"]
      assert id == user["id"]
      assert %DateTime{} = Repo.get!(User, id).last_seen_at

      assert [%Event{kind: "guest_created", platform: "ios", user_id: ^id}] =
               invite_events(invite, "guest_created")
    end

    test "an invited retry returns one guest and records one creation event", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      params = %{
        "display_name" => "Anna",
        "invite_code" => invite.code,
        "creation_token" => Ecto.UUID.generate(),
        "platform" => "ios"
      }

      first = conn |> post(~p"/api/v1/auth/guest", params) |> data(201)
      second = build_conn() |> post(~p"/api/v1/auth/guest", params) |> data(201)

      assert second["user"]["id"] == first["user"]["id"]
      assert second["state"] == "open"
      assert [%Event{kind: "guest_created"}] = invite_events(invite, "guest_created")
    end

    test "a full table still creates the guest and answers state full", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      fill_with_held_seat!(room)

      assert %{"user" => %{"guest" => true}, "state" => "full"} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Late",
                 "invite_code" => invite.code
               })
               |> data(201)
    end

    test "a revoked invite is 410 INVITE_REVOKED and an expired one 410 INVITE_EXPIRED", %{
      conn: conn
    } do
      {host, room} = host_and_room()
      {:ok, revoked} = room |> mint!(host) |> Invites.revoke()

      assert %{"errors" => [%{"code" => "INVITE_REVOKED"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => revoked.code
               })
               |> json_response(410)

      past = DateTime.add(DateTime.utc_now(), -60, :second)
      expired = room |> mint!(host) |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert %{"errors" => [%{"code" => "INVITE_EXPIRED"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => expired.code
               })
               |> json_response(410)

      refute Repo.exists?(from(u in User, where: u.display_name == "Anna"))
    end

    test "an unknown invite code is 404 and a bad platform is 422 on platform", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "invite_code" => "ZZZZZZZZ"
             })
             |> json_response(404)

      {host, room} = host_and_room()
      invite = mint!(room, host)

      assert %{"errors" => [%{"code" => "platform"}]} =
               build_conn()
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => invite.code,
                 "platform" => "windows"
               })
               |> json_response(422)
    end

    test "AE13: a look-alike of a connected player's name is 422 on display_name", %{conn: conn} do
      {host, room} = host_and_room(%{display_name: "Marcel"})
      invite = mint!(room, host)

      assert %{"errors" => [%{"code" => "display_name"}]} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "marcél",
                 "invite_code" => invite.code
               })
               |> json_response(422)
    end

    test "AE15: a name held by a reconnecting seat is accepted", %{conn: conn} do
      {host, room} = host_and_room(%{display_name: "Marcel"})
      invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, anna.id)
      :ok = RoomManager.handle_player_disconnect(room.code, anna.id)

      assert %{"user" => %{"display_name" => "Anna"}} =
               conn
               |> post(~p"/api/v1/auth/guest", %{
                 "display_name" => "Anna",
                 "invite_code" => invite.code
               })
               |> data(201)
    end

    test "an invited guest gets a generated display_name when it is missing", %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)

      assert %{"user" => %{"display_name" => display_name}} =
               conn |> post(~p"/api/v1/auth/guest", %{"invite_code" => invite.code}) |> data(201)

      assert display_name =~ ~r/\A\S+ \S+(?: [2-9])?\z/u
    end

    test "guest_create at limit 1: the second creation from one address is 429", %{conn: conn} do
      with_limit(:guest_create, 1, 3_600_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)
      params = %{"display_name" => "Anna", "invite_code" => invite.code}

      assert conn
             |> from_ip({10, 3, 0, 1})
             |> post(~p"/api/v1/auth/guest", params)
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 0, 1})
             |> post(~p"/api/v1/auth/guest", Map.put(params, "display_name", "Ben"))
             |> json_response(429)
    end

    test "guest_create_install at limit 1: the second creation with one install_id is 429 across addresses",
         %{conn: conn} do
      with_limit(:guest_create_install, 1, 3_600_000)
      {host, room} = host_and_room()
      invite = mint!(room, host)

      params = %{
        "display_name" => "Anna",
        "invite_code" => invite.code,
        "install_id" => "device-shared"
      }

      assert conn
             |> from_ip({10, 3, 0, 2})
             |> post(~p"/api/v1/auth/guest", params)
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 0, 3})
             |> post(~p"/api/v1/auth/guest", Map.put(params, "display_name", "Ben"))
             |> json_response(429)

      # Without an install id the install bucket is skipped.
      assert build_conn()
             |> from_ip({10, 3, 0, 4})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Chris",
               "invite_code" => invite.code
             })
             |> json_response(201)
    end

    test "direct creation keeps the install abuse limit", %{conn: conn} do
      with_limit(:guest_create_install, 1, 3_600_000)

      assert conn
             |> from_ip({10, 3, 1, 1})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Anna",
               "creation_token" => Ecto.UUID.generate(),
               "install_id" => "direct-shared"
             })
             |> json_response(201)

      assert build_conn()
             |> from_ip({10, 3, 1, 2})
             |> post(~p"/api/v1/auth/guest", %{
               "display_name" => "Ben",
               "creation_token" => Ecto.UUID.generate(),
               "install_id" => "direct-shared"
             })
             |> json_response(429)
    end
  end

  describe "upgrade" do
    setup :start_room_manager

    test "AE9: 200 with a new token, the old token 401, guest false and a guest_upgraded event",
         %{conn: conn} do
      {host, room} = host_and_room()
      invite = mint!(room, host)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, _room, _position, _honored} = RoomManager.claim_seat(room.code, room.id, anna.id)

      {:ok, _redemption} =
        Invites.record_redemption(invite, %{user_id: anna.id, position: :south})

      old_token = Token.generate(anna)
      assert json_response(me(conn, old_token), 200)

      response =
        build_conn()
        |> put_req_header("authorization", "Bearer #{old_token}")
        |> post(~p"/api/v1/auth/upgrade", %{
          "email" => "Anna@example.com",
          "password" => "anna-secret-1"
        })
        |> json_response(200)

      assert %{
               "user" => %{"id" => id, "guest" => false, "display_name" => "Anna"},
               "token" => token
             } =
               response["data"]

      assert id == anna.id
      assert json_response(me(build_conn(), old_token), 401)
      assert json_response(me(build_conn(), token), 200)

      assert [%Event{kind: "guest_upgraded", user_id: ^id}] =
               invite_events(invite, "guest_upgraded")

      assert %{"user" => %{"id" => ^id}} =
               build_conn()
               |> post(~p"/api/v1/auth/login", %{
                 "username" => "anna@example.com",
                 "password" => "anna-secret-1"
               })
               |> data(200)
    end

    test "a registered caller is 409 NOT_A_GUEST", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert %{"errors" => [%{"code" => "NOT_A_GUEST"}]} =
               conn
               |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "new@example.com",
                 "password" => "long-enough"
               })
               |> json_response(409)
    end

    test "a taken email is 409 EMAIL_TAKEN and a taken username 409 USERNAME_TAKEN", %{
      conn: conn
    } do
      AccountsFixtures.user_fixture(%{email: "taken@example.com", username: "taken_name"})
      guest = AccountsFixtures.guest_fixture()

      assert %{"errors" => [%{"code" => "EMAIL_TAKEN"}]} =
               conn
               |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "TAKEN@example.com",
                 "password" => "long-enough"
               })
               |> json_response(409)

      assert %{"errors" => [%{"code" => "USERNAME_TAKEN"}]} =
               build_conn()
               |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
               |> post(~p"/api/v1/auth/upgrade", %{
                 "email" => "free@example.com",
                 "password" => "long-enough",
                 "username" => "taken_name"
               })
               |> json_response(409)

      assert Repo.get!(User, guest.id).guest
    end

    test "a missing password, a short password and a malformed email are 422", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      for body <- [
            %{"email" => "ok@example.com"},
            %{"email" => "ok@example.com", "password" => "1234567"},
            %{"email" => "not-an-email", "password" => "long-enough"}
          ] do
        assert %{"errors" => [_ | _]} =
                 build_conn()
                 |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
                 |> post(~p"/api/v1/auth/upgrade", body)
                 |> json_response(422)
      end

      assert json_response(me(conn, Token.generate(guest)), 200)
    end

    test "auth_upgrade at limit 1: the second attempt from one address is 429", %{conn: conn} do
      with_limit(:auth_upgrade, 1, 600_000)
      guest = AccountsFixtures.guest_fixture()
      body = %{"email" => "bad", "password" => "x"}

      assert conn
             |> from_ip({10, 3, 0, 5})
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/auth/upgrade", body)
             |> json_response(422)

      assert build_conn()
             |> from_ip({10, 3, 0, 5})
             |> put_req_header("authorization", "Bearer #{Token.generate(guest)}")
             |> post(~p"/api/v1/auth/upgrade", body)
             |> json_response(429)
    end
  end

  describe "delete_me" do
    setup :start_room_manager

    test "deleting an account during play leaves a permanent bot", %{conn: conn} do
      {_host, room} = host_and_room()
      leaver = AccountsFixtures.guest_fixture()
      others = Enum.map(1..2, fn _ -> AccountsFixtures.guest_fixture() end)
      assert {:ok, _, position} = RoomManager.join_room(room.code, leaver.id)
      for user <- others, do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))
      PidroServer.RoomFixtures.ready_room(room.code)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(leaver)}")
        |> delete(~p"/api/v1/auth/me")

      assert response(conn, 204)
      assert Repo.get(User, leaver.id) == nil
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].occupant_type == :bot
      assert Process.alive?(updated.seats[position].bot_pid)
      assert updated.seats[position].reserved_for == nil
    end

    test "AE10: 204, the token is dead afterwards and the seat is vacant", %{conn: conn} do
      {_host, room} = host_and_room()
      ben = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, ben.id)
      token = Token.generate(ben)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete(~p"/api/v1/auth/me")

      assert response(conn, 204)
      assert json_response(me(build_conn(), token), 401)
      assert is_nil(Repo.get(User, ben.id))

      {:ok, vacated} = RoomManager.get_room(room.code)
      assert vacated.positions.east == nil
    end
  end

  defp start_room_manager(_context) do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  defp host_and_room(host_attrs \\ %{}) do
    host = AccountsFixtures.user_fixture(host_attrs)
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
    {host, room}
  end

  defp mint!(room, host) do
    {:ok, invite} =
      Invites.create_invite(%{room_id: room.id, room_code: room.code, host_user_id: host.id})

    invite
  end

  # Four positions taken while one seat is held keeps the room `:waiting`.
  defp fill_with_held_seat!(room) do
    [a, b, c] = for _ <- 1..3, do: AccountsFixtures.user_fixture()
    {:ok, _room, _pos} = RoomManager.join_room(room.code, a.id)
    {:ok, _room, _pos} = RoomManager.join_room(room.code, b.id)
    :ok = RoomManager.handle_player_disconnect(room.code, a.id)
    {:ok, full, _pos} = RoomManager.join_room(room.code, c.id)
    assert full.status == :waiting
    full
  end

  defp invite_events(invite, kind) do
    Repo.all(from(e in Event, where: e.invite_id == ^invite.id and e.kind == ^kind))
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
