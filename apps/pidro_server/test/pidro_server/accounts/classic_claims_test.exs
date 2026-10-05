defmodule PidroServer.Accounts.ClassicClaimsTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{
    Auth,
    ClassicClaims,
    ClassicClaimTicket,
    ClassicNameReservation,
    ClassicNameReservations,
    ProviderAuth,
    User,
    UserIdentity
  }

  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  defmodule ProviderIdentity do
    def apple("valid-apple-token"), do: {:ok, %{"sub" => "apple-subject"}}
    def apple(_token), do: {:error, :invalid_credentials}

    def facebook("valid-facebook-token") do
      {:ok, %{subject: "facebook-subject", issuer_app: "facebook-app", email: nil}}
    end

    def facebook(_token), do: {:error, :invalid_credentials}
    def facebook_business_ids("valid-facebook-token"), do: {:ok, []}
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
    assert claimed.classic_claim_method == :apple
    assert claimed.classic_matched_on == :email
    assert claimed.apple_sub == "apple-subject"
    assert %DateTime{} = claimed.classic_claimed_at

    identity = Repo.get_by!(UserIdentity, provider: :apple, subject: "apple-subject")
    assert identity.user_id == guest.id
    assert identity.link_source == :claim

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
             ProviderAuth.authenticate(:apple, "valid-apple-token", %{},
               provider_identity: ProviderIdentity
             )

    assert signed_in.id == guest.id
  end

  test "a blocked Classic name requires a replacement without losing the claim or career" do
    guest = AccountsFixtures.guest_fixture(%{display_name: "Random Guest"})

    assert {:ok, _} =
             ClassicNameReservations.import([%{id: 10_002, username: "Fuckface"}])

    ticket =
      issue_ticket!(guest, 10_002, :password, nil, %{
        xp: 250,
        classic_username: "Fuckface",
        classic_name_allowed: false,
        classic_level: 42,
        games_played_counter: 99
      })

    assert {:error, changeset} = ClassicClaims.redeem(ticket, guest, %{})
    assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    assert Repo.get!(User, guest.id).classic_user_id == nil
    assert Repo.get_by(PlayerProfile, user_id: guest.id) == nil

    assert {:ok, claimed} =
             ClassicClaims.redeem(ticket, guest, %{account: %{display_name: "Kind Player"}})

    assert claimed.id == guest.id
    assert claimed.display_name == "Kind Player"
    assert claimed.classic_user_id == 10_002

    profile = Repo.get_by!(PlayerProfile, user_id: guest.id)
    assert profile.veteran_xp == 250
    assert profile.heritage_flags["classic_username"] == "Fuckface"
    assert profile.heritage_flags["classic_name_allowed"] == false
    assert Repo.get!(ClassicNameReservation, 10_002).username == "Fuckface"
    refute Map.has_key?(Profiles.public_profile(guest.id).classic, :name)

    assert {:ok, retried} =
             ClassicClaims.redeem(ticket, claimed, %{
               account: %{display_name: "Fuckface"}
             })

    assert retried.display_name == "Kind Player"
  end

  test "both directions of the one-to-one link reject transfer" do
    first = AccountsFixtures.user_fixture()
    second = AccountsFixtures.user_fixture()

    first_ticket = issue_ticket!(first, 20_001, :password, nil, %{xp: 10})
    assert {:ok, first} = ClassicClaims.redeem(first_ticket, first, %{})

    same_classic = issue_ticket!(second, 20_001, :password, nil, %{xp: 20})

    assert {:error, {:already_claimed, :password}} =
             ClassicClaims.redeem(same_classic, second, %{})

    assert Repo.get!(User, second.id).classic_user_id == nil

    other_classic = issue_ticket!(first, 20_002, :password, nil, %{xp: 20})
    assert {:error, :user_already_claimed} = ClassicClaims.redeem(other_classic, first, %{})
    assert Repo.get!(User, first.id).classic_user_id == 20_001
  end

  test "already claimed errors name a sign-in method the owner actually has" do
    owner =
      %User{}
      |> User.social_registration_changeset(%{username: "apple_owner"})
      |> Repo.insert!()

    claimant = AccountsFixtures.user_fixture()
    owner_ticket = issue_ticket!(owner, 20_003, :apple, "owner-apple", %{xp: 10})
    assert {:ok, _owner} = ClassicClaims.redeem(owner_ticket, owner, %{})

    facebook_ticket = issue_ticket!(claimant, 20_003, :facebook, "claimant-facebook", %{xp: 10})

    assert {:error, {:already_claimed, :apple}} =
             ClassicClaims.redeem(facebook_ticket, claimant, %{})
  end

  test "a new ticket for the same pair cannot change heritage or overwrite a provider" do
    user = AccountsFixtures.user_fixture()
    first_ticket = issue_ticket!(user, 25_001, :apple, "original-sub", %{xp: 100})
    assert {:ok, claimed} = ClassicClaims.redeem(first_ticket, user, %{})

    {:ok, %{ticket: retry_ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 25_001,
        method: :password,
        user_id: user.id,
        legacy_data: %{classic_user_id: 999_999, xp: 900}
      })

    assert {:ok, retried} =
             ClassicClaims.redeem(retry_ticket, claimed, %{
               account: %{display_name: "Fuckface"}
             })

    assert retried.classic_claimed_at == claimed.classic_claimed_at
    assert retried.display_name == claimed.display_name

    profile = Repo.get_by!(PlayerProfile, user_id: user.id)
    assert profile.veteran_xp == 100
    assert profile.heritage_flags["classic_user_id"] == 25_001

    replacement = issue_ticket!(retried, 25_001, :apple, "replacement-sub", %{xp: 500})
    assert {:error, :provider_already_linked} = ClassicClaims.redeem(replacement, retried, %{})
    assert Repo.get!(User, user.id).apple_sub == "original-sub"
  end

  test "an import conflict rolls the link and provider identity back" do
    user = AccountsFixtures.user_fixture(%{display_name: "Original Player"})
    {:ok, _profile} = Profiles.import_legacy_progression(user, %{classic_user_id: 30_001, xp: 10})
    ticket = issue_ticket!(user, 30_002, :facebook, "facebook-subject", %{xp: 20})

    assert {:error, :user_already_claimed} =
             ClassicClaims.redeem(ticket, user, %{
               account: %{display_name: "Changed Player"}
             })

    persisted = Repo.get!(User, user.id)
    assert persisted.classic_user_id == nil
    assert persisted.facebook_id == nil
    assert persisted.display_name == "Original Player"

    profile = Repo.get_by!(PlayerProfile, user_id: user.id)
    assert profile.veteran_xp == 10
    assert profile.heritage_flags["classic_user_id"] == 30_001

    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 30_002).redeemed_by_id == nil
  end

  test "a fresh password claim creates one recoverable registered account" do
    ticket =
      issue_install_ticket!("fresh-password", 40_001, :password, nil, %{
        xp: 50,
        classic_username: "Fuckface",
        classic_name_allowed: false
      })

    params = %{
      install_id: "fresh-password",
      account: %{
        username: "returning_veteran",
        display_name: "Returning Veteran",
        email: "veteran@example.com",
        password: "password123"
      }
    }

    assert {:ok, created} = ClassicClaims.redeem(ticket, nil, params)
    refute created.guest
    assert created.display_name == "Returning Veteran"
    assert created.classic_user_id == 40_001
    assert {:ok, signed_in} = Auth.authenticate_user("veteran@example.com", "password123")
    assert signed_in.id == created.id

    assert {:ok, retried} = ClassicClaims.redeem(ticket, nil, params)
    assert retried.id == created.id
  end

  test "a fresh social claim binds repeat sign-in without inventing an email" do
    ticket =
      issue_install_ticket!("fresh-facebook", 50_001, :facebook, "facebook-subject", %{
        xp: 25,
        classic_username: "  Social   Veteran  ",
        classic_name_allowed: true
      })

    assert {:ok, created} =
             ClassicClaims.redeem(ticket, nil, %{
               install_id: "fresh-facebook",
               account: %{username: "social_veteran"}
             })

    refute created.guest
    assert created.display_name == "Social Veteran"
    assert created.email == nil
    assert created.facebook_id == "facebook-subject"

    assert Repo.get_by!(PlayerProfile, user_id: created.id).heritage_flags[
             "classic_username"
           ] == "  Social   Veteran  "

    assert {:ok, signed_in} =
             ProviderAuth.authenticate(:facebook, "valid-facebook-token", %{},
               provider_identity: ProviderIdentity
             )

    assert signed_in.id == created.id
  end

  test "a verified owner may take a reserved name and wins a colliding reservation" do
    assert {:ok, %{collisions: 1}} =
             ClassicNameReservations.import([
               %{id: 55_001, username: "Shared Veteran"},
               %{id: 55_002, username: " shared   veteran "}
             ])

    first_ticket =
      issue_install_ticket!("first-owner", 55_001, :password, nil, %{xp: 25})

    assert {:ok, first} =
             ClassicClaims.redeem(first_ticket, nil, %{
               install_id: "first-owner",
               account: %{
                 username: "SHARED VETERAN",
                 email: "first-owner@example.com",
                 password: "password123"
               }
             })

    assert first.classic_user_id == 55_001

    second_ticket =
      issue_install_ticket!("second-owner", 55_002, :password, nil, %{xp: 25})

    assert {:error, %Ecto.Changeset{} = changeset} =
             ClassicClaims.redeem(second_ticket, nil, %{
               install_id: "second-owner",
               account: %{
                 username: " shared   veteran ",
                 email: "second-owner@example.com",
                 password: "password123"
               }
             })

    assert %{
             username: [
               "This name belongs to a Classic player. Claim your Classic profile or choose another name."
             ]
           } = errors_on(changeset)

    refute Repo.get_by(User, email: "second-owner@example.com")

    assert {:ok, second} =
             ClassicClaims.redeem(second_ticket, nil, %{
               install_id: "second-owner",
               account: %{
                 username: "second_veteran",
                 display_name: "Second Veteran",
                 email: "second-owner@example.com",
                 password: "password123"
               }
             })

    assert second.classic_user_id == 55_002
    assert second.display_name == "Second Veteran"
  end

  test "expiry and binding failures leave the user untouched" do
    user = AccountsFixtures.user_fixture()

    {:ok, %{ticket: expired}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: 60_001,
        method: :password,
        user_id: user.id,
        legacy_data: %{xp: 100}
      })

    ClassicClaimTicket
    |> Repo.get_by!(classic_user_id: 60_001)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

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
