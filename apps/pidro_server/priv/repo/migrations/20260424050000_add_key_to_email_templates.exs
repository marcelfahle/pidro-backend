defmodule PidroServer.Repo.Migrations.AddKeyToEmailTemplates do
  use Ecto.Migration

  def up do
    alter table(:email_templates) do
      add :key, :string
    end

    execute """
    UPDATE email_templates
    SET key = substring(
      lower(
        trim(both '_' from regexp_replace(kind || '_' || coalesce(name, 'email') || '_' || substring(id::text, 1, 8), '[^a-zA-Z0-9]+', '_', 'g'))
      ) from 1 for 80
    )
    WHERE key IS NULL
    """

    alter table(:email_templates) do
      modify :key, :string, null: false
    end

    create unique_index(:email_templates, [:kind, :key])
  end

  def down do
    drop index(:email_templates, [:kind, :key])

    alter table(:email_templates) do
      remove :key
    end
  end
end
