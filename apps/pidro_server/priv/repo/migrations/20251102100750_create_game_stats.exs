defmodule PidroServer.Repo.Migrations.CreateGameStats do
  use Ecto.Migration

  def change do
    create table(:game_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_code, :string, null: false
      add :winner, :string
      add :final_scores, :map
      add :bid_amount, :integer
      add :bid_team, :string
      add :duration_seconds, :integer
      add :completed_at, :utc_datetime
      add :player_ids, {:array, :binary_id}

      timestamps()
    end

    create index(:game_stats, [:completed_at])
    create index(:game_stats, [:player_ids], using: "GIN")
    create index(:game_stats, [:room_code])
  end
end
