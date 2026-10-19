defmodule Pidro.Game.PlayColdPlayerTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Core.Types
  alias Pidro.Core.Types.Player
  alias Pidro.Game.{Engine, Play}
  alias Pidro.Test.Scenario

  describe "cold players at start of play" do
    test "players with no trumps are eliminated before they can block the turn" do
      players = %{
        north: %Player{
          position: :north,
          team: :north_south,
          hand: [{10, :clubs}],
          eliminated?: false
        },
        east: %Player{
          position: :east,
          team: :east_west,
          hand: [{14, :hearts}, {12, :spades}],
          eliminated?: false
        },
        south: %Player{
          position: :south,
          team: :north_south,
          hand: [{9, :clubs}],
          eliminated?: false
        },
        west: %Player{
          position: :west,
          team: :east_west,
          hand: [{14, :clubs}],
          eliminated?: false
        }
      }

      state = %{
        GameState.new(seed: 1)
        | phase: :playing,
          trump_suit: :clubs,
          current_turn: :east,
          players: players,
          events: []
      }

      new_state = Play.compute_kills(state)

      assert new_state.players.east.eliminated?
      assert new_state.players.east.hand == []
      assert new_state.players.east.revealed_cards == [{14, :hearts}, {12, :spades}]
      assert new_state.current_turn == :south

      assert {:player_went_cold, :east, [{14, :hearts}, {12, :spades}]} in new_state.events
    end

    test "current turn becomes nil when every player is cold" do
      players =
        Types.all_positions()
        |> Map.new(fn position ->
          {position,
           %Player{
             position: position,
             team: Types.position_to_team(position),
             hand: [{14, :hearts}],
             eliminated?: false
           }}
        end)

      state = %{
        GameState.new(seed: 1)
        | phase: :playing,
          trump_suit: :clubs,
          current_turn: :north,
          players: players,
          events: []
      }

      new_state = Play.compute_kills(state)

      assert Enum.all?(new_state.players, fn {_position, player} -> player.eliminated? end)
      assert new_state.current_turn == nil
    end

    test "a player without trumps who does not lead stays in until the turn reaches them" do
      state =
        Scenario.playing(me: :north, hands: %{north: [14, 2], east: [{10, :clubs}, {9, :spades}]})
        |> Play.compute_kills()

      refute state.players.east.eliminated?
      assert state.current_turn == :north

      state = play(state, :north, {14, :hearts})

      assert state.players.east.eliminated?
      assert state.players.east.revealed_cards == [{10, :clubs}, {9, :spades}]
      assert state.current_turn == :south
    end
  end

  describe "going out on your turn" do
    # The reported table: Antti (east) plays his last trump, Jocke (west)
    # takes the trick and leads the next, I (north) follow, and only then is
    # it Antti's turn, with nothing to play.
    test "a player who plays their last trump goes out on their next turn, not at once" do
      state =
        Scenario.playing(
          me: :east,
          hands: %{west: [9, 4], north: [13, 12], east: [3, {10, :clubs}], south: [7, 8]},
          trick: [west: 14, north: 6],
          tricks: [[north: 10, east: :off5, south: 2, west: 11]]
        )

      state = play(state, :east, {3, :hearts})
      refute state.players.east.eliminated?
      assert state.players.east.hand == [{10, :clubs}]
      assert state.current_turn == :south

      state = play(state, :south, {7, :hearts})
      assert List.last(state.tricks).winner == :west
      assert state.current_turn == :west
      refute state.players.east.eliminated?

      state = play(state, :west, {9, :hearts})
      assert state.current_turn == :north
      refute state.players.east.eliminated?

      state = play(state, :north, {13, :hearts})
      assert state.players.east.eliminated?
      assert state.players.east.revealed_cards == [{10, :clubs}]
      assert state.current_turn == :south

      assert Enum.take(play_events(state), -2) == [
               {:card_played, :north, {13, :hearts}},
               {:player_went_cold, :east, [{10, :clubs}]}
             ]

      state = play(state, :south, {8, :hearts})
      assert [{:west, _}, {:north, _}, {:south, _}] = List.last(state.tricks).plays
    end

    test "two players without trumps go out back to back, and the turn passes them both" do
      state =
        Scenario.playing(
          me: :north,
          hands: %{north: [14, 13], east: [{10, :clubs}], south: [{9, :clubs}], west: [12, 11]}
        )

      state = play(state, :north, {14, :hearts})

      assert state.current_turn == :west

      assert Enum.take(play_events(state), -2) == [
               {:player_went_cold, :east, [{10, :clubs}]},
               {:player_went_cold, :south, [{9, :clubs}]}
             ]

      state = play(state, :west, {12, :hearts})
      assert [{:north, _}, {:west, _}] = List.last(state.tricks).plays
      assert state.current_turn == :north
    end

    test "a lone holder's sweep starts once the others have gone out on their turns" do
      state =
        Scenario.playing(
          me: :south,
          hands: %{
            south: [2, 10, 12, :off5, 5],
            west: [{8, :clubs}],
            north: [{10, :clubs}],
            east: [{9, :clubs}]
          },
          tricks: [[north: 13, east: 11, south: 14, west: 8]]
        )

      assert Play.settled_play(state) == nil

      state = play(state, :south, {2, :hearts})
      assert Enum.all?([:west, :north, :east], &state.players[&1].eliminated?)
      assert [{:south, {2, :hearts}}] = List.last(state.tricks).plays
      assert Play.settled_play(state) == {:south, {12, :hearts}}

      state = sweep(state)
      assert state.cumulative_scores == %{north_south: 14, east_west: 0}
    end
  end

  defp play(state, position, card) do
    {:ok, state} = Engine.apply_action(state, position, {:play_card, card})
    state
  end

  # Every action also logs the kill check on entering play; leave it out.
  defp play_events(state), do: Enum.reject(state.events, &match?({:cards_killed, _}, &1))

  defp sweep(%{phase: :playing} = state) do
    {position, card} = Play.settled_play(state)
    sweep(play(state, position, card))
  end

  defp sweep(state), do: state
end
