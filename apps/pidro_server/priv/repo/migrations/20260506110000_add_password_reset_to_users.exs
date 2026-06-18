defmodule PidroServer.Repo.Migrations.AddPasswordResetToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :password_reset_token_hash, :binary
      add :password_reset_sent_at, :utc_datetime_usec
    end

    create unique_index(:users, [:password_reset_token_hash],
             where: "password_reset_token_hash IS NOT NULL"
           )
  end
end
