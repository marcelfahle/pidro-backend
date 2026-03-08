defmodule PidroServer.Repo.Migrations.AddPlayerResultsToGameStats do
  use Ecto.Migration

  def change do
    alter table(:game_stats) do
      add :player_results, :map
    end
  end
end
