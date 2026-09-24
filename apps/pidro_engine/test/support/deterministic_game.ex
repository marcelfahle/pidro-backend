defmodule Pidro.Test.DeterministicGame do
  @moduledoc """
  Drives the engine with a policy that is a pure function of the game state.

  `Pidro.Test.GameTrace` seeds the calling process, because its policy draws
  from `:rand`. Nothing here does: the action taken in a state is fixed, so the
  same starting state produces the same game in any process, at any time, no
  matter what else that process has drawn. A difference between two runs can
  therefore only have come from the engine — which is what the multi-hand and
  continuation tests are asserting about.
  """

  alias Pidro.Core.GameState
  alias Pidro.Game.{DealerRob, Dealing, Engine}

  @max_actions 5_000

  @doc """
  The state a game starts in: cuts drawn, first deck shuffled, cards dealt.
  """
  @spec opening(integer()) :: Pidro.Core.Types.GameState.t()
  def opening(seed) do
    {:ok, cut} = Dealing.select_dealer(GameState.new(seed: seed))
    {:ok, dealt} = Engine.advance_from_dealer_selection(cut)

    dealt
  end

  @doc """
  Applies one action, chosen by `action/1`.
  """
  @spec step(Pidro.Core.Types.GameState.t()) :: Pidro.Core.Types.GameState.t()
  def step(state) do
    position = state.current_turn
    {:ok, next} = Engine.apply_action(state, position, action(state))

    next
  end

  @doc """
  Applies `count` actions, stopping early if the game completes.
  """
  @spec advance(Pidro.Core.Types.GameState.t(), non_neg_integer()) ::
          Pidro.Core.Types.GameState.t()
  def advance(state, 0), do: state
  def advance(%{phase: :complete} = state, _count), do: state
  def advance(state, count) when count > 0, do: advance(step(state), count - 1)

  @doc """
  Plays until `predicate` holds, and returns that state.

  Raises if the game completes, or runs past `#{@max_actions}` actions, without
  the predicate ever holding — a silent early return would turn a real
  divergence into a passing test.
  """
  @spec play_until(Pidro.Core.Types.GameState.t(), (Pidro.Core.Types.GameState.t() -> boolean())) ::
          Pidro.Core.Types.GameState.t()
  def play_until(state, predicate), do: play_until(state, predicate, 0)

  defp play_until(state, predicate, count) do
    cond do
      predicate.(state) ->
        state

      state.phase == :complete ->
        raise "game completed before the predicate held"

      count > @max_actions ->
        raise "game exceeded #{@max_actions} actions before the predicate held"

      true ->
        play_until(step(state), predicate, count + 1)
    end
  end

  @doc """
  The action this driver takes in `state`: a pure function of the state.
  """
  @spec action(Pidro.Core.Types.GameState.t()) :: Pidro.Core.Types.action()
  def action(state) do
    position = state.current_turn

    state
    |> Engine.legal_actions(position)
    |> choose(state, position)
  end

  defp choose([{:select_hand, _marker}], state, position) do
    pool = state.players[position].hand ++ state.deck
    {:select_hand, DealerRob.select_best_cards(pool, state.trump_suit)}
  end

  defp choose(legal, _state, _position) do
    # Passing whenever it is legal keeps hands short and leaves the forced
    # dealer bid to the engine; otherwise take the first legal action, which is
    # a deterministic function of the state.
    if :pass in legal, do: :pass, else: hd(legal)
  end
end
