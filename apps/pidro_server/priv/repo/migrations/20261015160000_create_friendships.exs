defmodule PidroServer.Repo.Migrations.CreateFriendships do
  use Ecto.Migration

  def change do
    create table(:friendships, primary_key: false) do
      add :user_id, :binary_id, null: false
      add :friend_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:friendships, [:user_id, :friend_id])
    create index(:friendships, [:friend_id])
    create constraint(:friendships, :cannot_friend_self, check: "user_id <> friend_id")
  end
end
