defmodule PidroServer.Repo.Migrations.AddIgnoredAtToFriendships do
  use Ecto.Migration

  def change do
    alter table(:friendships) do
      add :ignored_at, :utc_datetime_usec
    end
  end
end
