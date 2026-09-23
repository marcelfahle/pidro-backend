defmodule Pidro.Bot.KnowledgeTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Knowledge
  alias Pidro.Core.Card
  alias Pidro.Game.Engine
  alias Pidro.Test.Scenario

  doctest Pidro.Bot.Knowledge

  describe "unbeatable?/2" do
    test "the King is unbeatable once the Ace has been played" do
      view =
        Scenario.playing(
          me: :east,
          hands: %{east: [13, 7, 3]},
          tricks: [[north: 9, east: 14, south: 4, west: 6]]
        )
        |> Scenario.view()

      assert Knowledge.unbeatable?(view, {13, :hearts})
    end

    test "the King is not unbeatable while the Ace is unseen, however few cards the others hold" do
      view =
        Scenario.playing(
          me: :north,
          hands: %{north: [13, 7]},
          counts: %{east: 1, south: 1, west: 1}
        )
        |> Scenario.view()

      refute Knowledge.unbeatable?(view, {13, :hearts})
      assert {14, :hearts} in Knowledge.live_threats(view)
    end

    test "killed trumps are not threats" do
      view =
        Scenario.playing(me: :north, hands: %{north: [13, 7]}, killed: %{east: [14]})
        |> Scenario.view()

      assert Knowledge.unbeatable?(view, {13, :hearts})
    end
  end

  describe "seats_to_act/1" do
    test "a cold seat is not still to act, and three active seats complete a trick" do
      state =
        Scenario.playing(
          me: :south,
          hands: %{south: [9, 3]},
          trick: [north: 8, east: 10],
          cold: [:west]
        )

      view = Scenario.view(state)
      assert Knowledge.seats_to_act(view) == []
      assert Knowledge.opponents_to_act(view) == []

      {:ok, after_play} = Engine.apply_action(state, :south, {:play_card, {9, :hearts}})
      assert after_play.current_trick == nil
      assert [%{plays: [_, _, _]}] = after_play.tricks
    end

    test "lists the active seats that have not played" do
      view =
        Scenario.playing(me: :east, hands: %{east: [9, 3]}, trick: [north: 8])
        |> Scenario.view()

      assert Knowledge.seats_to_act(view) == [:south, :west]
      assert Knowledge.opponents_to_act(view) == [:south]
    end
  end

  describe "current_winner/1" do
    test "the off-Five ranks below the Five and above the 4" do
      view =
        Scenario.playing(me: :west, hands: %{west: [3]}, trick: [north: 4, east: :off5, south: 2])
        |> Scenario.view()

      assert Knowledge.current_winner(view) == {:east, {5, :diamonds}}

      view =
        Scenario.playing(me: :west, hands: %{west: [3]}, trick: [north: :off5, east: 5, south: 4])
        |> Scenario.view()

      assert Knowledge.current_winner(view) == {:east, {5, :hearts}}
    end

    test "is nil on lead" do
      view = Scenario.playing(me: :north, hands: %{north: [9]}) |> Scenario.view()
      assert Knowledge.current_winner(view) == nil
    end
  end

  describe "safe_trick?/1" do
    test "partner winning with the Queen and the bot last to act is safe" do
      view =
        Scenario.playing(
          me: :west,
          hands: %{west: [14, 6]},
          trick: [north: 9, east: 12, south: 7]
        )
        |> Scenario.view()

      assert Knowledge.safe_trick?(view)
    end

    test "the same trick with an opponent still to act and the King unseen is not safe" do
      view =
        Scenario.playing(me: :west, hands: %{west: [14, 6]}, trick: [east: 12, south: 7])
        |> Scenario.view()

      refute Knowledge.safe_trick?(view)
      assert Knowledge.safe_after?(view, {14, :hearts})
      refute Knowledge.safe_after?(view, {6, :hearts})
    end

    test "an opponent winning is never safe" do
      view =
        Scenario.playing(me: :south, hands: %{south: [9]}, trick: [north: 3, east: 14])
        |> Scenario.view()

      refute Knowledge.safe_trick?(view)
    end
  end

  describe "points" do
    test "side points credit the 2 to the side that played it and ignore hand_points" do
      view =
        Scenario.playing(
          me: :east,
          hands: %{east: [9, 3]},
          tricks: [[north: 2, east: 14, south: 4, west: 6]]
        )
        |> Scenario.view()

      assert view.state.hand_points == %{north_south: 0, east_west: 2}
      assert Knowledge.side_points(view) == %{north_south: 1, east_west: 1}
    end

    test "points on the trick leave out the 2" do
      view =
        Scenario.playing(me: :west, hands: %{west: [3]}, trick: [north: 2, east: 10, south: 5])
        |> Scenario.view()

      assert Knowledge.points_on_trick(view) == 6
      assert Knowledge.opponent_five_on_trick?(view)
      refute Knowledge.opponent_five_on_trick?(%{view | position: :north})
    end
  end

  describe "non-trump filler" do
    test "is accepted by the scenario builder and ignored by every helper" do
      state =
        Scenario.playing(
          me: :south,
          hands: %{south: [9, 3, {14, :clubs}, {13, :spades}]},
          trick: [north: 8, east: 10]
        )

      view = Scenario.view(state)

      assert Scenario.legal(state) == [{:play_card, {9, :hearts}}, {:play_card, {3, :hearts}}]
      assert Knowledge.my_trumps(view) == [{3, :hearts}, {9, :hearts}]
      refute {14, :clubs} in Knowledge.unseen_trumps(view)
      assert Knowledge.unseen_trumps(view) |> Enum.all?(&Card.is_trump?(&1, :hearts))
      assert length(Knowledge.unseen_trumps(view)) == 14 - 4
    end
  end
end
