defmodule Mix.Tasks.Pidro.ImportClassicNameReservations do
  @moduledoc """
  Imports a JSON array from the restricted Classic name export.

      mix pidro.import_classic_name_reservations path/to/classic-names.json

  Every object must contain `id`, `username`, and may contain the export's
  `inserted_at`. Existing Classic IDs are never changed. In production, where
  Mix is unavailable, run `PidroServer.Release.import_classic_name_reservations/1`.
  """

  use Mix.Task

  alias PidroServer.Accounts.ClassicNameReservations

  @shortdoc "Imports the fixed Classic player-name snapshot"

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    path
    |> ClassicNameReservations.import_file()
    |> ClassicNameReservations.import_summary()
    |> Mix.shell().info()
  end

  def run(_args), do: Mix.raise("Usage: mix pidro.import_classic_name_reservations PATH")
end
