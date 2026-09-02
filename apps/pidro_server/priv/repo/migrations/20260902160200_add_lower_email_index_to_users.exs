defmodule PidroServer.Repo.Migrations.AddLowerEmailIndexToUsers do
  use Ecto.Migration

  def change do
    # Upgrade and login pre-checks compare email case-insensitively.
    create index(:users, ["lower(email)"], name: :users_lower_email_index)
  end
end
