defmodule Pidro.Game.DiscardLeaderTest do
  use ExUnit.Case, async: true
  alias Pidro.Core.Types
  alias Pidro.Core.Types.GameState
  alias Pidro.Game.Discard

  describe "leader selection for first trick" do
    test "after dealer robs pack, the highest bidder (not left of dealer) leads the first trick" do
      # Setup:
      # Dealer: South
      # Highest Bidder: South (Dealer)
      #
      # Expected: South leads (since they won the bid)
      # Bug behavior: West leads (left of dealer)

      trump = :hearts
      
      # South needs < 6 cards to trigger rob logic
      south_hand = [{14, :hearts}, {13, :hearts}, {12, :hearts}] 
      
      # Other players (hands irrelevant, just placeholders)
      players = %{
        south: %Types.Player{position: :south, team: :north_south, hand: south_hand},
        west: %Types.Player{position: :west, team: :east_west, hand: []},
        north: %Types.Player{position: :north, team: :north_south, hand: []},
        east: %Types.Player{position: :east, team: :east_west, hand: []}
      }

      deck = [{10, :hearts}, {9, :hearts}, {8, :hearts}] # Cards for dealer to rob

      state = %GameState{
        phase: :second_deal,
        trump_suit: trump,
        current_dealer: :south,
        current_turn: :south, # Dealer's turn to rob
        players: players,
        deck: deck,
        highest_bid: {:south, 14}, # South is highest bidder
        discarded_cards: [],
        events: []
      }

      # Dealer selects 6 cards to keep
      selected_cards = south_hand ++ deck 
      
      {:ok, new_state} = Discard.dealer_rob_pack(state, selected_cards)

      assert new_state.phase == :playing
      
      # The CRITICAL assertion:
      # Leader should be South (highest bidder), NOT West (left of dealer)
      assert new_state.current_turn == :south
    end

    test "after second deal (no rob), the highest bidder leads the first trick" do
      # Setup:
      # Dealer: South
      # Highest Bidder: North (Partner of dealer)
      # No cards in deck -> no rob -> direct transition to playing
      #
      # Expected: North leads
      # Bug behavior: West leads

      trump = :hearts
      
      # South has 6 cards -> no rob needed
      south_hand = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
      
      players = %{
        south: %Types.Player{position: :south, team: :north_south, hand: south_hand},
        west: %Types.Player{position: :west, team: :east_west, hand: []},
        north: %Types.Player{position: :north, team: :north_south, hand: []},
        east: %Types.Player{position: :east, team: :east_west, hand: []}
      }

      state = %GameState{
        phase: :second_deal,
        trump_suit: trump,
        current_dealer: :south,
        players: players,
        deck: [], # Empty deck, no rob possible
        highest_bid: {:north, 10}, # North is highest bidder
        discarded_cards: [],
        events: []
      }

      {:ok, new_state} = Discard.second_deal(state)

      assert new_state.phase == :playing
      assert new_state.current_turn == :north
    end
  end
end
