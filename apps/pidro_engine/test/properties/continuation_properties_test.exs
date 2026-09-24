defmodule Pidro.Properties.ContinuationPropertiesTest do
  @moduledoc """
  Properties for resuming and branching a saved game.

  A `%GameState{}` is plain serializable data and now carries the chance stream
  it draws from, so `:erlang.term_to_binary/1` is enough to save one and
  continue it elsewhere. These properties assert on *continued play* rather
  than on serialization equality: a round trip alone would never exercise the
  restored stream, and the draw that matters — the next hand's shuffle, inside
  the `:hand_complete` transition — happens several actions after the restore.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.GameState
  alias Pidro.Test.DeterministicGame, as: Game

  # Draws from the caller's process dictionary. Nothing the engine does may
  # depend on these.
  defp disturb_caller_rng do
    _ = Enum.shuffle(1..100)
    _ = Enum.random(1..1000)
    _ = :rand.uniform(1_000_000)
    :ok
  end

  defp save(state), do: :erlang.term_to_binary(state)
  defp restore(binary), do: :erlang.binary_to_term(binary)

  # Some way into hand 1, with bids placed and cards played, but well before
  # the hand ends.
  defp mid_hand(seed), do: seed |> Game.opening() |> Game.advance(8)

  defp through_next_shuffle(state) do
    Game.play_until(state, &(&1.hand_number == state.hand_number + 1))
  end

  # =============================================================================
  # Property: a restored state continues identically, across processes
  # =============================================================================

  property "a restored state deals the next hand identically" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      saved = seed |> mid_hand() |> save()

      there =
        Task.async(fn ->
          disturb_caller_rng()
          saved |> restore() |> through_next_shuffle()
        end)
        |> Task.await()

      here = saved |> restore() |> through_next_shuffle()

      assert here.deck == there.deck
      assert here.events == there.events
      assert here == there
    end
  end

  property "a restored state plays out the rest of the game identically" do
    check all(seed <- integer(1..1_000_000), max_runs: 10) do
      saved = seed |> mid_hand() |> save()

      there =
        Task.async(fn ->
          disturb_caller_rng()
          saved |> restore() |> Game.play_until(&(&1.phase == :complete))
        end)
        |> Task.await()

      here = saved |> restore() |> Game.play_until(&(&1.phase == :complete))

      assert here.winner == there.winner
      assert here.events == there.events
      assert here == there
    end
  end

  property "the saved value round-trips without loss" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      state = mid_hand(seed)

      assert state |> save() |> restore() == state
      assert state.chance |> save() |> restore() == state.chance
    end
  end

  # =============================================================================
  # Property: branching
  # =============================================================================

  property "two branches from one save differ only downstream of the divergence" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      saved = seed |> mid_hand() |> save()
      state = restore(saved)

      # Diverge: one branch takes the action the driver would take, the other
      # takes a different legal action at the same seat.
      position = state.current_turn
      legal = Pidro.Game.Engine.legal_actions(state, position)
      chosen = Game.action(state)

      case Enum.reject(legal, &(&1 == chosen)) do
        [] ->
          # Only one legal action here; nothing to branch on.
          :ok

        [other | _] ->
          {:ok, branch_a} = Pidro.Game.Engine.apply_action(state, position, chosen)
          {:ok, branch_b} = Pidro.Game.Engine.apply_action(restore(saved), position, other)

          # Upstream is shared history, downstream diverges.
          assert Enum.take(branch_a.events, length(state.events)) == state.events
          assert Enum.take(branch_b.events, length(state.events)) == state.events
          refute branch_a == branch_b

          # And the original is untouched by either branch.
          assert restore(saved) == state
      end
    end
  end

  property "the same branch taken twice is the same branch" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      saved = seed |> mid_hand() |> save()

      first = saved |> restore() |> through_next_shuffle()
      disturb_caller_rng()
      second = saved |> restore() |> through_next_shuffle()

      assert first == second
    end
  end

  # =============================================================================
  # Property: what a state must carry to be resumable
  # =============================================================================

  property "a state saved without its chance stream cannot cross the next shuffle" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      # This is the shape `Pidro.Core.Binary.from_binary/1` produces, and the
      # shape a bare `%GameState{}` fixture has: playable until it needs a
      # draw, and a loud failure at that point rather than a silent fallback to
      # process entropy.
      stripped = %{mid_hand(seed) | chance: nil}

      assert_raise FunctionClauseError, fn -> through_next_shuffle(stripped) end
    end
  end

  property "a state restored with a different chance stream deals a different hand" do
    check all(seed <- integer(1..1_000_000), max_runs: 20) do
      state = mid_hand(seed)
      other = %{state | chance: GameState.new(seed: seed + 1).chance}

      refute through_next_shuffle(state).deck == through_next_shuffle(other).deck
    end
  end
end
