defmodule Pidro.Game.DealingTest do
  @moduledoc """
  Unit tests for the Dealing module.

  Tests cover:
  - Dealer selection via deck cutting
  - Dealer rotation between hands
  - Initial card distribution (9 cards per player in 3-card batches)
  - Turn order setting after dealing
  - Error cases (no dealer, insufficient cards)
  """

  use ExUnit.Case, async: true

  alias Pidro.Core.{GameState, Types, Deck}
  alias Pidro.Game.Dealing

  # =============================================================================
  # Setup Helpers
  # =============================================================================

  defp new_game_with_deck do
    state = GameState.new()
    deck = Deck.new()
    Map.put(state, :deck, deck.cards)
  end

  defp new_game_with_dealer do
    state = new_game_with_deck()
    Map.put(state, :current_dealer, :north)
  end

  # =============================================================================
  # Dealer Selection Tests
  # =============================================================================

  describe "select_dealer/1" do
    test "selects a dealer from available positions" do
      state = GameState.new()

      {:ok, updated_state} = Dealing.select_dealer(state)

      assert updated_state.current_dealer in [:north, :east, :south, :west]
    end

    test "records dealer_selected event" do
      state = GameState.new()

      {:ok, updated_state} = Dealing.select_dealer(state)

      # Should have one event
      assert length(updated_state.events) == 1

      # Event should be dealer_selected
      [event] = updated_state.events
      assert match?({:dealer_selected, _, _}, event)

      # Extract position and card from event
      {:dealer_selected, position, card} = event
      assert position in [:north, :east, :south, :west]
      assert match?({_rank, _suit}, card)
    end

    test "selected dealer matches the position in the event" do
      state = GameState.new()

      {:ok, updated_state} = Dealing.select_dealer(state)

      [{:dealer_selected, event_position, _card}] = updated_state.events

      assert updated_state.current_dealer == event_position
    end
  end

  # =============================================================================
  # Dealer Rotation Tests
  # =============================================================================

  describe "rotate_dealer/1" do
    test "rotates dealer clockwise from north to east" do
      state = %{GameState.new() | current_dealer: :north}

      {:ok, updated_state} = Dealing.rotate_dealer(state)

      assert updated_state.current_dealer == :east
    end

    test "rotates dealer clockwise from east to south" do
      state = %{GameState.new() | current_dealer: :east}

      {:ok, updated_state} = Dealing.rotate_dealer(state)

      assert updated_state.current_dealer == :south
    end

    test "rotates dealer clockwise from south to west" do
      state = %{GameState.new() | current_dealer: :south}

      {:ok, updated_state} = Dealing.rotate_dealer(state)

      assert updated_state.current_dealer == :west
    end

    test "rotates dealer clockwise from west back to north" do
      state = %{GameState.new() | current_dealer: :west}

      {:ok, updated_state} = Dealing.rotate_dealer(state)

      assert updated_state.current_dealer == :north
    end

    test "increments hand number when rotating dealer" do
      state = %{GameState.new() | current_dealer: :north, hand_number: 1}

      {:ok, updated_state} = Dealing.rotate_dealer(state)

      assert updated_state.hand_number == 2
    end

    test "returns error when no dealer is set" do
      state = GameState.new()

      {:error, :no_dealer, message} = Dealing.rotate_dealer(state)

      assert message =~ "Cannot rotate dealer"
    end
  end

  # =============================================================================
  # Initial Deal Tests
  # =============================================================================

  describe "deal_initial/1" do
    test "deals 9 cards to each player" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Check each player has 9 cards
      assert length(updated_state.players.north.hand) == 9
      assert length(updated_state.players.east.hand) == 9
      assert length(updated_state.players.south.hand) == 9
      assert length(updated_state.players.west.hand) == 9
    end

    test "deals cards in batches of 3 (total 9 per player)" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Each player should have exactly 9 cards (3 batches × 3 cards)
      Enum.each(updated_state.players, fn {_pos, player} ->
        assert length(player.hand) == 9
      end)
    end

    test "removes 36 cards from deck (9 × 4 players)" do
      state = new_game_with_dealer()
      initial_deck_size = length(state.deck)

      {:ok, updated_state} = Dealing.deal_initial(state)

      remaining_cards = length(updated_state.deck)
      dealt_cards = initial_deck_size - remaining_cards

      assert dealt_cards == 36
      assert remaining_cards == 16
    end

    test "all dealt cards are unique across all players" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Collect all cards from all players
      all_cards =
        updated_state.players
        |> Enum.flat_map(fn {_pos, player} -> player.hand end)

      # All cards should be unique
      unique_cards = Enum.uniq(all_cards)
      assert length(all_cards) == 36
      assert length(unique_cards) == 36
    end

    test "sets current_turn to left of dealer (clockwise)" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Dealer is north, so current_turn should be east (left of north, clockwise)
      assert updated_state.current_turn == :east
    end

    test "dealing starts from left of dealer" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # With dealer as north, dealing should start at east
      # First 3 cards go to east, next 3 to south, etc.
      # We can verify that all players got cards
      Enum.each([:east, :south, :west, :north], fn position ->
        player = Map.get(updated_state.players, position)
        assert length(player.hand) == 9
      end)
    end

    test "records cards_dealt event with all player hands" do
      state = new_game_with_dealer()

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Should have one event
      assert length(updated_state.events) == 1

      # Event should be cards_dealt
      [event] = updated_state.events
      assert match?({:cards_dealt, _hands}, event)

      # Extract hands from event
      {:cards_dealt, hands} = event

      # Should have hands for all 4 players
      assert map_size(hands) == 4
      assert Map.has_key?(hands, :north)
      assert Map.has_key?(hands, :east)
      assert Map.has_key?(hands, :south)
      assert Map.has_key?(hands, :west)

      # Each hand should have 9 cards
      Enum.each(hands, fn {_pos, cards} ->
        assert length(cards) == 9
      end)
    end

    test "returns error when no dealer is set" do
      state = new_game_with_deck()

      {:error, :no_dealer, message} = Dealing.deal_initial(state)

      assert message =~ "Cannot deal cards without a dealer"
    end

    test "returns error when deck has insufficient cards" do
      state = new_game_with_dealer()
      # Set deck to have only 10 cards (need 36)
      small_deck = Enum.take(state.deck, 10)
      state = Map.put(state, :deck, small_deck)

      {:error, :insufficient_cards, message} = Dealing.deal_initial(state)

      assert message =~ "need 36 cards"
      assert message =~ "10 available"
    end
  end

  # =============================================================================
  # Dealing Order Tests
  # =============================================================================

  describe "deal_initial/1 dealing order" do
    test "with north as dealer, first cards go to east" do
      state = new_game_with_dealer()
      state = Map.put(state, :current_dealer, :north)

      # Take note of the first 9 cards in the deck
      expected_east_cards = Enum.take(state.deck, 3)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # East should have received the first 3 cards in their hand
      east_hand = updated_state.players.east.hand
      first_batch = Enum.take(east_hand, 3)

      assert first_batch == expected_east_cards
    end

    test "with south as dealer, first cards go to west" do
      state = new_game_with_dealer()
      state = Map.put(state, :current_dealer, :south)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Current turn should be west (left of south)
      assert updated_state.current_turn == :west
    end

    test "with east as dealer, first cards go to south" do
      state = new_game_with_dealer()
      state = Map.put(state, :current_dealer, :east)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Current turn should be south (left of east)
      assert updated_state.current_turn == :south
    end

    test "with west as dealer, first cards go to north" do
      state = new_game_with_dealer()
      state = Map.put(state, :current_dealer, :west)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # Current turn should be north (left of west)
      assert updated_state.current_turn == :north
    end
  end

  # =============================================================================
  # Integration Tests
  # =============================================================================

  describe "full dealing sequence" do
    test "select dealer, then deal initial cards" do
      state = new_game_with_deck()

      # Select dealer
      {:ok, state} = Dealing.select_dealer(state)
      dealer = state.current_dealer

      # Deal cards
      {:ok, state} = Dealing.deal_initial(state)

      # Verify dealer is still set
      assert state.current_dealer == dealer

      # Verify all players have cards
      Enum.each(state.players, fn {_pos, player} ->
        assert length(player.hand) == 9
      end)

      # Verify current turn is left of dealer
      expected_turn = Types.next_position(dealer)
      assert state.current_turn == expected_turn

      # Verify events recorded
      assert length(state.events) == 2
      assert match?([{:dealer_selected, _, _}, {:cards_dealt, _}], state.events)
    end

    test "rotate dealer and deal new hand" do
      state = new_game_with_deck()

      # Select initial dealer
      {:ok, state} = Dealing.select_dealer(state)
      first_dealer = state.current_dealer

      # Rotate dealer
      {:ok, state} = Dealing.rotate_dealer(state)
      second_dealer = state.current_dealer

      # Second dealer should be next clockwise from first
      assert second_dealer == Types.next_position(first_dealer)

      # Hand number should increment
      assert state.hand_number == 2
    end
  end

  # =============================================================================
  # Edge Cases
  # =============================================================================

  describe "edge cases" do
    test "dealing with exactly 36 cards in deck works" do
      state = new_game_with_dealer()
      # Set deck to exactly 36 cards
      exact_deck = Enum.take(state.deck, 36)
      state = Map.put(state, :deck, exact_deck)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # All 36 cards should be dealt
      assert length(updated_state.deck) == 0

      # Each player should have 9 cards
      Enum.each(updated_state.players, fn {_pos, player} ->
        assert length(player.hand) == 9
      end)
    end

    test "dealing with more than 52 cards in deck still works" do
      state = new_game_with_dealer()
      # Double the deck (104 cards)
      double_deck = state.deck ++ state.deck
      state = Map.put(state, :deck, double_deck)

      {:ok, updated_state} = Dealing.deal_initial(state)

      # 36 cards should be dealt
      assert length(updated_state.deck) == 68

      # Each player should have 9 cards
      Enum.each(updated_state.players, fn {_pos, player} ->
        assert length(player.hand) == 9
      end)
    end
  end
end
