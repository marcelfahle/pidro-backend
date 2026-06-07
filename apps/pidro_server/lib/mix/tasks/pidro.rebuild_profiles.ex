defmodule Mix.Tasks.Pidro.RebuildProfiles do
  @moduledoc """
  Rebuilds every player profile's lifetime counters from `game_stats` history.

  Idempotent repair task: recomputes `games_played`, `wins`, and `losses` for
  every user appearing in `game_stats.player_ids` and overwrites the stored
  counters. Use it to correct any drift in the incrementally-maintained rollup.

      mix pidro.rebuild_profiles
  """
  use Mix.Task

  @shortdoc "Rebuilds all player profiles from game_stats history"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, count} = PidroServer.Profiles.rebuild_all()

    Mix.shell().info("Rebuilt #{count} player profile(s) from game_stats history.")
  end
end
