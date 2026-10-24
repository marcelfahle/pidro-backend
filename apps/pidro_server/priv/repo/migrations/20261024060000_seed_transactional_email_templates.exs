defmodule PidroServer.Repo.Migrations.SeedTransactionalEmailTemplates do
  use Ecto.Migration

  @external_resource Path.expand("../transactional_email_templates_v1.sql", __DIR__)
  @sql File.read!(@external_resource)

  def up, do: execute(@sql)

  # An existing or edited template belongs to the admin, including on rollback.
  def down, do: :ok
end
