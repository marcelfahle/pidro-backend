defmodule PidroServer.Games.Bots.Strategy do
  @moduledoc """
  Behaviour for bot player strategies.

  Strategy modules decide what action a bot should take given the current
  legal actions and the bot's seat view.

  The second argument is a `Pidro.Core.SeatView` for the bot's own seat: its
  hand, the public table state, and the hand sizes of the other seats. No
  strategy is ever given another seat's cards or the deck, so no strategy can
  peek. `PidroServer.Games.Bots.BotBrain` and the turn timer build the view.

  ## Implementing a Strategy

      defmodule MyStrategy do
        @behaviour PidroServer.Games.Bots.Strategy

        @impl true
        def pick_action(legal_actions, %Pidro.Core.SeatView{} = view) do
          action = # ... your logic ...
          {:ok, action, "reason for choosing this action"}
        end
      end
  """

  @callback pick_action(legal_actions :: [term()], view :: Pidro.Core.SeatView.t()) ::
              {:ok, action :: term(), reasoning :: String.t()}
end
