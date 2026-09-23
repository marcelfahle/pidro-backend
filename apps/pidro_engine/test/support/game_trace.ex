defmodule Pidro.Test.GameTrace do
  @moduledoc """
  Plays seeded random games through the engine and returns every state.

  Used by properties that must hold in every state a real game passes
  through. Bidding mirrors the server's random strategy (pass 70% of the
  time, otherwise the minimum), which keeps games finite.
  """

  alias Pidro.Core.GameState
  alias Pidro.Game.{DealerRob, Dealing, Engine}

  @max_actions 5_000

  @doc """
  Plays one game from `seed` and returns its states, oldest first.

  Options:
  - `:auto_dealer_rob` - `false` makes the dealer rob manually (default `true`)
  """
  @spec states(integer(), keyword()) :: [Pidro.Core.Types.GameState.t()]
  def states(seed, opts \\ []) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    base = GameState.new()
    rob? = Keyword.get(opts, :auto_dealer_rob, true)
    initial = %{base | config: Map.put(base.config, :auto_dealer_rob, rob?)}

    {:ok, cut} = Dealing.select_dealer(initial)
    {:ok, dealt} = Engine.advance_from_dealer_selection(cut)

    play(dealt, [dealt, cut, initial], 0)
  end

  defp play(%{phase: :complete}, acc, _count), do: Enum.reverse(acc)

  defp play(_state, _acc, count) when count > @max_actions do
    raise "random game exceeded #{@max_actions} actions"
  end

  defp play(state, acc, count) do
    position = state.current_turn
    action = state |> Engine.legal_actions(position) |> choose(state, position)
    {:ok, next} = Engine.apply_action(state, position, action)
    play(next, [next | acc], count + 1)
  end

  defp choose([{:select_hand, _marker}], state, position) do
    pool = state.players[position].hand ++ state.deck
    {:select_hand, DealerRob.select_best_cards(pool, state.trump_suit)}
  end

  defp choose(legal, _state, _position) do
    cond do
      :pass in legal and :rand.uniform() < 0.7 -> :pass
      Enum.any?(legal, &match?({:bid, _}, &1)) -> Enum.find(legal, &match?({:bid, _}, &1))
      true -> Enum.random(legal)
    end
  end
end
