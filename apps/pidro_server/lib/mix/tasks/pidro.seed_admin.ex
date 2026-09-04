defmodule Mix.Tasks.Pidro.SeedAdmin do
  @moduledoc """
  Creates the first admin using `ADMIN_EMAIL` and password `changeme123`.

      ADMIN_EMAIL=operator@example.com mix pidro.seed_admin

  The task is idempotent: once any admin exists, it makes no changes.
  """

  use Mix.Task

  @shortdoc "Creates the first ops-panel admin if none exists"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case PidroServer.Admins.seed_first_admin() do
      {:ok, :already_seeded} ->
        Mix.shell().info("An admin already exists; no changes made.")

      {:ok, admin} ->
        Mix.shell().info(
          "Created #{admin.email} with temporary password changeme123. Change it at first login."
        )

      {:error, :admin_seed_email_missing} ->
        Mix.raise("Set ADMIN_EMAIL before running mix pidro.seed_admin.")

      {:error, changeset} ->
        Mix.raise("Could not create the first admin: #{inspect(changeset.errors)}")
    end
  end
end
