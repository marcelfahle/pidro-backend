defmodule Mix.Tasks.Pidro.ImportClassicNameReservations do
  @moduledoc """
  Imports a JSON array from the restricted Classic name export.

      mix pidro.import_classic_name_reservations path/to/classic-names.json

  Every object must contain `id`, `username`, and may contain the export's
  `inserted_at`. Existing Classic IDs are never changed.
  """

  use Mix.Task

  alias PidroServer.Accounts.ClassicNameReservations

  @shortdoc "Imports the fixed Classic player-name snapshot"

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    rows = path |> File.read!() |> Jason.decode!()

    unless is_list(rows) do
      Mix.raise("Expected a JSON array of Classic accounts.")
    end

    {:ok, result} = ClassicNameReservations.import(rows)
    cutoff = Application.fetch_env!(:pidro_server, ClassicNameReservations)[:cutoff_date]

    Mix.shell().info(
      "Classic name cutoff #{cutoff}: imported #{result.inserted}, kept #{result.existing} existing, " <>
        "found #{result.collisions} colliding key(s)."
    )
  end

  def run(_args), do: Mix.raise("Usage: mix pidro.import_classic_name_reservations PATH")
end
