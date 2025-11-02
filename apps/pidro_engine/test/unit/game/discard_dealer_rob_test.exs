defmodule Pidro.Game.DiscardDealerRobTest do
  @moduledoc """
  Comprehensive unit tests for dealer robbing edge cases in Finnish Pidro.

  According to specs/redeal.md and masterplan-redeal.md lines 586-599, the dealer robbing sequence is:
  1. Dealer keeps their current hand (trump cards only)
  2. Dealer takes ALL remaining undealt cards from deck
  3. Dealer combines: their_hand ++ remaining_deck_cards
  4. Dealer privately views this combined pool
  5. Dealer selects the best 6 cards from this pool
  6. Dealer discards the rest face-down

  Tests cover:
  - Pool combination and size tracking
  - Card selection validation
  - Event emission with counts only (no card lists for info hiding)
  - Phase transitions
  - Turn management
  - Edge cases (no cards available, >6 trump scenario)
  """
  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Game.Discard

  # =============================================================================
  # Test Helpers
  # =============================================================================

  # Creates a game state ready for dealer to rob the pack.
  defp setup_dealer_rob_state(opts \\ []) do
    dealer = Keyword.get(opts, :dealer, :north)
    dealer_hand = Keyword.get(opts, :dealer_hand, [{14, :hearts}, {13, :hearts}])

    remaining_deck =
      Keyword.get(opts, :remaining_deck, [
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ])

    state = GameState.new()
    dealer_player = %{Map.get(state.players, dealer) | hand: dealer_hand}
    updated_players = Map.put(state.players, dealer, dealer_player)

    %{
      state
      | phase: :second_deal,
        current_dealer: dealer,
        current_turn: dealer,
        trump_suit: :hearts,
        players: updated_players,
        deck: remaining_deck
    }
  end

  # =============================================================================
  # Test: Dealer combines hand ++ remaining_deck into pool
  # =============================================================================

  describe "dealer_rob_pack/2 - pool combination" do
    test "dealer combines their hand with remaining deck cards" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      # Dealer should have access to 2 (hand) + 4 (deck) = 6 cards total
      # Selecting all 6 should succeed
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.players[:north].hand == selected
      assert new_state.dealer_pool_size == 6
    end

    test "dealer can select from any card in combined pool" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      # Dealer selects mix of cards from hand and deck
      selected = [
        {14, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts},
        {13, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert length(new_state.players[:north].hand) == 6
      assert new_state.phase == :playing
    end

    test "dealer with large pool selects best 6 cards" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {12, :hearts}],
          remaining_deck: [
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts},
            {7, :hearts},
            {6, :hearts},
            {5, :hearts}
          ]
        )

      # Dealer has 3 + 7 = 10 cards to choose from
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.dealer_pool_size == 10
      assert length(new_state.players[:north].hand) == 6
    end
  end

  # =============================================================================
  # Test: Dealer selects exactly 6 cards from pool
  # =============================================================================

  describe "dealer_rob_pack/2 - card count validation" do
    test "dealer must select exactly 6 cards" do
      state = setup_dealer_rob_state()

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert length(new_state.players[:north].hand) == 6
    end

    test "error when dealer selects less than 6 cards" do
      state = setup_dealer_rob_state()

      selected = [{14, :hearts}, {13, :hearts}, {12, :hearts}]
      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:invalid_card_count, 6, 3}} = result
    end

    test "error when dealer selects more than 6 cards" do
      state = setup_dealer_rob_state()

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts},
        {8, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:invalid_card_count, 6, 7}} = result
    end

    test "error when dealer selects 0 cards" do
      state = setup_dealer_rob_state()

      result = Discard.dealer_rob_pack(state, [])

      assert {:error, {:invalid_card_count, 6, 0}} = result
    end
  end

  # =============================================================================
  # Test: dealer_pool_size tracked (dealer hand size + remaining deck)
  # =============================================================================

  describe "dealer_rob_pack/2 - dealer_pool_size tracking" do
    test "dealer_pool_size equals hand size + remaining deck size" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {12, :hearts}, {9, :hearts}],
          remaining_deck: [{11, :hearts}, {10, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Pool size should be 4 (hand) + 2 (deck) = 6
      assert new_state.dealer_pool_size == 6
    end

    test "dealer_pool_size with minimal cards" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [
            {14, :hearts},
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts}
          ],
          remaining_deck: []
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Pool size should be 6 (hand) + 0 (deck) = 6
      assert new_state.dealer_pool_size == 6
    end

    test "dealer_pool_size with maximum realistic cards" do
      # Dealer had 2 trump, gets 10 more from deck
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts},
            {7, :hearts},
            {6, :hearts},
            {5, :hearts},
            {4, :hearts},
            {3, :hearts}
          ]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Pool size should be 2 (hand) + 10 (deck) = 12
      assert new_state.dealer_pool_size == 12
    end
  end

  # =============================================================================
  # Test: Dealer can select ANY 6 cards (including discarding trump)
  # =============================================================================

  describe "dealer_rob_pack/2 - card selection freedom" do
    test "dealer can discard trump cards if desired" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {12, :hearts}],
          remaining_deck: [{11, :hearts}, {10, :hearts}, {9, :hearts}, {8, :hearts}]
        )

      # Dealer chooses to keep middle-value trumps, discarding Ace
      selected = [
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts},
        {8, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.players[:north].hand == selected
      assert {14, :hearts} in new_state.discarded_cards
    end

    test "dealer can select all cards from deck, discarding original hand" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{7, :hearts}, {6, :hearts}],
          remaining_deck: [
            {14, :hearts},
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {5, :hearts}
          ]
        )

      # Dealer discards original hand, keeps all deck cards
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.players[:north].hand == selected
      assert {7, :hearts} in new_state.discarded_cards
      assert {6, :hearts} in new_state.discarded_cards
    end

    test "dealer can mix cards from hand and deck freely" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {7, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {6, :hearts}]
        )

      # Dealer keeps high cards from hand, high cards from deck, discards low from both
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {7, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.players[:north].hand == selected
      assert {6, :hearts} in new_state.discarded_cards
    end
  end

  # =============================================================================
  # Test: Unselected cards go to discard pile
  # =============================================================================

  describe "dealer_rob_pack/2 - discard pile management" do
    test "unselected cards are added to discard pile" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      initial_discard_count = length(state.discarded_cards)

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # All cards selected, so no new discards
      assert length(new_state.discarded_cards) == initial_discard_count
    end

    test "discarded cards are removed from game" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {7, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {6, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {7, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # {6, :hearts} should be in discard pile
      assert {6, :hearts} in new_state.discarded_cards
      assert {6, :hearts} not in new_state.players[:north].hand
    end

    test "multiple discarded cards all added to pile" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts},
            {7, :hearts},
            {6, :hearts}
          ]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      initial_discard_count = length(state.discarded_cards)

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # 3 cards discarded: {8, :hearts}, {7, :hearts}, {6, :hearts}
      assert length(new_state.discarded_cards) == initial_discard_count + 3
      assert {8, :hearts} in new_state.discarded_cards
      assert {7, :hearts} in new_state.discarded_cards
      assert {6, :hearts} in new_state.discarded_cards
    end
  end

  # =============================================================================
  # Test: Error - Dealer selects cards not in pool
  # =============================================================================

  describe "dealer_rob_pack/2 - invalid card selection" do
    test "error when dealer selects card not in pool" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      # Try to select a card not in dealer's pool
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {8, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:card_not_in_hand, {8, :hearts}}} = result
    end

    test "error when dealer selects card from another player's hand" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      # Add a card to another player's hand
      east_player = %{Map.get(state.players, :east) | hand: [{5, :diamonds}]}
      state = put_in(state.players[:east], east_player)

      # Try to select that card
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :diamonds}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:card_not_in_hand, {5, :diamonds}}} = result
    end

    test "error when dealer selects already discarded card" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      # Add a card to discard pile
      state = %{state | discarded_cards: [{8, :hearts}]}

      # Try to select that discarded card
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {8, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:card_not_in_hand, {8, :hearts}}} = result
    end
  end

  # =============================================================================
  # Test: dealer_robbed_pack event emitted with counts only
  # =============================================================================

  describe "dealer_rob_pack/2 - event emission" do
    test "dealer_robbed_pack event is emitted" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Event should be in events list
      assert {:dealer_robbed_pack, :north, 4, 6} in new_state.events
    end

    test "event contains dealer position, taken count, and kept count" do
      state =
        setup_dealer_rob_state(
          dealer: :south,
          dealer_hand: [{14, :hearts}, {13, :hearts}, {12, :hearts}],
          remaining_deck: [{11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Event format: {:dealer_robbed_pack, dealer, taken_count, kept_count}
      event =
        Enum.find(new_state.events, fn e ->
          match?({:dealer_robbed_pack, _, _, _}, e)
        end)

      assert {:dealer_robbed_pack, :south, 3, 6} = event
    end

    test "event does not contain card lists (information hiding)" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Find the dealer_robbed_pack event
      event =
        Enum.find(new_state.events, fn e ->
          match?({:dealer_robbed_pack, _, _, _}, e)
        end)

      # Verify event only contains counts, not card lists
      {:dealer_robbed_pack, _position, taken_count, kept_count} = event
      assert is_integer(taken_count)
      assert is_integer(kept_count)
    end

    test "taken count equals remaining deck size" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts}
          ]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      {:dealer_robbed_pack, _position, taken_count, _kept_count} =
        Enum.find(new_state.events, fn e -> match?({:dealer_robbed_pack, _, _, _}, e) end)

      assert taken_count == 5
    end

    test "kept count always equals 6" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}],
          remaining_deck: [
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts},
            {7, :hearts}
          ]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      {:dealer_robbed_pack, _position, _taken_count, kept_count} =
        Enum.find(new_state.events, fn e -> match?({:dealer_robbed_pack, _, _, _}, e) end)

      assert kept_count == 6
    end
  end

  # =============================================================================
  # Test: Phase transitions to :playing after rob complete
  # =============================================================================

  describe "dealer_rob_pack/2 - phase transition" do
    test "phase transitions from :second_deal to :playing" do
      state = setup_dealer_rob_state()

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert state.phase == :second_deal
      assert new_state.phase == :playing
    end

    test "error if phase is not :second_deal" do
      state = setup_dealer_rob_state()
      state = %{state | phase: :playing}

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:invalid_phase, :second_deal, :playing}} = result
    end

    test "error if phase is :bidding" do
      state = setup_dealer_rob_state()
      state = %{state | phase: :bidding}

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:invalid_phase, :second_deal, :bidding}} = result
    end
  end

  # =============================================================================
  # Test: Current turn set to left of dealer after rob
  # =============================================================================

  describe "dealer_rob_pack/2 - turn management" do
    test "turn advances to left of dealer (north -> east)" do
      state = setup_dealer_rob_state(dealer: :north)

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.current_turn == :east
    end

    test "turn advances to left of dealer (east -> south)" do
      state = setup_dealer_rob_state(dealer: :east)

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.current_turn == :south
    end

    test "turn advances to left of dealer (south -> west)" do
      state = setup_dealer_rob_state(dealer: :south)

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.current_turn == :west
    end

    test "turn advances to left of dealer (west -> north)" do
      state = setup_dealer_rob_state(dealer: :west)

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.current_turn == :north
    end

    test "error if it's not dealer's turn" do
      state = setup_dealer_rob_state(dealer: :north)
      state = %{state | current_turn: :east}

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:not_dealer_turn, :north, :east}} = result
    end
  end

  # =============================================================================
  # Test: Edge case - Dealer gets no cards when all dealt to non-dealers
  # =============================================================================

  describe "dealer_rob_pack/2 - edge case: no remaining cards" do
    test "dealer with 6 cards and empty deck can rob" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [
            {14, :hearts},
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts}
          ],
          remaining_deck: []
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.dealer_pool_size == 6
      assert new_state.players[:north].hand == selected
      assert length(new_state.deck) == 0
    end

    test "dealer with 7 cards and empty deck selects 6" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [
            {14, :hearts},
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts}
          ],
          remaining_deck: []
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.dealer_pool_size == 7
      assert length(new_state.players[:north].hand) == 6
      assert {8, :hearts} in new_state.discarded_cards
    end

    test "taken count is 0 when deck is empty" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [
            {14, :hearts},
            {13, :hearts},
            {12, :hearts},
            {11, :hearts},
            {10, :hearts},
            {9, :hearts}
          ],
          remaining_deck: []
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      {:dealer_robbed_pack, _position, taken_count, _kept_count} =
        Enum.find(new_state.events, fn e -> match?({:dealer_robbed_pack, _, _, _}, e) end)

      assert taken_count == 0
    end
  end

  # =============================================================================
  # Test: Edge case - Dealer has >6 trump after robbing
  # =============================================================================

  describe "dealer_rob_pack/2 - edge case: dealer with >6 trump scenario" do
    test "dealer can select 6 from larger pool following kill rules" do
      # This test verifies the dealer CAN select 6 cards even if pool has >6 trump
      # The actual kill rule enforcement is handled in a separate module
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}, {12, :hearts}],
          remaining_deck: [
            {11, :hearts},
            {10, :hearts},
            {9, :hearts},
            {8, :hearts},
            {7, :hearts},
            {6, :hearts},
            {5, :hearts},
            {4, :hearts}
          ]
        )

      # Dealer has 3 + 8 = 11 trump cards to choose from
      # Dealer must select exactly 6 per rob rules
      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.dealer_pool_size == 11
      assert length(new_state.players[:north].hand) == 6
      assert new_state.phase == :playing
    end

    test "dealer with many point cards can still select any 6" do
      # Dealer has lots of point cards in pool
      state =
        setup_dealer_rob_state(
          # A, J, 10 (point cards)
          dealer_hand: [{14, :hearts}, {11, :hearts}, {10, :hearts}],
          remaining_deck: [
            # Right 5 (point card)
            {5, :hearts},
            # Wrong 5 (point card)
            {5, :diamonds},
            # 2 (point card)
            {2, :hearts},
            # K (non-point)
            {13, :hearts},
            # Q (non-point)
            {12, :hearts},
            # 9 (non-point)
            {9, :hearts}
          ]
        )

      # Dealer chooses all 6 point cards (allowed in rob phase)
      selected = [
        {14, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts},
        {5, :diamonds},
        {2, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert length(new_state.players[:north].hand) == 6
      # Non-point cards should be discarded
      assert {13, :hearts} in new_state.discarded_cards
      assert {12, :hearts} in new_state.discarded_cards
      assert {9, :hearts} in new_state.discarded_cards
    end

    test "deck is empty after dealer robs" do
      state =
        setup_dealer_rob_state(
          dealer_hand: [{14, :hearts}, {13, :hearts}],
          remaining_deck: [{12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
        )

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      assert new_state.deck == []
    end
  end

  # =============================================================================
  # Test: Additional validation edge cases
  # =============================================================================

  describe "dealer_rob_pack/2 - additional validations" do
    test "error when no dealer is set" do
      state = setup_dealer_rob_state()
      state = %{state | current_dealer: nil}

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      result = Discard.dealer_rob_pack(state, selected)

      assert {:error, {:no_dealer, _}} = result
    end

    test "works with different dealers" do
      for dealer <- [:north, :east, :south, :west] do
        state = setup_dealer_rob_state(dealer: dealer)

        selected = [
          {14, :hearts},
          {13, :hearts},
          {12, :hearts},
          {11, :hearts},
          {10, :hearts},
          {9, :hearts}
        ]

        {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

        assert new_state.players[dealer].hand == selected
        assert new_state.phase == :playing
      end
    end

    test "dealer's hand is updated, other players unchanged" do
      state = setup_dealer_rob_state(dealer: :north)

      # Set up other players' hands
      east_hand = [{5, :diamonds}, {4, :diamonds}]
      south_hand = [{6, :clubs}, {7, :clubs}, {8, :clubs}]
      west_hand = [{9, :spades}]

      state = put_in(state.players[:east].hand, east_hand)
      state = put_in(state.players[:south].hand, south_hand)
      state = put_in(state.players[:west].hand, west_hand)

      selected = [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts}
      ]

      {:ok, new_state} = Discard.dealer_rob_pack(state, selected)

      # Dealer's hand changed
      assert new_state.players[:north].hand == selected

      # Other players' hands unchanged
      assert new_state.players[:east].hand == east_hand
      assert new_state.players[:south].hand == south_hand
      assert new_state.players[:west].hand == west_hand
    end
  end
end
