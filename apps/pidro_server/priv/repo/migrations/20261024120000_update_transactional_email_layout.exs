defmodule PidroServer.Repo.Migrations.UpdateTransactionalEmailLayout do
  use Ecto.Migration

  @external_resource Path.expand("../transactional_email_templates.sql", __DIR__)
  @sql File.read!(@external_resource)

  def up, do: execute(@sql)

  # Mail content belongs to the admin; rolling code back must not overwrite it.
  def down, do: :ok
end
