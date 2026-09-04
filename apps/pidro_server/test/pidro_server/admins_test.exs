defmodule PidroServer.AdminsTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Admins
  alias PidroServer.Admins.AdminToken
  alias PidroServer.AdminsFixtures
  alias PidroServer.Repo

  setup do
    original_email = Application.get_env(:pidro_server, :admin_seed_email)

    on_exit(fn ->
      if original_email do
        Application.put_env(:pidro_server, :admin_seed_email, original_email)
      else
        Application.delete_env(:pidro_server, :admin_seed_email)
      end
    end)

    :ok
  end

  test "seed_first_admin creates the initial forced-password account idempotently" do
    Application.put_env(:pidro_server, :admin_seed_email, "First.Admin@example.com")

    assert {:ok, admin} = Admins.seed_first_admin()
    assert admin.email == "first.admin@example.com"
    assert admin.force_password_change
    assert Admins.get_admin_by_email_and_password(admin.email, "changeme123").id == admin.id

    assert {:ok, :already_seeded} = Admins.seed_first_admin()
    assert Admins.list_admins() == [admin]
  end

  test "an existing admin creates a forced-password admin with a generated password" do
    acting_admin = AdminsFixtures.admin_fixture()

    assert {:ok, admin, temporary_password} =
             Admins.create_admin(acting_admin, %{"email" => "new.admin@example.com"})

    assert admin.force_password_change
    assert byte_size(temporary_password) == 24

    assert Admins.get_admin_by_email_and_password(admin.email, temporary_password).id == admin.id
  end

  test "changing a password clears the forced gate and revokes every session" do
    admin =
      AdminsFixtures.admin_fixture(%{
        password: "temporary password",
        force_password_change: true
      })

    token = Admins.generate_admin_session_token(admin)

    assert {:ok, updated_admin} =
             Admins.update_admin_password(admin, %{
               "current_password" => "temporary password",
               "password" => "a brand new password",
               "password_confirmation" => "a brand new password"
             })

    refute updated_admin.force_password_change
    assert is_nil(Admins.get_admin_by_session_token(token))
    assert Admins.get_admin_by_email_and_password(admin.email, "a brand new password")
    refute Admins.get_admin_by_email_and_password(admin.email, "temporary password")
  end

  test "admin sessions expire after fourteen idle days" do
    admin = AdminsFixtures.admin_fixture()
    token = Admins.generate_admin_session_token(admin)

    Repo.update_all(AdminToken.by_token_and_context_query(token, "session"),
      set: [last_used_at: DateTime.add(DateTime.utc_now(), -15, :day)]
    )

    assert is_nil(Admins.get_admin_by_session_token(token))
  end

  test "deleting an admin revokes sessions and the final admin cannot delete themselves" do
    acting_admin = AdminsFixtures.admin_fixture()
    doomed_admin = AdminsFixtures.admin_fixture()
    token = Admins.generate_admin_session_token(doomed_admin)

    assert {:ok, deleted_admin} = Admins.delete_admin(acting_admin, doomed_admin.id)
    assert deleted_admin.id == doomed_admin.id
    assert is_nil(Admins.get_admin_by_session_token(token))
    assert {:error, :last_admin} = Admins.delete_admin(acting_admin, acting_admin.id)
    assert Admins.get_admin(acting_admin.id)
  end
end
