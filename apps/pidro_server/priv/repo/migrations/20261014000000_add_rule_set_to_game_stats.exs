defmodule PidroServer.Repo.Migrations.AddRuleSetToGameStats do
  use Ecto.Migration

  def change do
    alter table(:game_stats) do
      add :rule_set, :string, null: false, default: "finnish"
    end
  end
end
