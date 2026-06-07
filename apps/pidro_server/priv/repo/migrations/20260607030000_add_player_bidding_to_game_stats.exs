defmodule PidroServer.Repo.Migrations.AddPlayerBiddingToGameStats do
  use Ecto.Migration

  def change do
    alter table(:game_stats) do
      add :player_bidding, :map
    end
  end
end
