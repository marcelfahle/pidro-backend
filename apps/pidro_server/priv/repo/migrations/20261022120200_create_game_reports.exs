defmodule PidroServer.Repo.Migrations.CreateGameReports do
  use Ecto.Migration

  # Reserved diagnostics version; archive and bot catalogue migrate separately.
  def change do
    create table(:game_reports, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :room_code, :string, null: false
      add :game_instance_id, :string, null: false
      add :app_version, :string, null: false
      add :build, :string, null: false
      add :platform, :string, null: false
      add :events, {:array, :map}, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:game_reports, [:user_id, :inserted_at])
    create index(:game_reports, [:inserted_at])
    create index(:game_reports, [:game_instance_id])
  end
end
