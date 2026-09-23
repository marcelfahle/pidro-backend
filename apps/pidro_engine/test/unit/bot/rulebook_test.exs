defmodule Pidro.Bot.RulebookTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.{GameState, SeatView}
  alias Pidro.Core.Types.Trick
  alias Pidro.Game.Engine
  alias Pidro.Test.{GameTrace, Scenario}

  @positions [:north, :east, :south, :west]

  defp decide(state), do: Rulebook.decide(Scenario.view(state), Scenario.legal(state))

  # Every decision the rulebook would make while replaying some random games.
  defp decisions(seeds) do
    for seed <- seeds,
        state <- GameTrace.states(seed, auto_dealer_rob: rem(seed, 3) != 0),
        state.phase != :complete,
        position <- @positions,
        legal <- [Engine.legal_actions(state, position)],
        legal != [] do
      {state, position, legal, Rulebook.decide(SeatView.for_seat(state, position), legal)}
    end
  end

  test "AE15: states that differ only in the other seats' hidden cards give the same move and reason" do
    base = [
      me: :south,
      trick: [north: 12, east: 10],
      tricks: [[north: 9, east: 2, south: 4, west: 3]]
    ]

    own = %{south: [14, 6, 5]}

    one = %{north: [13, 7], east: [8, :off5], west: [11, {9, :clubs}]}
    two = %{north: [11, :off5], east: [13, 7], west: [8, {9, :clubs}]}
    one = Scenario.playing(base ++ [hands: Map.merge(own, one)])
    two = Scenario.playing(base ++ [hands: Map.merge(own, two)])

    assert one.players.north.hand != two.players.north.hand
    assert decide(one) == decide(two)
  end

  test "dealer selection returns :select_dealer" do
    state = GameState.new(seed: 1)

    assert {:select_dealer, _} =
             Rulebook.decide(SeatView.for_seat(state, :north), [:select_dealer])
  end

  test "a manual rob returns the hand-selection marker for the caller to resolve" do
    base = GameState.new(seed: 1)

    state = %{
      base
      | phase: :second_deal,
        current_dealer: :north,
        current_turn: :north,
        trump_suit: :hearts,
        highest_bid: {:east, 7},
        deck: [{14, :hearts}, {3, :spades}],
        config: Map.put(base.config, :auto_dealer_rob, false)
    }

    legal = Engine.legal_actions(state, :north)
    assert legal == [{:select_hand, :choose_6_cards}]

    assert {{:select_hand, :choose_6_cards}, _} =
             Rulebook.decide(SeatView.for_seat(state, :north), legal)
  end

  test "an unknown action shape falls back to a legal move and says so" do
    state =
      Scenario.bidding(me: :north, hand: Scenario.suit(:hearts, [14, 13, 12, 11, 10, 9, 8, 7, 6]))

    legal = Scenario.legal(state) ++ [{:mystery, 1}]

    {action, reason} = Rulebook.decide(Scenario.view(state), legal)
    assert action in legal
    assert action == :pass
    assert reason =~ "did not recognise"
  end

  test "a rule that raises falls back to the lowest non-point card" do
    state = Scenario.playing(me: :east, hands: %{east: [14, 9, 3]}, trick: [north: 7])

    broken = %{
      state
      | current_trick: %Trick{number: 1, leader: :north, plays: [{:north, :garbage}]}
    }

    {action, reason} = Rulebook.decide(Scenario.view(broken), Scenario.legal(state))
    assert action == {:play_card, {3, :hearts}}
    assert reason =~ "A rule failed"
  end

  describe "fallback with malformed card actions" do
    setup do
      state = Scenario.playing(me: :east, hands: %{east: [14, 9, 3]}, trick: [north: 7])
      %{view: Scenario.view(state)}
    end

    test "plays the lowest well-formed card when others are malformed", %{view: view} do
      legal = [{:play_card, {3, :hearts}}, {:play_card, :garbage}, {:play_card, {14, :hearts}}]

      assert {{:play_card, {3, :hearts}}, reason} = Rulebook.decide(view, legal)
      assert reason =~ "did not recognise"
    end

    test "takes the first move offered when no card is well formed", %{view: view} do
      assert {{:play_card, :garbage}, reason} = Rulebook.decide(view, [{:play_card, :garbage}])
      assert reason =~ "first move offered"

      assert {{:mystery, 1}, _} = Rulebook.decide(view, [{:mystery, 1}, {:mystery, 2}])

      assert Rulebook.fallback(view, [{:play_card, {99, :moons}}]) |> elem(0) ==
               {:play_card, {99, :moons}}
    end
  end

  test "a view deciding 100 times gives one result" do
    state =
      Scenario.playing(me: :south, hands: %{south: [14, 9, 5, 3]}, trick: [north: 12, east: 10])

    view = Scenario.view(state)
    legal = Scenario.legal(state)

    assert 1..100 |> Enum.map(fn _ -> Rulebook.decide(view, legal) end) |> Enum.uniq() |> length() ==
             1
  end

  test "every decision in every phase of real games is legal with a single-sentence reason" do
    results = decisions(1..30)
    phases = results |> Enum.map(fn {state, _, _, _} -> state.phase end) |> Enum.uniq()

    assert :bidding in phases and :declaring in phases and :playing in phases
    assert :second_deal in phases and :dealer_selection in phases

    for {state, position, legal, {action, reason}} <- results do
      assert action in legal, "#{position} in #{state.phase}: #{inspect(action)}"
      assert reason =~ ~r/^[A-Z][^.]*\.$/, reason
      refute reason =~ ~r/No rule applied|failed|recognise|not allowed/, reason
    end
  end

  test "a playing decision takes well under the bot move delay" do
    views =
      for seed <- 1..10,
          state <- GameTrace.states(seed),
          state.phase == :playing,
          do:
            {SeatView.for_seat(state, state.current_turn),
             Engine.legal_actions(state, state.current_turn)}

    times =
      for {view, legal} <- views do
        {micros, _} = :timer.tc(fn -> Rulebook.decide(view, legal) end)
        micros
      end

    assert Enum.max(times) < 50_000
    assert Enum.sum(times) / length(times) < 1_000
  end

  test "no rulebook module draws a random number" do
    for file <- ~w(knowledge bidding thresholds play rulebook) do
      source = File.read!(Path.join([__DIR__, "../../../lib/pidro/bot", file <> ".ex"]))
      refute source =~ ~r/:rand\.|Enum\.random|Enum\.shuffle|Enum\.take_random|:crypto\./, file
    end
  end
end
