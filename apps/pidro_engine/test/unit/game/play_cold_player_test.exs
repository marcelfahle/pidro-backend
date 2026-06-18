defmodule Pidro.Game.PlayColdPlayerTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Types
  alias Pidro.Core.Types.{GameState, Player}
  alias Pidro.Game.Play

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

      state = %GameState{
        phase: :playing,
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

      state = %GameState{
        phase: :playing,
        trump_suit: :clubs,
        current_turn: :north,
        players: players,
        events: []
      }

      new_state = Play.compute_kills(state)

      assert Enum.all?(new_state.players, fn {_position, player} -> player.eliminated? end)
      assert new_state.current_turn == nil
    end
  end
end
