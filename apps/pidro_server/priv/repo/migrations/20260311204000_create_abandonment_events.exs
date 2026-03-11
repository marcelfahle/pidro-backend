defmodule PidroServer.Repo.Migrations.CreateAbandonmentEvents do
  use Ecto.Migration

  def change do
    create table(:abandonment_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :room_code, :string, null: false
      add :position, :string, null: false

      timestamps(updated_at: false)
    end

    create index(:abandonment_events, [:user_id])
    create index(:abandonment_events, [:room_code])
    create unique_index(:abandonment_events, [:user_id, :room_code])
  end
end
