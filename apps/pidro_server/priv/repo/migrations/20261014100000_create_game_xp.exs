defmodule PidroServer.Repo.Migrations.CreateGameXp do
  use Ecto.Migration

  def change do
    create table(:game_xp, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Loose binary_id, NO FK, like player_profiles; account deletion removes
      # the rows with the user's other personal rows.
      add :user_id, :binary_id, null: false

      add :game_stats_id, references(:game_stats, type: :binary_id, on_delete: :delete_all),
        null: false

      add :xp, :integer, null: false
      add :earned_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A game counts once per player.
    create unique_index(:game_xp, [:user_id, :game_stats_id])
    # "This user's XP since this time" (week, month, later leagues).
    create index(:game_xp, [:user_id, :earned_at])
  end
end
