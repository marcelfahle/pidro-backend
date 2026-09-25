defmodule PidroServer.Games.Bots.Strategies.CasualStrategy do
  @moduledoc """
  Adapts the engine's Casual rulebook profile to seated and substitute bots.
  Scheduling and room configuration remain with the runtime.
  """
  @behaviour PidroServer.Games.Bots.Strategy

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView

  @impl true
  @spec pick_action([term()], SeatView.t()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, %SeatView{} = view) do
    {action, reason} = Rulebook.decide(view, legal_actions, :casual)
    {:ok, action, reason}
  end
end
