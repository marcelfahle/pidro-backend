defmodule PidroServer.Games.Bots.Strategy do
  @moduledoc """
  Behaviour for bot player strategies.

  Strategy modules decide what action a bot should take given the current
  legal actions and game state.

  ## Implementing a Strategy

      defmodule MyStrategy do
        @behaviour PidroServer.Games.Bots.Strategy

        @impl true
        def pick_action(legal_actions, game_state) do
          action = # ... your logic ...
          {:ok, action, "reason for choosing this action"}
        end
      end
  """

  @callback pick_action(legal_actions :: [term()], game_state :: map()) ::
              {:ok, action :: term(), reasoning :: String.t()}
end
