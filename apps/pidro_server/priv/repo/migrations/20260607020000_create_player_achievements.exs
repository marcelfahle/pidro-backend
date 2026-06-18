defmodule PidroServer.Repo.Migrations.CreatePlayerAchievements do
  use Ecto.Migration

  def change do
    create table(:player_achievements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Loose binary_id, NO FK — mirrors player_profiles / game_stats.player_ids.
      add :user_id, :binary_id, null: false
      add :achievement_key, :string, null: false
      add :tier, :integer, null: false, default: 1
      add :awarded_at, :utc_datetime_usec, null: false
      # Optional evidence (e.g. the score margin / streak length at award time).
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One permanent row per (user, achievement). The unique index makes
    # on_conflict: :nothing absorb re-evaluation (a later game, or a rebuild).
    create unique_index(:player_achievements, [:user_id, :achievement_key])
    create index(:player_achievements, [:user_id])
  end
end
