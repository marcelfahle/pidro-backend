defmodule PidroServer.Repo.Migrations.CreateBotProfiles do
  use Ecto.Migration

  def up do
    create table(:bot_profiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :enabled, :boolean, null: false, default: true
      add :strategy, :string, null: false, default: "rulebook"
      add :portrait, :string, null: false, default: "marcel"
      add :image, :binary
      add :image_version, :string
      timestamps(type: :utc_datetime)
    end

    create constraint(:bot_profiles, :supported_strategy,
             check: "strategy IN ('rulebook', 'random')"
           )

    execute """
    INSERT INTO bot_profiles (id, name, portrait, inserted_at, updated_at)
    VALUES ('marcel', 'Marcel', 'marcel', NOW(), NOW()),
           ('antti', 'Antti', 'antti', NOW(), NOW()),
           ('jocke', 'Jocke', 'jocke', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING
    """
  end

  def down, do: drop(table(:bot_profiles))
end
