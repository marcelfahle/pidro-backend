defmodule PidroServer.Repo.Migrations.CreateEmailTemplates do
  use Ecto.Migration

  def change do
    create table(:email_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :subject, :string, null: false
      add :preview_text, :string
      add :from_name, :string
      add :from_email, :string
      add :reply_to, :string
      add :html_body, :text, null: false
      add :variables, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_templates, [:kind])
    create index(:email_templates, [:updated_at])
  end
end
