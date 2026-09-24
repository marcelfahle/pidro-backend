defmodule Pidro.Properties.DealingPropertiesTest do
  @moduledoc """
  Property-based tests for the Dealing module using StreamData.

  These tests verify fundamental invariants of the Finnish Pidro dealing
  system, asserted against `Pidro.Game.Dealing` itself rather than a
  hand-rolled simulation of it:
  - The initial deal gives exactly 9 cards to each of the 4 players
  - Cards are dealt in batches of 3, clockwise from the left of the dealer
  - After the initial deal exactly 16 cards remain in the deck (the "kitty")
  - Cards are conserved: every card is in exactly one hand or in the deck
  - The deal is a pure function of the state it was given

  Related to Phase 3 of the masterplan: Dealer Selection and Initial Deal
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Chance, Deck, GameState, Types}
  alias Pidro.Game.Dealing

  @positions [:north, :east, :south, :west]

  # =============================================================================
  # Generators
  # =============================================================================

  @doc """
  Generates a position for the dealer.
  """
  def position do
    StreamData.member_of(@positions)
  end

  @doc """
  Generates a seed for the chance stream a deck is shuffled from.
  """
  def seed do
    StreamData.integer(1..1_000_000)
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  # A game ready to deal: a dealer, and `Deck.ordered/0` permuted by the
  # state's own explicit chance stream. Nothing here draws from the calling
  # process's RNG.
  defp ready_to_deal(seed, dealer) do
    state = GameState.new(seed: seed)
    {deck, chance} = Chance.shuffle(Deck.ordered(), state.chance)

    %{state | deck: deck, chance: chance, current_dealer: dealer}
  end

  defp hands(state) do
    Map.new(state.players, fn {pos, player} -> {pos, player.hand} end)
  end

  # The four seats in dealing order: the dealer's left, then clockwise.
  defp deal_order(dealer) do
    first = Types.next_position(dealer)

    [first | Enum.scan(1..3, first, fn _i, previous -> Types.next_position(previous) end)]
  end

  # =============================================================================
  # Property: Initial Deal Gives Exactly 9 Cards to Each Player
  # =============================================================================

  property "the initial deal gives exactly 9 cards to each player" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, dealt} = Dealing.deal_initial(ready_to_deal(seed, dealer))

      for {position, hand} <- hands(dealt) do
        assert length(hand) == 9,
               "#{position} should hold 9 cards, got #{length(hand)}"
      end
    end
  end

  property "after the initial deal exactly 16 cards remain in the deck (the kitty)" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, dealt} = Dealing.deal_initial(ready_to_deal(seed, dealer))

      assert length(dealt.deck) == 16,
             "After dealing 9 cards to 4 players, 16 cards should remain"

      assert length(Enum.uniq(dealt.deck)) == 16,
             "All 16 cards in the kitty should be distinct"

      for {rank, suit} <- dealt.deck do
        assert rank in 2..14
        assert suit in [:hearts, :diamonds, :clubs, :spades]
      end
    end
  end

  # =============================================================================
  # Property: Cards Are Conserved by the Deal
  # =============================================================================

  property "every card ends up in exactly one hand or in the deck" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      state = ready_to_deal(seed, dealer)
      {:ok, dealt} = Dealing.deal_initial(state)

      all_cards = Enum.flat_map(@positions, fn pos -> hands(dealt)[pos] end) ++ dealt.deck

      assert Enum.sort(all_cards) == Enum.sort(state.deck),
             "Hands + deck should be exactly the deck that was dealt from"

      assert length(Enum.uniq(all_cards)) == 52,
             "No card should be dealt twice"
    end
  end

  property "no two hands share a card" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, dealt} = Dealing.deal_initial(ready_to_deal(seed, dealer))
      hands = hands(dealt)

      for {pos1, idx1} <- Enum.with_index(@positions),
          {pos2, idx2} <- Enum.with_index(@positions),
          idx1 < idx2 do
        overlap = MapSet.intersection(MapSet.new(hands[pos1]), MapSet.new(hands[pos2]))

        assert MapSet.size(overlap) == 0,
               "#{pos1} and #{pos2} should not share cards, shared #{inspect(overlap)}"
      end
    end
  end

  property "no hand holds a card that is still in the deck" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, dealt} = Dealing.deal_initial(ready_to_deal(seed, dealer))
      kitty = MapSet.new(dealt.deck)

      for {position, hand} <- hands(dealt) do
        overlap = MapSet.intersection(MapSet.new(hand), kitty)

        assert MapSet.size(overlap) == 0,
               "#{position} holds #{inspect(overlap)}, which is still in the deck"
      end
    end
  end

  # =============================================================================
  # Property: Cards Are Dealt in 3-Card Batches, Clockwise From the Dealer's Left
  # =============================================================================

  property "dealing starts to the left of the dealer and passes them the turn" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, dealt} = Dealing.deal_initial(ready_to_deal(seed, dealer))

      assert dealt.current_turn == Types.next_position(dealer),
             "The player left of the dealer leads"
    end
  end

  property "each hand is three 3-card batches taken clockwise from the dealer's left" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      state = ready_to_deal(seed, dealer)
      {:ok, dealt} = Dealing.deal_initial(state)
      hands = hands(dealt)

      deal_order = deal_order(dealer)

      # Three rounds of one 3-card batch per seat, off the top of the deck.
      expected =
        for {position, seat_index} <- Enum.with_index(deal_order), into: %{} do
          cards =
            Enum.flat_map(0..2, fn round ->
              offset = (round * 4 + seat_index) * 3
              Enum.slice(state.deck, offset, 3)
            end)

          {position, cards}
        end

      assert hands == expected,
             "Hands should be the 3-card batches dealt clockwise from #{dealer}'s left"

      assert dealt.deck == Enum.drop(state.deck, 36),
             "The kitty should be the untouched tail of the deck"
    end
  end

  # =============================================================================
  # Property: The Deal Is a Pure Function of the State It Was Given
  # =============================================================================

  property "dealing the same state twice deals the same cards" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      state = ready_to_deal(seed, dealer)

      {:ok, first} = Dealing.deal_initial(state)
      {:ok, second} = Dealing.deal_initial(state)

      assert hands(first) == hands(second)
      assert first.deck == second.deck
    end
  end

  property "different chance streams deal different hands" do
    check all(seed <- seed(), dealer <- position(), max_runs: 100) do
      {:ok, first} = Dealing.deal_initial(ready_to_deal(seed, dealer))
      {:ok, second} = Dealing.deal_initial(ready_to_deal(seed + 1, dealer))

      refute hands(first) == hands(second)
    end
  end

  # =============================================================================
  # Property: The Deal Refuses a Deck It Cannot Serve
  # =============================================================================

  property "dealing from fewer than 36 cards is refused rather than short-dealt" do
    check all(
            seed <- seed(),
            dealer <- position(),
            deck_size <- StreamData.integer(0..35),
            max_runs: 100
          ) do
      state = ready_to_deal(seed, dealer)
      state = %{state | deck: Enum.take(state.deck, deck_size)}

      assert {:error, :insufficient_cards, message} = Dealing.deal_initial(state)
      assert message =~ "#{deck_size} available"
    end
  end

  property "dealing without a dealer is refused" do
    check all(seed <- seed(), max_runs: 100) do
      state = %{ready_to_deal(seed, :north) | current_dealer: nil}

      assert {:error, :no_dealer, _message} = Dealing.deal_initial(state)
    end
  end
end
