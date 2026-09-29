defmodule PidroServer.Accounts.ClassicNameReservationsTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, ClassicNameReservation, ClassicNameReservations, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  @message "This name belongs to a Classic player. Claim your Classic profile or choose another name."

  test "keys lowercase, trim and collapse whitespace without broader look-alike folding" do
    assert ClassicNameReservations.name_key("  Veteran\t  Name  ") == "veteran name"
    assert ClassicNameReservations.name_key("VÉTERAN") == "véteran"
    assert ClassicNameReservations.name_key("Vet-eran") == "vet-eran"
  end

  test "a decomposed accent keys the same as the precomposed one" do
    assert ClassicNameReservations.name_key("Ve\u0301teran") ==
             ClassicNameReservations.name_key("V\u00e9teran")
  end

  test "import keeps both colliding owners and never overwrites an existing owner" do
    imported_at = ~U[2026-09-27 12:00:00.000000Z]

    assert {:ok, %{inserted: 2, existing: 0, collisions: 1}} =
             ClassicNameReservations.import(
               [
                 %{"id" => 101, "username" => "Veteran  Name"},
                 %{"id" => 202, "username" => " veteran name "}
               ],
               imported_at
             )

    assert Repo.aggregate(ClassicNameReservation, :count) == 2

    assert {:ok, %{inserted: 1, existing: 1, collisions: 1}} =
             ClassicNameReservations.import(
               [
                 %{id: 101, username: "Renamed Later"},
                 %{id: 303, username: "Another Veteran"}
               ],
               DateTime.add(imported_at, 86_400, :second)
             )

    frozen = Repo.get!(ClassicNameReservation, 101)
    assert frozen.username == "Veteran  Name"
    assert frozen.name_key == "veteran name"
    assert frozen.imported_at == imported_at
  end

  @tag :tmp_dir
  test "import_file reads the JSON export and summarizes it with the cutoff", %{tmp_dir: dir} do
    path = Path.join(dir, "classic-names.json")
    File.write!(path, Jason.encode!([%{"id" => 303, "username" => "Snapshot"}]))

    assert ClassicNameReservations.import_file(path) |> ClassicNameReservations.import_summary() ==
             "Classic name cutoff 2026-09-27: imported 1, kept 0 existing, found 0 colliding key(s)."

    File.write!(path, ~s({"id": 1}))
    assert_raise ArgumentError, fn -> ClassicNameReservations.import_file(path) end
  end

  test "registration rejects reserved username and display-name variants" do
    reserve!(401, "Classic Hero")

    assert {:error, username_error} =
             Auth.register_user(%{
               username: "  CLASSIC   HERO ",
               email: "username@example.com",
               password: "password123"
             })

    assert %{username: [@message]} = errors_on(username_error)
    assert {@message, [code: :classic_name_reserved]} = username_error.errors[:username]

    assert {:error, display_error} =
             Auth.register_user(%{
               username: "newcomer",
               display_name: " classic   hero ",
               email: "display@example.com",
               password: "password123"
             })

    assert %{display_name: [@message]} = errors_on(display_error)

    assert {@message, [code: :classic_name_reserved]} =
             display_error.errors[:display_name]
  end

  test "guest creation and guest upgrade reject reserved public names" do
    reserve!(501, "Old Timer")

    assert {:error, guest_error} =
             Auth.create_guest_user(%{display_name: " old   TIMER "}, [])

    assert %{display_name: [@message]} = errors_on(guest_error)

    guest = AccountsFixtures.guest_fixture()

    assert {:error, upgrade_error} =
             Auth.upgrade_guest(guest, %{
               username: "OLD TIMER",
               email: "upgrade@example.com",
               password: "password123"
             })

    assert %{username: [@message]} = errors_on(upgrade_error)
    assert Repo.get!(User, guest.id).guest
  end

  test "admin username changes enforce reservations but unrelated edits preserve established names" do
    reserve!(601, "Established")
    user = AccountsFixtures.user_fixture()

    assert {:error, changeset} = Auth.update_user(user, %{username: " ESTABLISHED "})
    assert %{username: [@message]} = errors_on(changeset)

    established = user |> Ecto.Changeset.change(username: "Established") |> Repo.update!()
    assert {:ok, updated} = Auth.update_user(established, %{guest: true})
    assert updated.username == "Established"

    owner =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(
        classic_user_id: 601,
        classic_claimed_at: DateTime.utc_now()
      )
      |> Repo.update!()

    assert {:ok, owner} = Auth.update_user(owner, %{username: "  ESTABLISHED  "})
    assert owner.username == "  ESTABLISHED  "
  end

  defp reserve!(id, username) do
    assert {:ok, _result} = ClassicNameReservations.import([%{id: id, username: username}])
  end
end
