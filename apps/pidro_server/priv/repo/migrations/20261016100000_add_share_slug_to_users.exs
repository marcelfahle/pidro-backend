defmodule PidroServer.Repo.Migrations.AddShareSlugToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :share_slug, :string
    end

    create unique_index(:users, [:share_slug])

    flush()
    PidroServer.Accounts.backfill_share_slugs(repo())
  end

  def down do
    drop index(:users, [:share_slug])

    alter table(:users) do
      remove :share_slug
    end
  end
end
