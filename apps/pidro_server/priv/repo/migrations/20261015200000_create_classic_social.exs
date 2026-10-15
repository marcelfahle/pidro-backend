defmodule PidroServer.Repo.Migrations.CreateClassicSocial do
  use Ecto.Migration

  def change do
    create table(:classic_friendships, primary_key: false) do
      add :classic_user_id, :bigint, null: false
      add :classic_friend_id, :bigint, null: false
    end

    create unique_index(:classic_friendships, [:classic_user_id, :classic_friend_id])
    create index(:classic_friendships, [:classic_friend_id])

    create table(:classic_blocks, primary_key: false) do
      add :classic_user_id, :bigint, null: false
      add :classic_blocked_id, :bigint, null: false
    end

    create unique_index(:classic_blocks, [:classic_user_id, :classic_blocked_id])
    create index(:classic_blocks, [:classic_blocked_id])
  end
end
