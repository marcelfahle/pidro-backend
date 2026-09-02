defmodule PidroServer.Repo.Migrations.AddGuestPrereqsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :display_name, :string
      add :token_version, :integer, null: false, default: 0
      add :last_seen_at, :utc_datetime_usec
      add :install_id, :string
    end

    create index(:users, [:install_id], where: "install_id IS NOT NULL")
  end
end
