defmodule PidroServer.Repo.Migrations.CreateGameArchives do
  use Ecto.Migration

  def change do
    create table(:game_archives, primary_key: false) do
      add :game_instance_id, :text, primary_key: true
      add :room_code, :text, null: false
      add :format_version, :integer, null: false
      add :versions, :map, null: false
      add :participants, :map, null: false
      add :user_ids, {:array, :text}, null: false, default: []
      add :participation_truncated, :boolean, null: false, default: false
      add :status, :text, null: false
      add :termination_reason, :text
      add :evidence_status, :text, null: false
      add :failed_checkpoints, :integer, null: false, default: 0
      add :missing_revision_count, :bigint, null: false, default: 0
      add :last_revision, :bigint, null: false
      add :initial_snapshot, :map, null: false
      add :initial_deal, :map
      add :last_snapshot, :map, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :saved_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create index(:game_archives, [:started_at, :game_instance_id])
    create index(:game_archives, [:room_code, :started_at])
    create index(:game_archives, [:status, :game_instance_id])
    create index(:game_archives, [:ended_at])
    create index(:game_archives, [:user_ids], using: :gin)

    create table(:game_archive_events, primary_key: false) do
      add :game_instance_id,
          references(:game_archives,
            column: :game_instance_id,
            type: :text,
            on_delete: :delete_all
          ),
          primary_key: true

      add :revision, :bigint, primary_key: true
      add :occurred_at, :utc_datetime_usec, null: false
      add :saved_at, :utc_datetime_usec, null: false
      add :payload, :map, null: false
      add :snapshot, :map, null: false
    end

    create constraint(:game_archives, :archive_status,
             check: "status IN ('active', 'complete', 'closed', 'interrupted')"
           )
  end
end
