defmodule PidroServer.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks, primary_key: false) do
      add :user_id, :binary_id, null: false
      add :blocked_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:blocks, [:user_id, :blocked_id])
    create index(:blocks, [:blocked_id])
    create constraint(:blocks, :cannot_block_self, check: "user_id <> blocked_id")
  end
end
