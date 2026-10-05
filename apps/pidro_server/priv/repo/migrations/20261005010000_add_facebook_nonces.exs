defmodule PidroServer.Repo.Migrations.AddFacebookNonces do
  use Ecto.Migration

  def change do
    create table(:facebook_nonces, primary_key: false) do
      add :nonce_hash, :binary, primary_key: true
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:facebook_nonces, [:expires_at])
  end
end
