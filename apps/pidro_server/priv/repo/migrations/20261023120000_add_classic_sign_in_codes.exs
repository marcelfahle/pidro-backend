defmodule PidroServer.Repo.Migrations.AddClassicSignInCodes do
  use Ecto.Migration

  def change do
    create table(:classic_sign_in_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :classic_user_id, :bigint, null: false
      add :code_hash, :binary, null: false
      add :install_id, :string, size: 64
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:classic_sign_in_codes, [:classic_user_id])
    create index(:classic_sign_in_codes, [:user_id])

    create constraint(:classic_sign_in_codes, :classic_code_has_one_binding,
             check:
               "(user_id IS NOT NULL AND install_id IS NULL) OR " <>
                 "(user_id IS NULL AND install_id IS NOT NULL)"
           )
  end
end
