defmodule Pidro.Game.MultiHandDeterminismTest do
  @moduledoc """
  The deck dealt for hands 2..N is shuffled inside `apply_action/3`, during the
  `:hand_complete` transition — the dealer-cut ceremony runs once per game, so
  after the first hand the engine crosses `:dealer_selection` automatically and
  deals whatever that shuffle produced.

  These tests pin that deck to the game's chance stream: the same starting
  state deals the same hand 2 and hand 3, whatever the calling process has
  drawn from `:rand` in between.
  """

  use ExUnit.Case, async: true

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

  defp hands(state) do
    Map.new(state.players, fn {position, player} -> {position, player.hand} end)
  end

  describe "hands after the first" do
    test "the same starting state deals the same hand 2" do
      start = Game.opening(1)

      first = Game.play_until(start, &(&1.hand_number == 2))
      disturb_caller_rng()
      second = Game.play_until(start, &(&1.hand_number == 2))

      assert first.deck == second.deck
      assert hands(first) == hands(second)
      assert first.events == second.events
      assert first == second
    end

    test "the same starting state deals the same hand 3" do
      start = Game.opening(1)

      first = start |> Game.play_until(&(&1.hand_number == 3))
      disturb_caller_rng()
      second = start |> Game.play_until(&(&1.hand_number == 3))

      assert first.deck == second.deck
      assert hands(first) == hands(second)
      assert first == second
    end

    test "hand 2 is dealt from the chance stream, not from the hand-1 deck" do
      hand_one = Game.opening(1)
      hand_two = Game.play_until(hand_one, &(&1.hand_number == 2))

      # A full deck's worth of cards is back in play, and the stream has moved
      # on: the deck was shuffled during the `:hand_complete` transition.
      assert length(hand_two.deck) +
               Enum.sum(Enum.map(hands(hand_two), fn {_p, h} -> length(h) end)) ==
               52

      refute hand_two.chance == hand_one.chance
      assert hand_two.dealer_selection_cuts == nil
    end

    test "different seeds deal different second hands" do
      second_hand = fn seed ->
        seed |> Game.opening() |> Game.play_until(&(&1.hand_number == 2))
      end

      refute second_hand.(1).deck == second_hand.(2).deck
    end

    test "a game whose chance is missing fails loudly at the next hand's shuffle" do
      # `Binary.from_binary/1` and any hand-built fixture leave `chance: nil`.
      # Such a state must not silently fall back to process entropy.
      start = %{Game.opening(1) | chance: nil}

      assert_raise FunctionClauseError, fn ->
        Game.play_until(start, &(&1.hand_number == 2))
      end
    end
  end

  describe "the chance stream is the whole difference" do
    test "two states that differ only in chance deal different second hands" do
      base = Game.opening(1)
      other = %{base | chance: GameState.new(seed: 99).chance}

      first = Game.play_until(base, &(&1.hand_number == 2))
      second = Game.play_until(other, &(&1.hand_number == 2))

      refute first.deck == second.deck
    end
  end
end
