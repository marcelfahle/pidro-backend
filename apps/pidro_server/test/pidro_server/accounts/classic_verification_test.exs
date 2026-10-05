defmodule PidroServer.Accounts.ClassicVerificationTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Accounts.{ClassicClaimTicket, ClassicVerification}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  defmodule Classic do
    @behaviour PidroServer.Accounts.ClassicClient

    @impl true
    def verify_password("veteran@example.com", "correct-password"), do: {:ok, profile()}

    def verify_password("disjoint-counters", "correct-password") do
      {:ok, Map.merge(profile(), %{"played_games" => 100, "total_game" => 20})}
    end

    def verify_password("blocked-name", "correct-password") do
      {:ok, Map.put(profile(), "username", "  Fuckface  ")}
    end

    # A pre-2017 veteran exactly as Classic's live endpoint describes one,
    # passed through the real client's normalizer.
    def verify_password("bengt@example.com", "correct-password") do
      {:ok,
       PidroServer.Accounts.ClassicClient.normalize(%{
         "id" => 50,
         "username" => nil,
         "first_name" => "Bengt",
         "email" => "bengt@example.com",
         "member_since" => "2014-03-02T10:00:00",
         "level" => 1,
         "xp" => 0,
         "games" => %{
           "legacy_played_games" => 1862,
           "legacy_victories" => 937,
           "legacy_losses" => 925,
           "total_game" => 0,
           "win_game" => 0,
           "lost_game" => 0,
           "games_logged" => 0,
           "games_started" => 0,
           "games_ended" => 0
         },
         "premium" => %{"active" => false, "until" => nil},
         "badges" => []
       })}
    end

    def verify_password(_login, _password), do: {:error, :invalid_credentials}

    @impl true
    def lookup(:email, "apple@example.com"), do: {:ok, profile()}
    def lookup(:fbid, "current-app-id"), do: {:error, :not_found}
    def lookup(:fbid, "direct-current-app-id"), do: {:ok, profile()}
    def lookup(:fbid, "old-app-id"), do: {:ok, profile()}
    def lookup(:email, "facebook@example.com"), do: {:ok, profile()}
    def lookup(:email, "ambiguous@example.com"), do: {:error, :ambiguous}

    def lookup(:email, "deleted@example.com"),
      do: {:ok, Map.put(profile(), "account_deleted", true)}

    def lookup(:email, "sparse@example.com"), do: {:ok, %{"id" => 98_765}}
    def lookup(_field, _value), do: {:error, :not_found}

    defp profile do
      %{
        "id" => 12_345,
        "username" => "",
        "firstname" => "Old Timer",
        "inserted_at" => "2012-04-03T00:00:00Z",
        "xp" => 800_000,
        "level" => 87,
        "played_games" => 40,
        "victories" => 21,
        "losses" => 19,
        "total_game" => 321,
        "win_game" => 200,
        "lost_game" => 121,
        "xpoints_count" => 250,
        "started" => 300,
        "ended" => 290,
        "badges" => ["Veteran"]
      }
    end
  end

  defmodule Providers do
    def apple("apple-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "aud" => "com.oneapps.pidro",
           "email" => "apple@example.com",
           "email_verified" => "true"
         }}

    def apple("unverified-apple-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "email" => "apple@example.com",
           "email_verified" => false
         }}

    def apple("missing-verification-apple-token"),
      do: {:ok, %{"sub" => "apple-subject", "email" => "apple@example.com"}}

    def apple("sparse-profile-token"),
      do:
        {:ok,
         %{
           "sub" => "apple-subject",
           "email" => "sparse@example.com",
           "email_verified" => true
         }}

    def apple(_token), do: {:error, :invalid_credentials}

    def facebook("facebook-token") do
      {:ok, %{subject: "current-app-id", issuer_app: "facebook-app", email: nil}}
    end

    def facebook("direct-facebook-token") do
      {:ok, %{subject: "direct-current-app-id", issuer_app: "facebook-app", email: nil}}
    end

    def facebook("email-facebook-token") do
      {:ok,
       %{
         subject: "email-current-app-id",
         issuer_app: "facebook-app",
         email: "facebook@example.com"
       }}
    end

    def facebook(_token), do: {:error, :invalid_credentials}

    def facebook_limited("limited-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "facebook@example.com"
       }}
    end

    def facebook_limited("ambiguous-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "ambiguous@example.com"
       }}
    end

    def facebook_limited("deleted-token", "limited-nonce") do
      {:ok,
       %{
         subject: "limited-current-app-id",
         issuer_app: "facebook-app",
         email: "deleted@example.com"
       }}
    end

    def facebook_business_ids("facebook-token"), do: {:ok, ["old-app-id"]}
    def facebook_business_ids("direct-facebook-token"), do: {:ok, ["unused-old-app-id"]}
    def facebook_business_ids("email-facebook-token"), do: {:ok, []}
  end

  test "a real Classic payload for a no-username veteran previews name and old games" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "bengt@example.com",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.name == "Bengt"
    assert result.classic.games_played == 1862
    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 50).bound_user_id == user.id
  end

  test "password verification accepts an email login and binds the authenticated user" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "veteran@example.com",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic == %{
             name: "Old Timer",
             games_played: 321,
             level: 87,
             member_since: "2012-04-03T00:00:00Z",
             name_allowed: true
           }

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.bound_user_id == user.id
    assert ticket.install_id == nil
    assert ticket.method == :password
    assert ticket.matched_on == :password
    assert ticket.legacy_data["classic_username"] == "Old Timer"
    assert ticket.legacy_data["classic_name_allowed"] == true
    assert ticket.legacy_data["games_played_counter"] == 321
  end

  test "a blocked Classic name is preserved privately and marked unavailable" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "blocked-name",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.name == "  Fuckface  "
    assert result.classic.name_allowed == false

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.legacy_data["classic_username"] == "  Fuckface  "
    assert ticket.legacy_data["classic_name_allowed"] == false
  end

  test "preview uses the same disjoint-era game count as the claimed profile" do
    user = AccountsFixtures.guest_fixture()

    assert {:ok, result} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "disjoint-counters",
                 "password" => "correct-password"
               },
               user,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert result.classic.games_played == 120
  end

  test "Apple proof resolves Classic by email but stores only the stable subject" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "apple-token",
                 "install_id" => "apple-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.install_id == "apple-install"
    assert ticket.method == :apple
    assert ticket.matched_on == :email
    assert ticket.provider_id == "apple-subject"
    assert ticket.provider_issuer_app == "com.oneapps.pidro"
    assert ticket.provider_email == "apple@example.com"
    refute inspect(ticket.legacy_data) =~ "apple@example.com"
  end

  test "Facebook checks every business-scoped id and keeps the current app id" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.method == :facebook
    assert ticket.matched_on == :facebook_business_id
    assert ticket.provider_id == "current-app-id"
  end

  test "Facebook records a match on the current app id" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "direct-facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.matched_on == :facebook_id
  end

  test "Facebook falls back to verified email" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "access_token" => "email-facebook-token",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345).matched_on == :email
  end

  test "Facebook Limited Login verifies a Classic claim by email" do
    assert {:ok, _result} =
             ClassicVerification.verify(
               %{
                 "method" => "facebook",
                 "authentication_token" => "limited-token",
                 "nonce" => "limited-nonce",
                 "install_id" => "facebook-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    ticket = Repo.get_by!(ClassicClaimTicket, classic_user_id: 12_345)
    assert ticket.provider_id == "limited-current-app-id"
    assert ticket.provider_business_ids == []
    assert ticket.matched_on == :email
  end

  test "ambiguous or deleted Facebook emails are not a Classic match" do
    for token <- ["ambiguous-token", "deleted-token"] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(
                 %{
                   "method" => "facebook",
                   "authentication_token" => token,
                   "nonce" => "limited-nonce",
                   "install_id" => "facebook-install"
                 },
                 nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "Facebook requires exactly one credential shape" do
    for params <- [
          %{"method" => "facebook", "install_id" => "facebook-install"},
          %{
            "method" => "facebook",
            "access_token" => "facebook-token",
            "authentication_token" => "limited-token",
            "nonce" => "limited-nonce",
            "install_id" => "facebook-install"
          }
        ] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(params, nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end
  end

  test "Apple email must be verified before it can select a Classic account" do
    for token <- ["unverified-apple-token", "missing-verification-apple-token"] do
      assert {:error, :invalid_credentials} =
               ClassicVerification.verify(
                 %{
                   "method" => "apple",
                   "identity_token" => token,
                   "install_id" => "apple-install"
                 },
                 nil,
                 classic_client: Classic,
                 provider_identity: Providers
               )
    end

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "a malformed Classic profile cannot issue a schema-invalid ticket" do
    assert {:error, :provider_unavailable} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "sparse-profile-token",
                 "install_id" => "apple-install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end

  test "invalid proof and an unbound fresh install issue no ticket" do
    assert {:error, :invalid_credentials} =
             ClassicVerification.verify(
               %{
                 "method" => "password",
                 "login" => "veteran@example.com",
                 "password" => "wrong",
                 "install_id" => "install"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert {:error, :claim_binding_required} =
             ClassicVerification.verify(
               %{
                 "method" => "apple",
                 "identity_token" => "apple-token"
               },
               nil,
               classic_client: Classic,
               provider_identity: Providers
             )

    assert Repo.aggregate(ClassicClaimTicket, :count) == 0
  end
end
