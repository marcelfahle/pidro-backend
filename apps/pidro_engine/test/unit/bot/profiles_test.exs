defmodule Pidro.Bot.ProfilesTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView
  alias Pidro.Game.Engine
  alias Pidro.Test.{GameTrace, Scenario}

  defp decide(state, profile) do
    Rulebook.decide(Scenario.view(state), Scenario.legal(state), profile)
  end

  test "Regular remembers a spent Ace; Casual keeps its Five with an opponent still to act" do
    state =
      Scenario.playing(
        me: :south,
        hands: %{south: [5, 9, 3]},
        tricks: [[north: 14, east: 4, south: 2, west: 6]],
        trick: [north: 13, east: 7]
      )

    assert {{:play_card, {5, :hearts}}, _} = decide(state, :regular)
    assert {{:play_card, {3, :hearts}}, _} = decide(state, :casual)
    assert decide(state, :regular) == Rulebook.decide(Scenario.view(state), Scenario.legal(state))
  end

  test "Casual does not use killed cards to promote a lower trump" do
    state =
      Scenario.playing(
        me: :north,
        hands: %{north: [9, 4, 3]},
        killed: %{east: [14, 13, 12, 11, 10]}
      )

    assert {{:play_card, {9, :hearts}}, _} = decide(state, :regular)
    assert {{:play_card, {3, :hearts}}, _} = decide(state, :casual)
  end

  for profile <- [:casual, :regular] do
    test "#{profile} keeps essential partnership conventions" do
      cases = [
        {[me: :south, hands: %{south: [5, 9, 3]}, trick: [north: 14, east: 4]], 5},
        {[me: :south, hands: %{south: [14, 6]}, trick: [west: 9, north: 12, east: 7]], 6},
        {[me: :south, hands: %{south: [5, 9, 3]}, trick: [north: 2, east: 14]], 3},
        {[me: :south, hands: %{south: [13, 8]}, trick: [north: 3, east: 5]], 13},
        {[me: :north, hands: %{north: [5, 9, 3]}], 3},
        {[me: :south, hands: %{south: [5, 9, 3]}, trick: [north: 12, east: 7], cold: [:west]], 5}
      ]

      for {opts, rank} <- cases do
        assert {{:play_card, {^rank, :hearts}}, reason} =
                 decide(Scenario.playing(opts), unquote(profile))

        refute reason =~ "failed"
      end
    end
  end

  test "profiles share bidding, trump selection, legality and deterministic decisions" do
    for seed <- 1..15,
        state <- GameTrace.states(seed),
        state.phase != :complete,
        position <- [:north, :east, :south, :west],
        legal = Engine.legal_actions(state, position),
        legal != [] do
      view = SeatView.for_seat(state, position)
      regular = Rulebook.decide(view, legal)
      assert regular == Rulebook.decide(view, legal, :regular)
      {action, reason} = casual = Rulebook.decide(view, legal, :casual)
      assert action in legal
      refute reason =~ ~r/failed|recognise|not allowed/
      assert casual == Rulebook.decide(view, legal, :casual)
      if state.phase != :playing, do: assert(casual == regular)
    end
  end
end
