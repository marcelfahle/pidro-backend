defmodule PidroServer.Accounts.AuthTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, Token, User}
  alias PidroServer.AccountsFixtures

  defp subscribe_to_socket(user) do
    :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, "user_socket:#{user.id}")
  end

  defp fetch_for(token) do
    {:ok, claims} = Token.verify(token)
    Auth.fetch_user_for_token(claims)
  end

  describe "register_user/1" do
    test "ignores guest in the attributes" do
      assert {:ok, user} =
               Auth.register_user(%{
                 username: "register_guest",
                 email: "register_guest@example.com",
                 password: "password123",
                 guest: true
               })

      refute user.guest
      refute Repo.get!(User, user.id).guest
    end

    test "stores a trimmed display_name" do
      assert {:ok, user} =
               Auth.register_user(%{
                 username: "register_named",
                 email: "register_named@example.com",
                 password: "password123",
                 display_name: "  Anna  "
               })

      assert user.display_name == "Anna"
    end

    test "rejects a display_name longer than 40 characters" do
      assert {:error, changeset} =
               Auth.register_user(%{
                 username: "register_long",
                 email: "register_long@example.com",
                 password: "password123",
                 display_name: String.duplicate("a", 41)
               })

      assert %{display_name: ["should be at most 40 character(s)"]} = errors_on(changeset)
    end
  end

  describe "authenticate_user/2" do
    test "returns the user for valid credentials" do
      user = AccountsFixtures.user_fixture(%{username: "login_ok"})

      assert {:ok, %User{id: id}} =
               Auth.authenticate_user("login_ok", AccountsFixtures.valid_user_password())

      assert id == user.id
    end

    test "rejects a wrong password" do
      AccountsFixtures.user_fixture(%{username: "login_wrong"})

      assert {:error, :invalid_credentials} = Auth.authenticate_user("login_wrong", "nope nope")
    end

    test "rejects an unknown username" do
      assert {:error, :invalid_credentials} = Auth.authenticate_user("nobody", "password123")
    end

    test "returns invalid credentials for a user without a password hash" do
      {:ok, guest} =
        %User{}
        |> User.guest_changeset(%{username: "guest_login"})
        |> Repo.insert()

      assert is_nil(guest.password_hash)
      assert {:error, :invalid_credentials} = Auth.authenticate_user("guest_login", "anything")
    end
  end

  describe "change_user/2 and update_user/2" do
    test "set guest from admin attrs" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, updated} = Auth.update_user(user, %{"guest" => "true"})
      assert updated.guest
      assert Repo.get!(User, user.id).guest

      changeset = Auth.change_user(updated, %{"guest" => "false"})
      assert get_change(changeset, :guest) == false
    end

    test "still update username and email" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, updated} =
               Auth.update_user(user, %{
                 "username" => "renamed_by_admin",
                 "email" => "renamed@example.com"
               })

      assert updated.username == "renamed_by_admin"
      assert updated.email == "renamed@example.com"
    end
  end

  describe "fetch_user_for_token/1" do
    test "returns the user when the version matches" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{id: id, token_version: 0}} =
               Auth.fetch_user_for_token(%{id: user.id, v: 0})

      assert id == user.id
    end

    test "returns not_found for an unknown id" do
      assert {:error, :not_found} = Auth.fetch_user_for_token(%{id: Ecto.UUID.generate(), v: 0})
    end

    test "returns token_revoked when the version differs" do
      user = AccountsFixtures.user_fixture()

      assert {:error, :token_revoked} = Auth.fetch_user_for_token(%{id: user.id, v: 1})
      assert {:error, :token_revoked} = Auth.fetch_user_for_token(%{id: user.id, v: -1})
    end
  end

  describe "bump_token_version/1" do
    test "increments token_version atomically and returns the updated user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{token_version: 1} = bumped} = Auth.bump_token_version(user)
      assert bumped.id == user.id
      assert Repo.get!(User, user.id).token_version == 1

      assert {:ok, %User{token_version: 2}} = Auth.bump_token_version(bumped)
      assert Repo.get!(User, user.id).token_version == 2
    end

    test "accepts a bare user id" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, %User{token_version: 1}} = Auth.bump_token_version(user.id)
    end

    test "returns not_found for an unknown user" do
      assert {:error, :not_found} = Auth.bump_token_version(Ecto.UUID.generate())
    end

    test "invalidates every earlier token and accepts a fresh one" do
      user = AccountsFixtures.user_fixture()
      old_token = Token.generate(user)
      assert {:ok, _} = fetch_for(old_token)

      {:ok, bumped} = Auth.bump_token_version(user)

      assert {:error, :token_revoked} = fetch_for(old_token)
      assert {:ok, %User{token_version: 1}} = fetch_for(Token.generate(bumped))
    end

    test "broadcasts disconnect on the user's socket topic after the increment" do
      user = AccountsFixtures.user_fixture()
      subscribe_to_socket(user)

      {:ok, _bumped} = Auth.bump_token_version(user)

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "user_socket:#{user.id}"
      assert Repo.get!(User, user.id).token_version == 1
    end

    test "does not broadcast for an unknown user" do
      id = Ecto.UUID.generate()
      :ok = Phoenix.PubSub.subscribe(PidroServer.PubSub, "user_socket:#{id}")

      assert {:error, :not_found} = Auth.bump_token_version(id)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "two concurrent bumps leave token_version incremented by exactly 2" do
      user = AccountsFixtures.user_fixture()

      # The shared sandbox serialises these on one connection, so this pins
      # the atomic `inc` rather than a read-modify-write in application code.
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Auth.bump_token_version(user.id) end) end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %User{}}, &1))
      assert results |> Enum.map(fn {:ok, u} -> u.token_version end) |> Enum.sort() == [1, 2]
      assert Repo.get!(User, user.id).token_version == 2
    end
  end

  describe "reset_user_password/2" do
    test "changes the password, bumps token_version and clears the reset fields together" do
      user = AccountsFixtures.user_fixture(%{username: "reset_me"})
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)
      old_token = Token.generate(user)
      subscribe_to_socket(user)

      assert {:ok, %User{} = reset} = Auth.reset_user_password(reset_token, "new password!")

      assert reset.id == user.id
      assert reset.token_version == 1
      assert is_nil(reset.password_reset_token_hash)
      assert is_nil(reset.password_reset_sent_at)
      assert Bcrypt.verify_pass("new password!", reset.password_hash)

      stored = Repo.get!(User, user.id)
      assert stored.token_version == 1
      assert is_nil(stored.password_reset_token_hash)
      assert is_nil(stored.password_reset_sent_at)
      assert {:ok, _} = Auth.authenticate_user("reset_me", "new password!")

      assert {:error, :token_revoked} = fetch_for(old_token)
      assert {:ok, %User{token_version: 1}} = fetch_for(Token.generate(reset))

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "user_socket:#{user.id}"
    end

    test "rejects a reused reset token" do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)

      assert {:ok, _} = Auth.reset_user_password(reset_token, "new password!")

      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password(reset_token, "another password!")

      assert Repo.get!(User, user.id).token_version == 1
    end

    test "rejects unknown or malformed tokens" do
      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password("nope", "new password!")

      assert {:error, :invalid_or_expired_password_reset_token} =
               Auth.reset_user_password(nil, "new password!")
    end

    test "rolls back the whole transaction when the password is invalid" do
      user = AccountsFixtures.user_fixture()
      {:ok, %{token: reset_token}} = Auth.request_password_reset(user.username)
      subscribe_to_socket(user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.reset_user_password(reset_token, "short")

      assert %{password: [_message]} = errors_on(changeset)
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      stored = Repo.get!(User, user.id)
      assert stored.token_version == 0
      refute is_nil(stored.password_reset_token_hash)

      assert {:ok, %User{token_version: 1}} =
               Auth.reset_user_password(reset_token, "long enough now!")
    end
  end

  describe "user_fixture/1" do
    test "keeps the email when flipping guest" do
      user = AccountsFixtures.user_fixture(%{guest: true, email: "g@x.test"})

      assert user.guest
      assert user.email == "g@x.test"

      stored = Repo.get!(User, user.id)
      assert stored.guest
      assert stored.email == "g@x.test"
    end

    test "builds a non-guest by default" do
      user = AccountsFixtures.user_fixture()

      refute user.guest
      assert is_binary(user.password_hash)
    end
  end
end
