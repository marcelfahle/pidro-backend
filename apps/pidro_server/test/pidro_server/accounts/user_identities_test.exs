defmodule PidroServer.Accounts.UserIdentitiesTest do
  use PidroServer.DataCase, async: false

  import ExUnit.CaptureLog

  alias PidroServer.Accounts.{Auth, User, UserIdentities, UserIdentity}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  test "a backfilled identity heals missing metadata and advances last_used_at" do
    user = AccountsFixtures.guest_fixture()
    linked_at = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, _user} =
             UserIdentities.link(user, identity_attrs(nil), :backfill, linked_at)

    assert {:ok, signed_in} =
             UserIdentities.sign_in(
               identity_attrs(%{
                 issuer_app: "com.oneapps.pidro",
                 email: "relay@privaterelay.appleid.com",
                 email_is_relay: true,
                 business_ids: []
               })
             )

    identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-subject")
    assert identity.link_source == :backfill
    assert identity.linked_at == linked_at
    assert DateTime.after?(identity.last_used_at, linked_at)
    assert identity.issuer_app == "com.oneapps.pidro"
    assert identity.email == "relay@privaterelay.appleid.com"
    assert identity.email_is_relay
    assert identity.business_ids == []
    assert signed_in.email == "relay@privaterelay.appleid.com"
  end

  test "an email owned by another user stays only on the identity" do
    _owner = AccountsFixtures.user_fixture(%{email: "taken@example.com"})
    user = AccountsFixtures.guest_fixture()

    assert {:ok, linked} =
             UserIdentities.link(
               user,
               identity_attrs(%{email: "TAKEN@example.com"}),
               :sign_up
             )

    assert linked.email == nil
    assert Repo.get!(User, user.id).email == nil

    identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-subject")
    assert identity.email == "TAKEN@example.com"
  end

  test "a changed verified email is logged without either address and not overwritten" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, _user} =
             UserIdentities.link(
               user,
               identity_attrs(%{email: "first@example.com"}),
               :sign_up
             )

    log =
      capture_log(fn ->
        assert {:ok, _user} =
                 UserIdentities.sign_in(identity_attrs(%{email: "second@example.com"}))
      end)

    assert log =~ "different verified email"
    refute log =~ "first@example.com"
    refute log =~ "second@example.com"
    assert Repo.get_by!(UserIdentity, subject: "apple-subject").email == "first@example.com"
  end

  test "deleting a user cascades to every identity" do
    user = AccountsFixtures.guest_fixture()
    assert {:ok, _user} = UserIdentities.link(user, identity_attrs(%{}), :sign_up)
    assert Repo.get_by(UserIdentity, user_id: user.id)

    assert {:ok, _deleted} = Auth.delete_user(user)
    refute Repo.get_by(UserIdentity, user_id: user.id)
  end

  test "provider lookup does not fall back to legacy user columns" do
    user = AccountsFixtures.guest_fixture()
    user |> Ecto.Changeset.change(apple_sub: "legacy-only") |> Repo.update!()

    assert {:error, :not_found} =
             UserIdentities.sign_in(identity_attrs(%{subject: "legacy-only"}))
  end

  defp identity_attrs(overrides) do
    Map.merge(
      %{
        provider: :apple,
        subject: "apple-subject",
        issuer_app: nil,
        email: nil,
        email_is_relay: false,
        business_ids: nil
      },
      overrides || %{}
    )
  end
end
