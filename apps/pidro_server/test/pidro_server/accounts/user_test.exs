defmodule PidroServer.Accounts.UserTest do
  use PidroServer.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias PidroServer.Accounts
  alias PidroServer.Accounts.{Auth, User}
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

    test "collapses separator whitespace without hiding control characters" do
      changeset =
        User.changeset(%User{}, %{username: "spaced", display_name: "  Nordic\u{00A0}  Moose  "})

      assert changeset.valid?
      assert get_change(changeset, :display_name) == "Nordic Moose"

      refute User.changeset(%User{}, %{username: "tabbed", display_name: "Nordic\tMoose"}).valid?
    end

    test "clears an existing display_name with nil or a blank value" do
      user = %User{username: "anna_clear", display_name: "Anna"}

      for value <- [nil, "", "   "] do
        changeset = User.changeset(user, %{display_name: value})
        assert changeset.valid?, inspect(changeset.errors)
        assert Ecto.Changeset.get_field(changeset, :display_name) == nil
      end
    end

    test "treats a blank display_name as nil" do
      changeset = User.changeset(%User{}, %{username: "blank_name", display_name: "   "})

      assert changeset.valid?
      assert get_field(changeset, :display_name) == nil
    end

    test "accepts a display_name of exactly 20 graphemes" do
      changeset =
        User.changeset(%User{}, %{username: "twenty", display_name: String.duplicate("a", 20)})

      assert changeset.valid?
    end

    test "rejects a display_name longer than 20 graphemes" do
      changeset =
        User.changeset(%User{}, %{
          username: "twenty_one",
          display_name: String.duplicate("a", 21)
        })

      refute changeset.valid?
      assert %{display_name: ["should be at most 20 character(s)"]} = errors_on(changeset)
    end

    test "rejects a single-grapheme display_name" do
      changeset = User.changeset(%User{}, %{username: "one_char", display_name: "A"})

      refute changeset.valid?
      assert %{display_name: ["should be at least 2 character(s)"]} = errors_on(changeset)
    end

    test "counts graphemes, not bytes or codepoints" do
      # 20 flags: 160 bytes, 40 codepoints, 20 graphemes.
      flags = String.duplicate("\u{1F1EB}\u{1F1EE}", 20)
      changeset = User.changeset(%User{}, %{username: "flags", display_name: flags})

      assert changeset.valid?, inspect(changeset.errors)
    end

    test "measures the display_name length after trimming" do
      padded = "  " <> String.duplicate("a", 20) <> "  "
      changeset = User.changeset(%User{}, %{username: "padded", display_name: padded})

      assert changeset.valid?
      assert get_change(changeset, :display_name) == String.duplicate("a", 20)
    end

    test "folds compatibility characters with NFKC" do
      # Full-width "A" (U+FF21) and the "fi" ligature (U+FB01) fold to ASCII.
      changeset =
        User.changeset(%User{}, %{username: "fullwidth", display_name: "\u{FF21}nna \u{FB01}n"})

      assert changeset.valid?
      assert get_change(changeset, :display_name) == "Anna fin"
    end

    test "rejects a zero-width joiner" do
      changeset = User.changeset(%User{}, %{username: "zwj", display_name: "An\u{200D}na"})

      refute changeset.valid?

      assert %{display_name: ["must not contain control or format characters"]} =
               errors_on(changeset)
    end

    test "rejects a control character" do
      changeset = User.changeset(%User{}, %{username: "control", display_name: "An\u{0001}na"})

      refute changeset.valid?

      assert %{display_name: ["must not contain control or format characters"]} =
               errors_on(changeset)
    end

    test "accepts an emoji-only display_name" do
      changeset =
        User.changeset(%User{}, %{username: "emoji", display_name: "\u{1F98A}\u{1F43C}"})

      assert changeset.valid?, inspect(changeset.errors)
    end
  end

  describe "name_key/1" do
    test "maps accent, case and spacing variants to one key" do
      assert User.name_key("Marcél") == "marcel"
      assert User.name_key("MARCEL") == "marcel"
      assert User.name_key("m a r c e l") == "marcel"
      assert User.name_key("Marcel") == "marcel"
      assert User.name_key("M.a-r_c/e l!") == "marcel"
    end

    test "folds compatibility forms before keying" do
      assert User.name_key("\u{FF2D}arcel") == "marcel"
    end

    test "falls back to the casefolded name when nothing alphanumeric remains" do
      assert User.name_key("\u{1F98A}") == "\u{1F98A}"
      assert User.name_key("\u{1F98A}") != User.name_key("\u{1F43C}")
      assert User.name_key(" \u{1F98A} ") == "\u{1F98A}"
    end

    test "answers nil for nil" do
      assert User.name_key(nil) == nil
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
          display_name: String.duplicate("b", 21)
        })

      refute too_long.valid?
      assert %{display_name: ["should be at most 20 character(s)"]} = errors_on(too_long)
    end

    test "casts install_id up to 64 characters" do
      ok =
        User.guest_changeset(%User{}, %{
          username: "guest_five",
          install_id: String.duplicate("i", 64)
        })

      assert ok.valid?
      assert get_change(ok, :install_id) == String.duplicate("i", 64)

      too_long =
        User.guest_changeset(%User{}, %{
          username: "guest_six",
          install_id: String.duplicate("i", 65)
        })

      refute too_long.valid?
      assert %{install_id: ["should be at most 64 character(s)"]} = errors_on(too_long)
    end
  end

  describe "upgrade_changeset/2" do
    setup do
      {:ok, guest} =
        %User{}
        |> User.guest_changeset(%{username: "guest_upgrade", display_name: "Anna"})
        |> Repo.insert()

      %{guest: guest}
    end

    test "sets email, password hash and guest false, keeping the username", %{guest: guest} do
      changeset =
        User.upgrade_changeset(guest, %{email: "anna@example.com", password: "password123"})

      assert changeset.valid?, inspect(changeset.errors)
      assert get_change(changeset, :email) == "anna@example.com"
      assert get_change(changeset, :guest) == false
      assert Bcrypt.verify_pass("password123", get_change(changeset, :password_hash))
      refute Map.has_key?(changeset.changes, :password)
      assert get_field(changeset, :username) == "guest_upgrade"
      assert get_field(changeset, :display_name) == "Anna"
    end

    test "applies an optional username", %{guest: guest} do
      changeset =
        User.upgrade_changeset(guest, %{
          email: "anna@example.com",
          password: "password123",
          username: "anna"
        })

      assert changeset.valid?
      assert get_change(changeset, :username) == "anna"
    end

    test "requires email and password", %{guest: guest} do
      changeset = User.upgrade_changeset(guest, %{})

      refute changeset.valid?
      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates the email format, the password minimum and the username minimum", %{
      guest: guest
    } do
      changeset =
        User.upgrade_changeset(guest, %{email: "not-an-email", password: "short", username: "ab"})

      refute changeset.valid?

      assert %{
               email: ["must be a valid email address"],
               password: ["should be at least 8 character(s)"],
               username: ["should be at least 3 character(s)"]
             } = errors_on(changeset)
    end

    test "returns the unique-constraint errors for a taken email or username", %{guest: guest} do
      AccountsFixtures.user_fixture(%{username: "taken_up", email: "taken_up@example.com"})

      assert {:error, email_taken} =
               Repo.update(
                 User.upgrade_changeset(guest, %{
                   email: "taken_up@example.com",
                   password: "password123"
                 })
               )

      assert %{email: ["has already been taken"]} = errors_on(email_taken)

      assert {:error, username_taken} =
               Repo.update(
                 User.upgrade_changeset(guest, %{
                   email: "fresh@example.com",
                   password: "password123",
                   username: "taken_up"
                 })
               )

      assert %{username: ["has already been taken"]} = errors_on(username_taken)
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
          display_name: String.duplicate("c", 21),
          guest: true
        })

      refute changeset.valid?

      assert %{
               username: ["should be at least 3 character(s)"],
               display_name: ["should be at most 20 character(s)"]
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

  describe "validate_email/1" do
    # The SMTP encoder raises on these before the `@`, so no mail could reach them.
    for char <- [",", ";", "\"", "<", "("] do
      test "refuses #{char} before the @" do
        changeset = email_changeset("anna#{unquote(char)}ben@example.com")

        assert %{email: ["must be a valid email address"]} = errors_on(changeset)
      end
    end

    test "keeps ordinary addresses" do
      for email <- [
            "anna@example.com",
            "anna+pidro@example.com",
            "anna.ben@example.com",
            "anna@mail.example.co.uk",
            "o'hara_1-2@example.ie",
            "Anna.Ben@Example.COM"
          ] do
        assert email_changeset(email).valid?, email
      end
    end

    test "leaves an unchanged stored address alone" do
      user = %User{username: "anna", email: "anna,ben@example.com"}

      assert User.changeset(user, %{display_name: "Anna"}).valid?
    end
  end

  defp email_changeset(email),
    do: User.changeset(%User{}, %{username: "anna", email: email})

  describe "share_slug/2" do
    defp slug(username, taken \\ []), do: User.share_slug(username, &(&1 in taken))

    test "transliterates Swedish and German letters and drops other marks" do
      assert slug("Åsa Öberg") == "asa-oberg"
      assert slug("Jürgen Häkkinen") == "jurgen-hakkinen"
      assert slug("Renée") == "renee"
    end

    test "turns spaces into dashes, strips the rest and collapses dashes" do
      assert slug("  Bengt  the -- Great!  ") == "bengt-the-great"
      assert slug("anna_b/c.d") == "annabcd"
      assert slug("Ünal 🃏 Ok") == "unal-ok"
    end

    test "prefixes a too-short result" do
      assert slug("Bo!") == "player-bo"
      assert slug("日本語") == "player"
    end

    test "numbers clashes from 2 and keeps every candidate within 30 characters" do
      assert slug("Bengt", ["bengt"]) == "bengt-2"
      assert slug("bengt", ["bengt", "bengt-2"]) == "bengt-3"

      long = String.duplicate("a", 28) <> " b"
      assert slug(long) == String.duplicate("a", 28) <> "-b"
      assert slug(long, [slug(long)]) == String.duplicate("a", 28) <> "-2"
    end
  end

  describe "share slugs on accounts" do
    test "registration sets the slug once and a case-only clash gets a suffix" do
      bengt = AccountsFixtures.user_fixture(%{username: "Bengt"})
      lower = AccountsFixtures.user_fixture(%{username: "bengt"})

      assert {bengt.share_slug, lower.share_slug} == {"bengt", "bengt-2"}

      {:ok, renamed} = Auth.update_user(bengt, %{username: "Bengt Two"})
      assert renamed.share_slug == "bengt"
    end

    test "guests have none until they register" do
      guest = AccountsFixtures.guest_fixture()
      assert guest.share_slug == nil

      {:ok, upgraded} =
        Auth.upgrade_guest(guest, %{
          username: "Göran",
          email: "goran@example.com",
          password: AccountsFixtures.valid_user_password()
        })

      assert upgraded.share_slug == "goran"
    end

    test "the backfill gives registered accounts slugs, oldest first" do
      older = AccountsFixtures.user_fixture(%{username: "Märta"})
      newer = AccountsFixtures.user_fixture(%{username: "marta"})
      kept = AccountsFixtures.user_fixture(%{username: "Kept"})
      guest = AccountsFixtures.guest_fixture()

      Repo.update_all(from(u in User, where: u.id in ^[older.id, newer.id]),
        set: [share_slug: nil]
      )

      Repo.update_all(from(u in User, where: u.id == ^older.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]]
      )

      assert :ok = Accounts.backfill_share_slugs()

      slugs =
        Map.new([older, newer, kept, guest], &{&1.id, Repo.get!(User, &1.id).share_slug})

      assert slugs == %{
               older.id => "marta",
               newer.id => "marta-2",
               kept.id => "kept",
               guest.id => nil
             }
    end
  end
end
