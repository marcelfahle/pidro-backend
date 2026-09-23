defmodule PidroServer.Games.Bots.Strategies.RulebookStrategy do
  @moduledoc """
  The rule-based bot every seated bot plays with.

  A thin adapter over `Pidro.Bot.Rulebook` in the engine, which bids from
  hand strength, names trump, and plays by partnership conventions. It decides
  from the seat view alone and returns a one-sentence reason with every move.
  """

  @behaviour PidroServer.Games.Bots.Strategy

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView

  @impl true
  @spec pick_action([term()], SeatView.t()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, %SeatView{} = view) do
    {action, reason} = Rulebook.decide(view, legal_actions)
    {:ok, action, reason}
  end
end
