defmodule PidroServer.Repo.Migrations.CreateFriendIgnores do
  use Ecto.Migration

  # An ignore outlives the request it hid, so a cancelled and resent request
  # stays hidden. `friendships.ignored_at` stays for servers still running
  # during a deploy and is no longer read.
  def up do
    create table(:friend_ignores, primary_key: false) do
      add :user_id, :binary_id, null: false
      add :ignored_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:friend_ignores, [:user_id, :ignored_id])
    create constraint(:friend_ignores, :cannot_ignore_self, check: "user_id <> ignored_id")

    execute """
    INSERT INTO friend_ignores (user_id, ignored_id, inserted_at)
    SELECT friend_id, user_id, ignored_at FROM friendships WHERE ignored_at IS NOT NULL
    """
  end

  def down do
    drop table(:friend_ignores)
  end
end
