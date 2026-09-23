defmodule Pidro.Bot.RandomPolicy do
  @moduledoc """
  The self-play baseline: a policy that mirrors the server's random bot.

  While passing is allowed it passes 70% of the time and otherwise bids the
  minimum. Everywhere else, including a dealer's forced bid, it picks a
  legal action uniformly at random. It is the strategy every bot seat used
  before the rulebook, so beating it is the release bar.
  """

  alias Pidro.Core.{SeatView, Types}

  @doc """
  Chooses an action from the non-empty list `legal`. The view is ignored.
  """
  @spec choose(SeatView.t(), [Types.action(), ...]) :: Types.action()
  def choose(_view, legal) do
    if :pass in legal do
      if :rand.uniform() < 0.7, do: :pass, else: minimum_bid(legal)
    else
      Enum.random(legal)
    end
  end

  defp minimum_bid(legal) do
    case for({:bid, amount} <- legal, do: amount) do
      [] -> :pass
      amounts -> {:bid, Enum.min(amounts)}
    end
  end
end
