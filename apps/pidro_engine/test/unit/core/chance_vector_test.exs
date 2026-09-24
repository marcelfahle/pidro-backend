defmodule Pidro.Core.ChanceVectorTest do
  @moduledoc """
  A recorded chance vector: one seed, and the exact cards it produces.

  The engine's determinism guarantee is version-qualified — the same engine
  version on the supported OTP version (see `.tool-versions`) turns a seed into
  the same game. Nothing promises that across an OTP upgrade, a change to
  `Pidro.Core.Chance`, or a change to how `:rand.shuffle_s/2` consumes its
  stream. This test is what makes such a change visible.

  It is an intentional-change gate, not a bug detector. When it fails, the
  first question is whether the sequence was *meant* to move. If it was — an
  OTP bump, a deliberate change to the chance primitives — re-record the values
  below and note the change. If it was not, something drew from the stream that
  did not before, and the cards every seeded game deals have shifted with it.

  The two values cover both primitives the engine draws through: the cut map
  comes from `Chance.uniform/2` and the deck from `Chance.shuffle/2`, which is
  also the call that deals hands 2..N.
  """

  use ExUnit.Case, async: true

  alias Pidro.Core.{Chance, GameState}
  alias Pidro.Game.Dealing

  # Recorded on erlang 29.0.3 / elixir 1.20.2-otp-29.
  @seed 20_260_924

  @chance {:exsss, [149_428_487_850_567_403 | 48_848_935_574_042_587]}

  @cuts %{
    north: {11, :spades},
    east: {4, :diamonds},
    south: {3, :clubs},
    west: {4, :spades}
  }

  @dealer :north

  @deck_prefix [
    {5, :clubs},
    {11, :spades},
    {11, :clubs},
    {12, :hearts},
    {13, :hearts},
    {9, :diamonds},
    {12, :spades},
    {4, :spades}
  ]

  test "the seed builds the recorded chance value" do
    assert Chance.from_seed(@seed) == @chance
    assert GameState.new(seed: @seed).chance == @chance
  end

  test "the recorded chance value cuts and shuffles the recorded cards" do
    {:ok, state} = Dealing.select_dealer(GameState.new(seed: @seed))

    assert state.dealer_selection_cuts == @cuts
    assert state.current_dealer == @dealer
    assert Enum.take(state.deck, 8) == @deck_prefix
    assert length(state.deck) == 52
  end
end
