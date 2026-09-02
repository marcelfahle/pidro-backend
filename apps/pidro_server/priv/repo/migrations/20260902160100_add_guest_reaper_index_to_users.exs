defmodule PidroServer.Repo.Migrations.AddGuestReaperIndexToUsers do
  use Ecto.Migration

  def change do
    # The guest reaper sweeps stale guests by last_seen_at; registered accounts
    # never qualify, so the index covers guest rows only.
    create index(:users, [:last_seen_at], where: "guest = true")
  end
end
