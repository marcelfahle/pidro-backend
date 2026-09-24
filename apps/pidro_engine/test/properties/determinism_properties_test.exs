defmodule Pidro.Properties.DeterminismPropertiesTest do
  @moduledoc """
  Property-based tests for the engine's determinism guarantee.

  > Given the same complete authoritative state and action, the same engine
  > version on the supported OTP version produces equal next state and domain
  > events, independently of the calling process's RNG state.

  The second half of that sentence is the interesting one: these properties
  deliberately draw from the *test* process's `:rand` dictionary between two
  otherwise identical engine calls, and assert it changes nothing. That is what
  would have failed before chance became an explicit field on `%GameState{}`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Chance, GameState}
  alias Pidro.Game.Engine

  # Draws from the caller's process dictionary. Nothing the engine does may
  # depend on these.
  defp disturb_caller_rng do
    _ = Enum.shuffle(1..100)
    _ = Enum.random(1..1000)
    _ = :rand.uniform(1_000_000)
    :ok
  end

  # =============================================================================
  # Property: A seed fully determines the game it starts
  # =============================================================================

  property "the same seed builds the same starting state" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      disturb_caller_rng()
      assert GameState.new(seed: seed) == GameState.new(seed: seed)
    end
  end

  property "different seeds build different chance streams" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      refute GameState.new(seed: seed).chance == GameState.new(seed: seed + 1).chance
    end
  end

  # =============================================================================
  # Property: Transitions ignore the caller's RNG
  # =============================================================================

  property "the dealer-cut transition ignores the caller's RNG" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      state = GameState.new(seed: seed)

      {:ok, first} = Engine.apply_action(state, :north, :select_dealer)

      disturb_caller_rng()

      {:ok, second} = Engine.apply_action(state, :north, :select_dealer)

      assert first.deck == second.deck
      assert first.dealer_selection_cuts == second.dealer_selection_cuts
      assert first.events == second.events
      assert first == second
    end
  end

  property "the deal and the first bidding round ignore the caller's RNG" do
    check all(seed <- integer(1..1_000_000), max_runs: 50) do
      state = GameState.new(seed: seed)

      first = play_opening(state)
      disturb_caller_rng()
      second = play_opening(state)

      assert first == second
    end
  end

  defp play_opening(state) do
    {:ok, cut} = Engine.apply_action(state, :north, :select_dealer)
    {:ok, dealt} = Engine.advance_from_dealer_selection(cut)
    {:ok, bid} = Engine.apply_action(dealt, dealt.current_turn, {:bid, 6})
    bid
  end

  # =============================================================================
  # Property: the chance stream advances, and carries the game forward
  # =============================================================================

  property "select_dealer advances the chance stream" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      state = GameState.new(seed: seed)
      {:ok, cut} = Engine.apply_action(state, :north, :select_dealer)

      refute cut.chance == state.chance
    end
  end

  property "a chance value survives a round trip through a binary" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      chance = Chance.from_seed(seed)
      restored = chance |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert restored == chance

      assert Chance.shuffle(Enum.to_list(1..20), restored) ==
               Chance.shuffle(Enum.to_list(1..20), chance)
    end
  end

  property "a state restored in another process cuts and deals identically" do
    check all(seed <- integer(1..1_000_000), max_runs: 30) do
      saved = seed |> then(&GameState.new(seed: &1)) |> :erlang.term_to_binary()

      here = saved |> :erlang.binary_to_term() |> play_opening()

      there =
        Task.async(fn ->
          disturb_caller_rng()
          saved |> :erlang.binary_to_term() |> play_opening()
        end)
        |> Task.await()

      assert here == there
    end
  end

  # =============================================================================
  # Property: Chance helpers are pure and thread their state
  # =============================================================================

  property "Chance.shuffle/2 preserves the items and advances the stream" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      items = Enum.to_list(1..52)
      chance = Chance.from_seed(seed)

      {shuffled, advanced} = Chance.shuffle(items, chance)

      assert Enum.sort(shuffled) == items
      refute advanced == chance
    end
  end

  property "Chance.uniform/2 stays in range and advances the stream" do
    check all(seed <- integer(1..1_000_000), n <- integer(1..100), max_runs: 100) do
      chance = Chance.from_seed(seed)
      {value, advanced} = Chance.uniform(n, chance)

      assert value in 1..n
      refute advanced == chance
    end
  end

  property "Chance.cut_cards/2 yields one valid card per position" do
    check all(seed <- integer(1..1_000_000), max_runs: 100) do
      positions = [:north, :east, :south, :west]
      {cuts, advanced} = Chance.cut_cards(positions, Chance.from_seed(seed))

      assert Enum.map(cuts, &elem(&1, 0)) == positions

      assert Enum.all?(cuts, fn {_position, {rank, suit}} ->
               rank in 2..14 and suit in [:hearts, :diamonds, :clubs, :spades]
             end)

      refute advanced == Chance.from_seed(seed)
    end
  end

  # =============================================================================
  # Property: a malformed chance value fails loudly instead of self-seeding
  # =============================================================================

  # `:rand.seed_s/1` accepts a bare algorithm name as well as an exported
  # state. Without a shape guard, `Chance.shuffle(deck, :exsss)` would build a
  # default-seeded stream and draw *nondeterministically* — the exact failure
  # this whole change exists to remove — instead of raising. `nil` is the other
  # value that reaches here in practice: `Pidro.Core.Binary.from_binary/1`
  # documents decoded states as carrying it.
  describe "a malformed chance value" do
    setup do
      %{bad: [:exsss, :exro928ss, nil, {}, {:exsss}, "chance", 42, {:exsss, [1 | 2], :extra}]}
    end

    test "is rejected by shuffle/2", %{bad: bad} do
      for value <- bad do
        assert_raise FunctionClauseError, fn -> Chance.shuffle([1, 2, 3], value) end
      end
    end

    test "is rejected by uniform/2", %{bad: bad} do
      for value <- bad do
        assert_raise FunctionClauseError, fn -> Chance.uniform(6, value) end
      end
    end

    test "is rejected by cut_cards/2", %{bad: bad} do
      for value <- bad do
        assert_raise FunctionClauseError, fn -> Chance.cut_cards([:north], value) end
      end
    end

    test "a well-formed value is still accepted", %{bad: _} do
      chance = Chance.from_seed(7)

      assert {_shuffled, _advanced} = Chance.shuffle([1, 2, 3], chance)
      assert {_value, _advanced} = Chance.uniform(6, chance)
      assert {_cuts, _advanced} = Chance.cut_cards([:north], chance)
    end
  end
end
