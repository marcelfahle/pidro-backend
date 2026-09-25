defmodule Pidro.Bot.RulebookContractTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView
  alias Pidro.Game.Engine
  alias Pidro.Test.{GameTrace, Scenario}

  defp decide(state) do
    Rulebook.decide(Scenario.view(state), Scenario.legal(state))
  end

  test "uses public history to feed a Five after the Ace has been played" do
    state =
      Scenario.playing(
        me: :south,
        hands: %{south: [5, 9, 3]},
        tricks: [[north: 14, east: 4, south: 2, west: 6]],
        trick: [north: 13, east: 7]
      )

    assert {{:play_card, {5, :hearts}}, _} = decide(state)
  end

  test "uses publicly killed cards to recognise the highest live trump" do
    state =
      Scenario.playing(
        me: :north,
        hands: %{north: [9, 4, 3]},
        killed: %{east: [14, 13, 12, 11, 10]}
      )

    assert {{:play_card, {9, :hearts}}, _} = decide(state)
  end

  test "keeps essential partnership conventions" do
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
               decide(Scenario.playing(opts))

      refute reason =~ "failed"
    end
  end

  test "decisions stay legal and deterministic across real game traces" do
    for seed <- 1..15,
        state <- GameTrace.states(seed),
        state.phase != :complete,
        position <- [:north, :east, :south, :west],
        legal = Engine.legal_actions(state, position),
        legal != [] do
      view = SeatView.for_seat(state, position)
      {action, reason} = decision = Rulebook.decide(view, legal)
      assert action in legal
      refute reason =~ ~r/failed|recognise|not allowed/
      assert decision == Rulebook.decide(view, legal)
    end
  end
end
