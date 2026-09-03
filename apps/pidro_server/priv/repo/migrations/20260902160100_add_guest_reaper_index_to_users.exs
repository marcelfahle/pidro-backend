defmodule PidroServer.Repo.Migrations.AddGuestReaperIndexToUsers do
  use Ecto.Migration

  def change do
    # Match the reaper's predicate and ordering, including guests that have
    # never been seen. Registered accounts never qualify.
    create index(:users, ["COALESCE(last_seen_at, inserted_at)", :id],
             where: "guest = true",
             name: :users_guest_reaper_index
           )
  end
end
