defmodule Mix.Tasks.Pidro.Selfplay do
  @moduledoc """
  Plays seeded games between two bot teams and prints how each team did.

      mix pidro.selfplay                          # 2000 games, seed 1, rulebook vs random
      mix pidro.selfplay --games 500 --seed 7
      mix pidro.selfplay --a rulebook --b rulebook

  Team A alternates between North/South and East/West. The summary reports
  win rate, bids made and set, average bid, decision times, and any illegal
  move, crash, stall or capped game. The task exits non-zero if a game did not
  finish cleanly. Needs no database.
  """
  use Mix.Task

  alias Pidro.Bot.SelfPlay

  @shortdoc "Plays seeded bot-vs-bot games and prints a summary"

  @policies ~w(rulebook random)

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args, strict: [games: :integer, seed: :integer, a: :string, b: :string])

    if invalid != [], do: usage("Unknown options: #{inspect(invalid)}")

    a = Keyword.get(opts, :a, "rulebook")
    b = Keyword.get(opts, :b, "random")
    {label_a, label_b} = if a == b, do: {"#{a}_a", "#{b}_b"}, else: {a, b}

    summary =
      SelfPlay.run(
        games: Keyword.get(opts, :games, 2000),
        seed: Keyword.get(opts, :seed, 1),
        a: {String.to_atom(label_a), policy(a)},
        b: {String.to_atom(label_b), policy(b)}
      )

    Mix.shell().info(SelfPlay.format(summary))

    if summary.complete != summary.games do
      Mix.shell().error("Games that did not finish: #{inspect(summary.failures)}")
      exit({:shutdown, 1})
    end
  end

  defp policy("rulebook"), do: SelfPlay.rulebook_policy()
  defp policy("random"), do: SelfPlay.random_policy()

  defp policy(name),
    do: usage("Unknown policy #{inspect(name)}; use one of #{Enum.join(@policies, ", ")}")

  defp usage(message) do
    Mix.shell().error(message)

    Mix.shell().info(
      "Usage: mix pidro.selfplay [--games N] [--seed N] [--a rulebook|random] [--b rulebook|random]"
    )

    exit({:shutdown, 1})
  end
end
