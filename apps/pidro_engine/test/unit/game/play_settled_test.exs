defmodule Pidro.Game.PlaySettledTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Card
  alias Pidro.Game.{Engine, Play}
  alias Pidro.Test.Scenario

  @positions [:north, :east, :south, :west]
  @first_trick [[north: 13, east: 14, south: 8, west: 11]]

  defp lone_holder(holder, hand) do
    Scenario.playing(
      me: holder,
      hands: %{holder => hand},
      cold: List.delete(@positions, holder),
      tricks: @first_trick
    )
  end

  describe "settled_play/1" do
    test "a lone holder leading plays their highest trump, whichever seat holds them" do
      for holder <- [:south, :east] do
        assert Play.settled_play(lone_holder(holder, [2, 12, :off5])) ==
                 {holder, {12, :hearts}}
      end
    end

    test "is not settled while two players still hold trumps" do
      state =
        Scenario.playing(
          me: :south,
          hands: %{south: [14, 2], west: [10]},
          cold: [:north, :east],
          tricks: @first_trick
        )

      assert Play.settled_play(state) == nil
    end

    test "is not settled inside a trick led by a player who then went cold" do
      state =
        Scenario.playing(
          me: :north,
          hands: %{north: [14, 2]},
          cold: [:east, :south, :west],
          trick: [west: 9]
        )

      assert Play.settled_play(state) == nil
    end

    test "Louisiana never settles, as its players never go cold" do
      state =
        Scenario.playing(
          me: :north,
          hands: %{
            north: [14, 2],
            south: [{9, :clubs}, {8, :clubs}],
            east: [{9, :spades}, {8, :spades}],
            west: [{10, :clubs}, {7, :clubs}]
          }
        )

      assert Play.settled_play(%{state | variant: :louisiana}) == nil
    end

    test "playing out the sweep scores the same as any other order" do
      state = lone_holder(:south, [2, 3, 10, :off5, 5])

      swept = play_out(state, fn s -> elem(Play.settled_play(s), 1) end)

      lowest_first =
        play_out(state, fn s ->
          s
          |> Play.legal_plays(:south)
          |> Enum.min_by(& &1, &(Card.compare(&1, &2, :hearts) != :gt))
        end)

      assert swept.hand_number == state.hand_number + 1
      assert swept.cumulative_scores == lowest_first.cumulative_scores
      assert swept.cumulative_scores == %{north_south: 12, east_west: 2}
    end
  end

  defp play_out(%{phase: :playing} = state, pick) do
    {:ok, state} = Engine.apply_action(state, :south, {:play_card, pick.(state)})
    play_out(state, pick)
  end

  defp play_out(state, _pick), do: state
end
