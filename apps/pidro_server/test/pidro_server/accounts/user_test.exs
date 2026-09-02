defmodule PidroServer.Accounts.UserTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Accounts.User
  alias PidroServer.AccountsFixtures

  describe "changeset/2" do
    test "does not cast guest from public params" do
      changeset = User.changeset(%User{}, %{username: "public_user", guest: true})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :guest)
      assert get_field(changeset, :guest) == false
    end

    test "does not cast guest from string-keyed params" do
      changeset = User.changeset(%User{}, %{"username" => "public_user", "guest" => "true"})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :guest)
    end

    test "trims display_name" do
      changeset = User.changeset(%User{}, %{username: "trimmed", display_name: "  Anna  "})

      assert changeset.valid?
      assert get_change(changeset, :display_name) == "Anna"
    end

    test "treats a blank display_name as nil" do
      changeset = User.changeset(%User{}, %{username: "blank_name", display_name: "   "})

      assert changeset.valid?
      assert get_field(changeset, :display_name) == nil
    end

    test "accepts a display_name of exactly 40 characters" do
      changeset =
        User.changeset(%User{}, %{username: "forty", display_name: String.duplicate("a", 40)})

      assert changeset.valid?
    end

    test "rejects a display_name longer than 40 characters" do
      changeset =
        User.changeset(%User{}, %{username: "forty_one", display_name: String.duplicate("a", 41)})

      refute changeset.valid?
      assert %{display_name: ["should be at most 40 character(s)"]} = errors_on(changeset)
    end

    test "measures the display_name length after trimming" do
      padded = "  " <> String.duplicate("a", 40) <> "  "
      changeset = User.changeset(%User{}, %{username: "padded", display_name: padded})

      assert changeset.valid?
      assert get_change(changeset, :display_name) == String.duplicate("a", 40)
    end
  end

  describe "guest_changeset/2" do
    test "builds a guest from username and display_name without credentials" do
      changeset =
        User.guest_changeset(%User{}, %{username: "guest_one", display_name: "Guest One"})

      assert changeset.valid?
      assert get_field(changeset, :guest) == true
      assert get_field(changeset, :display_name) == "Guest One"
      assert get_field(changeset, :email) == nil
      assert get_field(changeset, :password_hash) == nil

      assert {:ok, user} = Repo.insert(changeset)
      assert user.guest
      assert user.username == "guest_one"
      assert is_nil(user.email)
      assert is_nil(user.password_hash)
      assert user.token_version == 0
    end

    test "requires a username" do
      changeset = User.guest_changeset(%User{}, %{display_name: "No Name"})

      refute changeset.valid?
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a username shorter than 3 characters" do
      changeset = User.guest_changeset(%User{}, %{username: "ab"})

      refute changeset.valid?
      assert %{username: ["should be at least 3 character(s)"]} = errors_on(changeset)
    end

    test "returns the unique-constraint error for a taken username" do
      AccountsFixtures.user_fixture(%{username: "taken_name"})

      assert {:error, changeset} =
               Repo.insert(User.guest_changeset(%User{}, %{username: "taken_name"}))

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "ignores email, password and guest in the params" do
      changeset =
        User.guest_changeset(%User{}, %{
          username: "guest_two",
          email: "guest@example.com",
          password: "password123",
          guest: false
        })

      assert changeset.valid?
      assert get_field(changeset, :guest) == true
      refute Map.has_key?(changeset.changes, :email)
      refute Map.has_key?(changeset.changes, :password)
    end

    test "trims and bounds display_name" do
      trimmed = User.guest_changeset(%User{}, %{username: "guest_three", display_name: " Bo "})
      assert get_change(trimmed, :display_name) == "Bo"

      too_long =
        User.guest_changeset(%User{}, %{
          username: "guest_four",
          display_name: String.duplicate("b", 41)
        })

      refute too_long.valid?
      assert %{display_name: ["should be at most 40 character(s)"]} = errors_on(too_long)
    end
  end

  describe "admin_changeset/2" do
    test "toggles guest" do
      user = AccountsFixtures.user_fixture()
      refute user.guest

      changeset = User.admin_changeset(user, %{guest: true})
      assert get_change(changeset, :guest) == true
      assert {:ok, guest} = Repo.update(changeset)
      assert guest.guest

      assert {:ok, reverted} =
               guest
               |> User.admin_changeset(%{"guest" => "false"})
               |> Repo.update()

      refute reverted.guest
    end

    test "still validates the public fields" do
      user = AccountsFixtures.user_fixture()

      changeset =
        User.admin_changeset(user, %{
          username: "ab",
          display_name: String.duplicate("c", 41),
          guest: true
        })

      refute changeset.valid?

      assert %{
               username: ["should be at least 3 character(s)"],
               display_name: ["should be at most 40 character(s)"]
             } = errors_on(changeset)
    end

    test "trims display_name" do
      user = AccountsFixtures.user_fixture()
      changeset = User.admin_changeset(user, %{display_name: "  Admin Set  "})

      assert get_change(changeset, :display_name) == "Admin Set"
    end
  end

  describe "token_version" do
    test "defaults to 0 on a fresh struct and on the stored row" do
      assert %User{}.token_version == 0

      user = AccountsFixtures.user_fixture()
      assert user.token_version == 0
      assert Repo.get!(User, user.id).token_version == 0
    end
  end
end
