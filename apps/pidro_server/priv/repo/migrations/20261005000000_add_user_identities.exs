defmodule PidroServer.Repo.Migrations.AddUserIdentities do
  use Ecto.Migration

  def up do
    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :subject, :string, null: false
      add :issuer_app, :string
      add :email, :string
      add :email_is_relay, :boolean, null: false, default: false
      add :business_ids, {:array, :string}
      add :link_source, :string, null: false
      add :linked_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec, null: false
    end

    create unique_index(:user_identities, [:provider, :subject])
    create index(:user_identities, [:user_id])

    create constraint(:user_identities, :user_identity_provider_is_valid,
             check: "provider IN ('apple', 'facebook')"
           )

    create constraint(:user_identities, :user_identity_link_source_is_valid,
             check: "link_source IN ('sign_up', 'sign_in', 'claim', 'backfill')"
           )

    alter table(:users) do
      add :classic_claim_method, :string
      add :classic_matched_on, :string
    end

    alter table(:classic_claim_tickets) do
      add :matched_on, :string
      add :provider_issuer_app, :string
      add :provider_email, :string
      add :provider_email_is_relay, :boolean, null: false, default: false
      add :provider_business_ids, {:array, :string}
    end

    create constraint(:users, :classic_claim_method_is_valid,
             check:
               "classic_claim_method IS NULL OR classic_claim_method IN ('password', 'apple', 'facebook')"
           )

    create constraint(:users, :classic_matched_on_is_valid,
             check:
               "classic_matched_on IS NULL OR classic_matched_on IN " <>
                 "('password', 'email', 'facebook_id', 'facebook_business_id')"
           )

    create constraint(:classic_claim_tickets, :claim_ticket_matched_on_is_valid,
             check:
               "matched_on IS NULL OR matched_on IN " <>
                 "('password', 'email', 'facebook_id', 'facebook_business_id')"
           )

    execute("""
    INSERT INTO user_identities
      (id, user_id, provider, subject, email_is_relay, link_source, linked_at, last_used_at)
    SELECT gen_random_uuid(), id, 'apple', apple_sub, false, 'backfill', inserted_at, inserted_at
    FROM users
    WHERE apple_sub IS NOT NULL
    """)

    execute("""
    INSERT INTO user_identities
      (id, user_id, provider, subject, email_is_relay, link_source, linked_at, last_used_at)
    SELECT gen_random_uuid(), id, 'facebook', facebook_id, false, 'backfill', inserted_at, inserted_at
    FROM users
    WHERE facebook_id IS NOT NULL
    """)
  end

  def down do
    alter table(:classic_claim_tickets) do
      remove :provider_business_ids
      remove :provider_email_is_relay
      remove :provider_email
      remove :provider_issuer_app
      remove :matched_on
    end

    alter table(:users) do
      remove :classic_matched_on
      remove :classic_claim_method
    end

    drop table(:user_identities)
  end
end
