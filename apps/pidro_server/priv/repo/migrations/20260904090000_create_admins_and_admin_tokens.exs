defmodule PidroServer.Repo.Migrations.CreateAdminsAndAdminTokens do
  use Ecto.Migration

  def change do
    create table(:admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :hashed_password, :string, null: false
      add :force_password_change, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admins, ["lower(email)"], name: :admins_lower_email_index)

    create table(:admin_tokens, primary_key: false) do
      add :token, :binary, primary_key: true
      add :context, :string, null: false
      add :last_used_at, :utc_datetime_usec, null: false

      add :admin_id, references(:admins, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:admin_tokens, [:admin_id])
  end
end
