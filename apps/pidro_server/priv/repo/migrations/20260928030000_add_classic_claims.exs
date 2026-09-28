defmodule PidroServer.Repo.Migrations.AddClassicClaims do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :classic_user_id, :bigint
      add :classic_claimed_at, :utc_datetime_usec
      add :apple_sub, :string
      add :facebook_id, :string
    end

    create unique_index(:users, [:classic_user_id])
    create unique_index(:users, [:apple_sub])
    create unique_index(:users, [:facebook_id])

    create constraint(:users, :classic_link_is_complete,
             check:
               "(classic_user_id IS NULL AND classic_claimed_at IS NULL) OR " <>
                 "(classic_user_id IS NOT NULL AND classic_claimed_at IS NOT NULL)"
           )

    create table(:classic_claim_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false
      add :classic_user_id, :bigint, null: false
      add :method, :string, null: false
      add :provider_id, :string
      add :legacy_data, :map, null: false
      add :bound_user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :install_id, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :redeemed_by_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :redeemed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:classic_claim_tickets, [:token_hash])
    create index(:classic_claim_tickets, [:classic_user_id])

    create constraint(:classic_claim_tickets, :claim_ticket_has_one_binding,
             check:
               "(bound_user_id IS NOT NULL AND install_id IS NULL) OR " <>
                 "(bound_user_id IS NULL AND install_id IS NOT NULL)"
           )

    create constraint(:classic_claim_tickets, :claim_ticket_redemption_is_complete,
             check:
               "(redeemed_by_id IS NULL AND redeemed_at IS NULL) OR " <>
                 "(redeemed_by_id IS NOT NULL AND redeemed_at IS NOT NULL)"
           )

    create constraint(:classic_claim_tickets, :claim_ticket_method_is_valid,
             check: "method IN ('password', 'apple', 'facebook')"
           )

    create constraint(:classic_claim_tickets, :claim_ticket_provider_matches_method,
             check:
               "(method = 'password' AND provider_id IS NULL) OR " <>
                 "(method IN ('apple', 'facebook') AND provider_id IS NOT NULL)"
           )
  end
end
