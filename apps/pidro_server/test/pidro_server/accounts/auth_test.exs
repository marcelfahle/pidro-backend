defmodule PidroServer.Accounts.AuthTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.AccountsFixtures

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
