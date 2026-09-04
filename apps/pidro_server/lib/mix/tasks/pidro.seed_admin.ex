defmodule Mix.Tasks.Pidro.SeedAdmin do
  @moduledoc """
  Creates the first admin using `ADMIN_EMAIL` and a generated temporary password.

      ADMIN_EMAIL=operator@example.com mix pidro.seed_admin

  The password is displayed once in the invoking terminal. The task is
  idempotent: once any admin exists, it makes no changes.
  """

  use Mix.Task

  @shortdoc "Creates the first ops-panel admin if none exists"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case PidroServer.Admins.seed_first_admin() do
      {:ok, :already_seeded} ->
        Mix.shell().info("An admin already exists; no changes made.")

      {:ok, admin, temporary_password} ->
        Mix.shell().info("Created #{admin.email}.")
        Mix.shell().info("Temporary password (shown once): #{temporary_password}")
        Mix.shell().info("Change it immediately at first login.")

      {:error, :admin_seed_email_missing} ->
        Mix.raise("Set ADMIN_EMAIL before running mix pidro.seed_admin.")

      {:error, changeset} ->
        Mix.raise("Could not create the first admin: #{inspect(changeset.errors)}")
    end
  end
end
