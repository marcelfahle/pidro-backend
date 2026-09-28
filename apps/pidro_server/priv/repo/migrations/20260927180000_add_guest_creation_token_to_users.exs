defmodule PidroServer.Repo.Migrations.AddGuestCreationTokenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :guest_creation_token_hash, :binary
    end

    create unique_index(:users, [:guest_creation_token_hash],
             where: "guest_creation_token_hash IS NOT NULL"
           )
  end
end
