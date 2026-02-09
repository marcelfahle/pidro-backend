defmodule PidroServer.Games.Bots.Strategies.RandomStrategy do
  @moduledoc """
  Random strategy for bot players that avoids infinite games.

  During bidding, passes 70% of the time and bids minimum otherwise.
  This prevents the infinite-game problem caused by uniform random bidding
  where both teams accumulate massive negative scores.

  For all other phases (play, declare trump, select hand), picks randomly
  from the available legal actions.
  """

  @behaviour PidroServer.Games.Bots.Strategy

  @impl true
  @spec pick_action(list(), map()) :: {:ok, term(), String.t()}
  def pick_action(legal_actions, _game_state) do
    action = choose_action(legal_actions)

    reasoning =
      "Randomly selected from #{length(legal_actions)} legal action#{if length(legal_actions) == 1, do: "", else: "s"}"

    {:ok, action, reasoning}
  end

  defp choose_action(legal_actions) do
    cond do
      # Bidding phase: pass 70% of the time, bid minimum otherwise
      :pass in legal_actions ->
        if :rand.uniform() < 0.7 do
          :pass
        else
          # Find minimum bid available
          legal_actions
          |> Enum.filter(&match?({:bid, _}, &1))
          |> case do
            [] -> :pass
            bids -> Enum.min_by(bids, fn {:bid, amount} -> amount end)
          end
        end

      # All other phases: random
      true ->
        Enum.random(legal_actions)
    end
  end
end
