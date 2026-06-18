defmodule Mix.Tasks.Pidro.Rerate do
  @moduledoc """
  Recomputes player ratings by replaying `game_stats` history.

  This is the rating replay job (PID-46) — distinct from
  `mix pidro.rebuild_profiles`, which repairs the order-agnostic lifetime
  counters. Ratings are path-dependent, so this replays games in a fixed total
  order through the shared per-game rating step.

      mix pidro.rerate --all          # wipe + recompute every rating from history
      mix pidro.rerate --incremental  # apply only games since the last run

  Exactly one of `--all` / `--incremental` is required. `--all` is destructive
  (it wipes every rating to the default before replaying), so neither flag
  defaults — you must pick one explicitly.
  """
  use Mix.Task

  @shortdoc "Replays game_stats history to (re)compute player ratings"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [all: :boolean, incremental: :boolean])

    Mix.Task.run("app.start")

    case {opts[:all], opts[:incremental]} do
      {true, true} ->
        usage("Pass exactly one of --all or --incremental, not both.")

      {true, _} ->
        {:ok, %{profiles: profiles, games: games}} = PidroServer.Profiles.rerate_all()

        Mix.shell().info(
          "Rerated #{profiles} profile(s) from #{games} rated game(s) (full rebuild)."
        )

      {_, true} ->
        {:ok, %{games: games}} = PidroServer.Profiles.rerate_incremental()

        Mix.shell().info("Applied #{games} new rated game(s) incrementally.")

      _ ->
        usage("Pass exactly one of --all or --incremental.")
    end
  end

  defp usage(message) do
    Mix.shell().error(message)
    Mix.shell().info("Usage: mix pidro.rerate --all | --incremental")
    exit({:shutdown, 1})
  end
end
