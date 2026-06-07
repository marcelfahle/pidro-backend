defmodule PidroServer.Repo.Migrations.CreatePlayerProfiles do
  use Ecto.Migration

  def change do
    create table(:player_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false

      add :games_played, :integer, null: false, default: 0
      add :wins, :integer, null: false, default: 0
      add :losses, :integer, null: false, default: 0

      add :rating_mu, :float, null: false, default: 25.0
      add :rating_sigma, :float, null: false, default: 8.333
      add :rating_games_count, :integer, null: false, default: 0

      add :veteran_level, :integer, null: false, default: 0
      add :veteran_xp, :integer, null: false, default: 0

      add :playstyle_bidding_wins, :integer, null: false, default: 0
      add :playstyle_bidding_attempts, :integer, null: false, default: 0
      add :avg_winning_bid_sum, :integer, null: false, default: 0
      add :avg_winning_bid_count, :integer, null: false, default: 0

      add :heritage_flags, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:player_profiles, [:user_id])
  end
end
