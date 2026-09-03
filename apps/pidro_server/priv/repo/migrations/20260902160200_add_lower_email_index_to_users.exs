defmodule PidroServer.Repo.Migrations.AddLowerEmailIndexToUsers do
  use Ecto.Migration

  def up do
    # Choosing a winner between two existing accounts is a product decision,
    # so fail closed with a useful remediation instead of silently merging
    # identities during deployment.
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM users
        WHERE email IS NOT NULL
        GROUP BY lower(email)
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'users contain case-insensitive email duplicates; resolve them before retrying this migration';
      END IF;
    END
    $$;
    """

    # Upgrade, registration and login all treat email case-insensitively. The
    # unique expression index is the final guard for concurrent writes.
    create unique_index(:users, ["lower(email)"], name: :users_lower_email_index)
  end

  def down do
    drop_if_exists index(:users, ["lower(email)"], name: :users_lower_email_index)
  end
end
