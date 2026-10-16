defmodule PidroServerWeb.Serializers.GameStateSerializerTest do
  @moduledoc """
  The serializer is an allow-list, so a field added to `%GameState{}` stays out
  of client payloads until somebody adds it here on purpose. The game's chance
  stream is the field where that matters most: the rest of the deck follows
  from it, so a client that saw it could read the hands it has not been dealt
  yet.

  These tests assert the containment rather than assuming it.
  """

  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Game.{Dealing, Engine}
  alias PidroServerWeb.Serializers.GameStateSerializer

  # A state with cuts drawn, a shuffled deck and dealt hands — everything the
  # chance stream has produced so far.
  defp dealt_state do
    {:ok, cut} = Dealing.select_dealer(GameState.new(seed: 1))
    {:ok, dealt} = Engine.advance_from_dealer_selection(cut)

    dealt
  end

  # `term_to_binary/1` prefixes a version byte that never recurs inside a term,
  # so it has to come off before the encoding can be used as a needle.
  defp encoded_chance(chance) do
    encoded = :erlang.term_to_binary(chance)
    binary_part(encoded, 1, byte_size(encoded) - 1)
  end

  describe "serialize/2" do
    test "trick signals are additive and finished points exclude the trump two" do
      for variant <- [:finnish, :louisiana] do
        trick = %Pidro.Core.Types.Trick{
          number: 1,
          leader: :north,
          plays: [{:north, {5, :diamonds}}, {:east, {2, :hearts}}, {:south, {10, :hearts}}]
        }

        state = %{dealt_state() | variant: variant, trump_suit: :hearts, current_trick: trick}
        payload = GameStateSerializer.serialize(state)
        plays = GameStateSerializer.serialize_plays(trick.plays)

        assert payload.current_trick == plays
        assert payload.current_trick_details.plays == plays
        assert payload.current_trick_details.cards == plays
        assert payload.current_trick_details.winner == nil

        assert payload.current_trick_details.winning ==
                 %{position: :south, card: %{rank: 10, suit: :hearts}}

        assert payload.current_trick_details.points == 6
        assert payload.current_trick_details.two_of_trump == %{position: :east, points: 1}
        assert payload.scores == payload.cumulative_scores
        assert payload.hand_points == state.hand_points

        {:ok, finished} = Pidro.Game.Play.complete_trick(state)
        [completed] = GameStateSerializer.serialize(finished).tricks
        assert completed.winner == :south
        assert completed.points == 6
        assert completed.two_of_trump == %{position: :east, points: 1}
        assert completed.plays == plays
        assert completed.cards == plays
      end
    end

    test "the last hand's bids, trump and tricks have the live fields' shapes" do
      finished =
        1
        |> Pidro.Test.DeterministicGame.opening()
        |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 2))

      last_hand = finished.last_hand
      assert [_ | _] = last_hand.tricks
      assert [_ | _] = last_hand.bids
      assert finished.tricks == [] and finished.bids == [] and finished.trump_suit == nil

      payload = GameStateSerializer.serialize(finished)

      # The same hand as it would have been serialized live, before the reset.
      live =
        GameStateSerializer.serialize(%{
          finished
          | tricks: last_hand.tricks,
            bids: last_hand.bids,
            trump_suit: last_hand.trump
        })

      assert payload.last_hand.tricks == live.tricks
      assert payload.last_hand.bids == live.bids
      assert payload.last_hand.trump == live.trump_suit
      assert payload.last_hand.trump in [:hearts, :diamonds, :clubs, :spades]

      assert Map.drop(payload.last_hand, [:bids, :trump, :tricks, :point_cards]) ==
               Map.drop(last_hand, [:bids, :trump, :tricks, :point_cards])

      assert payload.last_hand.point_cards ==
               Enum.map(last_hand.point_cards, fn %{card: {rank, suit}} = point_card ->
                 %{point_card | card: %{rank: rank, suit: suit}}
               end)

      assert payload.hand_history == [Map.drop(payload.last_hand, [:bids, :tricks])]

      wire = payload |> Jason.encode!() |> Jason.decode!()
      live_wire = live |> Jason.encode!() |> Jason.decode!()
      assert wire["last_hand"]["tricks"] == live_wire["tricks"]
      assert wire["last_hand"]["bids"] == live_wire["bids"]
      assert wire["last_hand"]["trump"] == live_wire["trump_suit"]
    end

    test "a cold player's revealed cards reach every viewer" do
      state = dealt_state()

      cold = %{
        state.players.east
        | eliminated?: true,
          revealed_cards: [{9, :clubs}, {4, :spades}]
      }

      state = %{state | players: %{state.players | east: cold}}

      for viewer <- [nil, :north, :east] do
        east = GameStateSerializer.serialize(state, viewer).players.east
        assert east.eliminated
        assert east.revealed_cards == [%{rank: 9, suit: :clubs}, %{rank: 4, suit: :spades}]
      end

      assert GameStateSerializer.serialize(state).players.north.revealed_cards == []
    end

    test "absent and empty current tricks retain their existing shapes" do
      state = dealt_state()
      payload = GameStateSerializer.serialize(state)
      assert payload.current_trick == []
      assert payload.current_trick_details == nil
      assert payload.last_hand == nil
      assert payload.hand_history == []

      empty = %Pidro.Core.Types.Trick{number: 1, leader: :north}

      payload =
        GameStateSerializer.serialize(%{state | current_trick: empty, trump_suit: :hearts})

      assert payload.current_trick == []
      assert payload.current_trick_details.winning == nil
      assert payload.current_trick_details.points == 0
      assert payload.current_trick_details.two_of_trump == nil
    end

    test "the payload has no :chance key" do
      state = dealt_state()

      assert state.chance != nil
      refute Map.has_key?(GameStateSerializer.serialize(state), :chance)
      refute Map.has_key?(GameStateSerializer.serialize(state, :north), :chance)
      refute Map.has_key?(GameStateSerializer.serialize_public(state), :chance)
    end

    test "the payload mentions nothing of the chance stream" do
      state = dealt_state()
      payload = GameStateSerializer.serialize(state, :north)

      # The algorithm tag would be the giveaway if the value leaked whole or in
      # part, under this name or any other.
      refute payload |> inspect(limit: :infinity) |> String.contains?("exsss")

      assert :binary.match(:erlang.term_to_binary(payload), encoded_chance(state.chance)) ==
               :nomatch

      # Control: the same search finds the stream in the state itself, so the
      # assertion above is testing something.
      assert :binary.match(:erlang.term_to_binary(state), encoded_chance(state.chance)) !=
               :nomatch
    end

    test "serializing a state whose chance differs produces the same payload" do
      state = dealt_state()
      restreamed = %{state | chance: GameState.new(seed: 99).chance}

      assert GameStateSerializer.serialize(state, :north) ==
               GameStateSerializer.serialize(restreamed, :north)
    end
  end
end
