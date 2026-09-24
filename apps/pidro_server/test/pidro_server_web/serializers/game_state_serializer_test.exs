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
