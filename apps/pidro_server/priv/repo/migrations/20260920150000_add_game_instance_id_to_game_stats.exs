defmodule PidroServer.Repo.Migrations.AddGameInstanceIdToGameStats do
  use Ecto.Migration

  # A room can host more than one game (rematch) and room codes are reused
  # once a room closes, so `room_code` cannot identify a finished game. The
  # engine's per-process instance id can. Rows saved before this column stay
  # NULL, which the unique index ignores.
  def change do
    alter table(:game_stats) do
      add :game_instance_id, :string
    end

    create unique_index(:game_stats, [:game_instance_id])
  end
end
