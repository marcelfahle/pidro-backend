defmodule PidroServer.Accounts.ClassicClaimsTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, ClassicClaims, ProviderAuth, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  defmodule Verifier do
    @behaviour PidroServer.Accounts.ProviderVerifier

    @impl true
    def verify(:apple, "valid-apple-token"), do: {:ok, "apple-subject"}
    def verify(:facebook, "valid-facebook-token"), do: {:ok, "facebook-subject"}
    def verify(_provider, _token), do: {:error, :invalid_credentials}
  end

  test "an authenticated guest keeps its identity and progress, and retry is a no-op" do
    guest = AccountsFixtures.guest_fixture()
    {:ok, profile} = Profiles.get_or_create_profile(guest.id)

    profile
    |> PlayerProfile.changeset(%{veteran_xp: 125, rating_mu: 31.5, games_played: 7})
    |> Repo.update!()

    ticket = issue_ticket!(guest, 10_001, :apple, "apple-subject", %{xp: 400})

    assert {:ok, claimed} = ClassicClaims.redeem(ticket, guest, %{})
    assert claimed.id == guest.id
    assert claimed.guest
    assert claimed.classic_user_id == 10_001
    assert claimed.apple_sub == "apple-subject"
    assert %DateTime{} = claimed.classic_claimed_at

    imported = Repo.get_by!(PlayerProfile, user_id: guest.id)
    assert imported.veteran_xp == 525
    assert imported.rating_mu == 31.5
    assert imported.games_played == 7
    claimed_at = claimed.classic_claimed_at

    assert {:ok, retried} = ClassicClaims.redeem(ticket, claimed, %{})
    assert retried.id == guest.id
    assert retried.classic_claimed_at == claimed_at
    assert Repo.get_by!(PlayerProfile, user_id: guest.id).veteran_xp == 525

    assert {:ok, signed_in} =
             ProviderAuth.authenticate(:apple, "valid-apple-token", verifier: Verifier)

    assert signed_in.id == guest.id
  end

  test "both directions of the one-to-one link reject transfer" do
    first = AccountsFixtures.user_fixture()
    second = AccountsFixtures.user_fixture()

    first_ticket = issue_ticket!(first, 20_001, :password, nil, %{xp: 10})
    assert {:ok, first} = ClassicClaims.redeem(first_ticket, first, %{})

    same_classic = issue_ticket!(second, 20_001, :password, nil, %{xp: 20})
    assert {:error, :already_claimed} = ClassicClaims.redeem(same_classic, second, %{})
    assert Repo.get!(User, second.id).classic_user_id == nil

    other_classic = issue_ticket!(first, 20_002, :password, nil, %{xp: 20})
    assert {:error, :user_already_claimed} = ClassicClaims.redeem(other_classic, first, %{})
    assert Repo.get!(User, first.id).classic_user_id == 20_001
  end

  test "an import conflict rolls the link and provider identity back" do
    user = AccountsFixtures.user_fixture()
    {:ok, _profile} = Profiles.import_legacy_progression(user, %{classic_user_id: 30_001, xp: 10})
    ticket = issue_ticket!(user, 30_002, :facebook, "facebook-subject", %{xp: 20})

    assert {:error, :user_already_claimed} = ClassicClaims.redeem(ticket, user, %{})

    persisted = Repo.get!(User, user.id)
    assert persisted.classic_user_id == nil
    assert persisted.facebook_id == nil
  end

  test "a fresh password claim creates one recoverable registered account" do
    ticket =
      issue_install_ticket!("fresh-password", 40_001, :password, nil, %{xp: 50})

    params = %{
      install_id: "fresh-password",
      account: %{
        username: "returning_veteran",
        email: "veteran@example.com",
        password: "password123"
      }
    }

    assert {:ok, created} = ClassicClaims.redeem(ticket, nil, params)
    refute created.guest
    assert created.classic_user_id == 40_001
    assert {:ok, signed_in} = Auth.authenticate_user("veteran@example.com", "password123")
    assert signed_in.id == created.id

    assert {:ok, retried} = ClassicClaims.redeem(ticket, nil, params)
    assert retried.id == created.id
  end

  test "a fresh social claim binds repeat sign-in without inventing an email" do
    ticket =
      issue_install_ticket!("fresh-facebook", 50_001, :facebook, "facebook-subject", %{xp: 25})

    assert {:ok, created} =
             ClassicClaims.redeem(ticket, nil, %{
               install_id: "fresh-facebook",
               account: %{username: "social_veteran"}
             })

    refute created.guest
    assert created.email == nil
    assert created.facebook_id == "facebook-subject"

    assert {:ok, signed_in} =
             ProviderAuth.authenticate(:facebook, "valid-facebook-token", verifier: Verifier)

    assert signed_in.id == created.id
  end

  test "expiry and binding failures leave the user untouched" do
    user = AccountsFixtures.user_fixture()

    {:ok, %{ticket: expired}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 60_001,
        method: :password,
        user_id: user.id,
        legacy_data: %{xp: 100},
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    assert {:error, :claim_ticket_expired} = ClassicClaims.redeem(expired, user, %{})
    assert Repo.get!(User, user.id).classic_user_id == nil

    install_ticket =
      issue_install_ticket!("right-install", 60_002, :facebook, "other-subject", %{xp: 100})

    assert {:error, :claim_ticket_binding_mismatch} =
             ClassicClaims.redeem(install_ticket, nil, %{
               install_id: "wrong-install",
               account: %{username: "never_created"}
             })

    refute Repo.get_by(User, username: "never_created")
  end

  defp issue_ticket!(user, classic_user_id, method, provider_id, legacy_data) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: method,
        provider_id: provider_id,
        user_id: user.id,
        legacy_data: Map.put(legacy_data, :classic_user_id, classic_user_id)
      })

    ticket
  end

  defp issue_install_ticket!(install_id, classic_user_id, method, provider_id, legacy_data) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: method,
        provider_id: provider_id,
        install_id: install_id,
        legacy_data: Map.put(legacy_data, :classic_user_id, classic_user_id)
      })

    ticket
  end
end
