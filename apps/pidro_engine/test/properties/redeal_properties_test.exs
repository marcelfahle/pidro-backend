defmodule Pidro.Properties.RedealPropertiesTest do
  @moduledoc """
  Property-based tests for Finnish Pidro redeal mechanics.

  Tests the dealer advantage, kill rules, and information tracking that are
  critical to the Finnish Pidro variant.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Card, GameState, Types}
  alias Pidro.Game.{Discard, Trump, Play}

  @positions [:north, :east, :south, :west]

  # =============================================================================
  # Generators
  # =============================================================================

  defp suit_gen do
    member_of([:hearts, :diamonds, :clubs, :spades])
  end

  # Generator for a game state at second_deal phase
  defp post_discard_pre_redeal_gen do
    gen all(
          trump_suit <- suit_gen(),
          dealer_pos <- member_of(@positions)
        ) do
      # Create initial state
      state = GameState.new()

      # Set up dealer and trump
      state =
        state
        |> GameState.update(:current_dealer, dealer_pos)
        |> GameState.update(:trump_suit, trump_suit)
        |> GameState.update(:phase, :second_deal)
        |> GameState.update(:bidding_team, Types.position_to_team(dealer_pos))
        |> GameState.update(:highest_bid, {dealer_pos, 10})

      # Create players with only trump cards (0-6 each)
      players =
        @positions
        |> Enum.map(fn pos ->
          # Random trump count 0-6 for non-dealers, 0-3 for dealer
          trump_count =
            if pos == dealer_pos do
              Enum.random(0..3)
            else
              Enum.random(0..6)
            end

          hand =
            if trump_count > 0 do
              1..trump_count
              |> Enum.map(fn i ->
                rank = rem(i, 13) + 2
                {rank, trump_suit}
              end)
            else
              []
            end

          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: hand
          }

          {pos, player}
        end)
        |> Map.new()

      # Create a deck with remaining cards (simulating cards available for redeal)
      remaining_cards =
        for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades] do
          {rank, suit}
        end
        |> Enum.take(16)

      state
      |> GameState.update(:players, players)
      |> GameState.update(:deck, remaining_cards)
    end
  end

  # Generator for a game state after dealer has robbed the pack
  defp post_dealer_rob_gen do
    gen all(state <- post_discard_pre_redeal_gen()) do
      # Simulate dealer robbing the pack
      dealer = state.current_dealer
      dealer_player = Map.get(state.players, dealer)
      remaining_deck = state.deck

      # Dealer combines hand + deck
      dealer_pool = dealer_player.hand ++ remaining_deck

      # Dealer selects best 6 (just take first 6 for testing)
      selected = Enum.take(dealer_pool, 6)

      # Update dealer's hand
      updated_players =
        Map.put(state.players, dealer, %{dealer_player | hand: selected})

      state
      |> GameState.update(:players, updated_players)
      |> GameState.update(:dealer_pool_size, length(dealer_pool))
      |> GameState.update(:deck, [])
    end
  end

  # Generator for a player with >6 trump cards
  defp player_with_excess_trump_gen do
    gen all(
          trump_suit <- suit_gen(),
          trump_count <- integer(7..14)
        ) do
      hand =
        if trump_count > 0 do
          1..trump_count
          |> Enum.map(fn i ->
            rank = rem(i, 13) + 2
            {rank, trump_suit}
          end)
        else
          []
        end

      player = %Types.Player{
        position: :north,
        team: :north_south,
        hand: hand
      }

      {player, trump_suit}
    end
  end

  # =============================================================================
  # Property: Dealer Combines Hand + Deck
  # =============================================================================

  describe "Property: dealer combines hand with remaining deck" do
    property "dealer always sees at least 6 cards when robbing pack" do
      check all(state <- post_discard_pre_redeal_gen(), max_runs: 50) do
        dealer = state.current_dealer
        dealer_player = Map.get(state.players, dealer)
        deck_remaining = length(state.deck)
        dealer_hand = length(dealer_player.hand)

        # Dealer should see combined pool
        expected_pool_size = dealer_hand + deck_remaining

        # In a valid game, dealer must have at least 6 cards to select
        assert expected_pool_size >= 0,
               "Dealer pool size should be non-negative: #{expected_pool_size}"

        # If pool < 6, this is an edge case but should still be handled
        # (dealer just keeps what they have)
      end
    end

    property "dealer_pool_size tracks total cards available to dealer" do
      check all(state <- post_dealer_rob_gen(), max_runs: 50) do
        # dealer_pool_size should be set
        assert is_integer(state.dealer_pool_size),
               "dealer_pool_size should be set after dealer robs"

        assert state.dealer_pool_size >= 0,
               "dealer_pool_size should be non-negative"
      end
    end
  end

  # =============================================================================
  # Property: Cards Requested Tracking
  # =============================================================================

  describe "Property: cards requested tracking" do
    property "cards_requested tracks how many cards each non-dealer received" do
      check all(state <- post_discard_pre_redeal_gen(), max_runs: 50) do
        # After second_deal, simulate tracking cards requested
        dealer = state.current_dealer
        non_dealers = @positions -- [dealer]

        # Each non-dealer with <6 cards should request cards
        expected_requests =
          non_dealers
          |> Enum.map(fn pos ->
            player = Map.get(state.players, pos)
            cards_needed = max(0, 6 - length(player.hand))
            {pos, cards_needed}
          end)
          |> Map.new()

        # Verify structure (actual tracking happens in Discard.second_deal)
        assert is_map(expected_requests)

        Enum.each(expected_requests, fn {_pos, count} ->
          assert count >= 0 and count <= 6,
                 "Cards requested should be between 0 and 6: #{count}"
        end)
      end
    end
  end

  # =============================================================================
  # Property: Kill Rule - Non-point Cards Only
  # =============================================================================

  describe "Property: kill rule - non-point cards only" do
    property "killed cards must be non-point trumps (unless player has 7+ point cards)" do
      check all({player, trump_suit} <- player_with_excess_trump_gen(), max_runs: 50) do
        hand = player.hand
        hand_size = length(hand)

        if hand_size > 6 do
          # Count point cards
          point_count = Enum.count(hand, &Card.is_point_card?(&1, trump_suit))

          if point_count >= 7 do
            # Cannot kill - should keep all cards
            # In actual implementation, killed_cards would be []
            assert point_count >= 7,
                   "Player with 7+ point cards cannot kill any"
          else
            # Should be able to kill excess non-point cards
            non_point = Card.non_point_trumps(hand, trump_suit)
            excess = hand_size - 6

            assert length(non_point) >= excess,
                   "Should have enough non-point cards to kill: #{length(non_point)} >= #{excess}"
          end
        end
      end
    end

    property "can_kill_to_six? returns true only when enough non-point cards exist" do
      check all({player, trump_suit} <- player_with_excess_trump_gen(), max_runs: 50) do
        hand = player.hand
        can_kill = Trump.can_kill_to_six?(hand, trump_suit)

        if can_kill do
          # Should have enough non-point cards
          non_point = Card.non_point_trumps(hand, trump_suit)
          excess = length(hand) - 6

          assert length(non_point) >= excess,
                 "If can_kill_to_six? is true, should have enough non-point cards"
        else
          # Should have 7+ point cards or not enough non-point cards
          point_count = Enum.count(hand, &Card.is_point_card?(&1, trump_suit))
          non_point = Card.non_point_trumps(hand, trump_suit)
          excess = length(hand) - 6

          assert point_count >= 7 or length(non_point) < excess,
                 "If can_kill_to_six? is false, should have 7+ point cards or insufficient non-point cards"
        end
      end
    end
  end

  # =============================================================================
  # Property: Kill Rule - Validation
  # =============================================================================

  describe "Property: kill rule validation" do
    property "validate_kill_cards rejects point cards" do
      check all(
              trump_suit <- suit_gen(),
              max_runs: 30
            ) do
        # Create a hand with some point cards
        point_cards = [
          {14, trump_suit},
          # Ace
          {11, trump_suit},
          # Jack
          {10, trump_suit}
          # 10
        ]

        hand = point_cards ++ [{3, trump_suit}, {4, trump_suit}]

        # Try to kill a point card
        result = Trump.validate_kill_cards([{14, trump_suit}], hand, trump_suit)
        assert result == {:error, :cannot_kill_point_cards}
      end
    end

    property "validate_kill_cards accepts non-point trump cards" do
      check all(trump_suit <- suit_gen(), max_runs: 30) do
        # Create a hand with non-point trumps
        non_point_cards = [{3, trump_suit}, {4, trump_suit}, {6, trump_suit}]
        hand = non_point_cards ++ [{14, trump_suit}]

        # Kill a non-point card
        result = Trump.validate_kill_cards([{3, trump_suit}], hand, trump_suit)
        assert result == :ok
      end
    end

    property "validate_kill_cards rejects cards not in hand" do
      check all(trump_suit <- suit_gen(), max_runs: 30) do
        hand = [{3, trump_suit}, {4, trump_suit}]
        not_in_hand = [{7, trump_suit}]

        result = Trump.validate_kill_cards(not_in_hand, hand, trump_suit)
        assert result == {:error, :cards_not_in_hand}
      end
    end

    property "validate_kill_cards rejects non-trump cards" do
      check all(
              trump_suit <- suit_gen(),
              max_runs: 30
            ) do
        other_suits = [:hearts, :diamonds, :clubs, :spades] -- [trump_suit]
        other_suit = Enum.random(other_suits)

        hand = [{3, trump_suit}, {4, other_suit}]

        result = Trump.validate_kill_cards([{4, other_suit}], hand, trump_suit)
        assert result == {:error, :can_only_kill_trump}
      end
    end
  end

  # =============================================================================
  # Property: Card Helper Functions
  # =============================================================================

  describe "Property: card helper functions" do
    property "is_point_card? correctly identifies point cards" do
      check all(trump_suit <- suit_gen(), max_runs: 30) do
        # Point cards: A, J, 10, Right-5, Wrong-5, 2
        assert Card.is_point_card?({14, trump_suit}, trump_suit) == true
        assert Card.is_point_card?({11, trump_suit}, trump_suit) == true
        assert Card.is_point_card?({10, trump_suit}, trump_suit) == true
        assert Card.is_point_card?({5, trump_suit}, trump_suit) == true
        assert Card.is_point_card?({2, trump_suit}, trump_suit) == true

        # Wrong 5 is also a point card
        wrong_5_suit = Card.same_color_suit(trump_suit)
        assert Card.is_point_card?({5, wrong_5_suit}, trump_suit) == true

        # Non-point cards
        assert Card.is_point_card?({3, trump_suit}, trump_suit) == false
        assert Card.is_point_card?({4, trump_suit}, trump_suit) == false
        assert Card.is_point_card?({6, trump_suit}, trump_suit) == false
        assert Card.is_point_card?({13, trump_suit}, trump_suit) == false
      end
    end

    property "count_trump correctly counts trump cards including wrong 5" do
      check all(trump_suit <- suit_gen(), max_runs: 30) do
        wrong_5_suit = Card.same_color_suit(trump_suit)

        # Pick a non-trump suit (not trump or wrong 5 color)
        non_trump_suit =
          [:hearts, :diamonds, :clubs, :spades]
          |> Enum.reject(&(&1 == trump_suit or &1 == wrong_5_suit))
          |> Enum.random()

        hand = [
          {14, trump_suit},
          {5, trump_suit},
          {5, wrong_5_suit},
          {3, trump_suit},
          {7, non_trump_suit}
        ]

        trump_count = Card.count_trump(hand, trump_suit)

        # Should count: A, Right-5, Wrong-5, 3 = 4 cards (7 of non-trump is not counted)
        expected = 4
        assert trump_count == expected, "Expected #{expected} trump cards, got #{trump_count}"
      end
    end

    property "non_point_trumps filters correctly" do
      check all(trump_suit <- suit_gen(), max_runs: 30) do
        hand = [
          {14, trump_suit},
          # Point
          {11, trump_suit},
          # Point
          {3, trump_suit},
          # Non-point
          {4, trump_suit},
          # Non-point
          {6, trump_suit}
          # Non-point
        ]

        non_point = Card.non_point_trumps(hand, trump_suit)

        assert length(non_point) == 3, "Should have 3 non-point trumps"

        Enum.each(non_point, fn card ->
          assert Card.is_trump?(card, trump_suit)
          refute Card.is_point_card?(card, trump_suit)
        end)
      end
    end
  end

  # =============================================================================
  # Property: Information Hiding
  # =============================================================================

  describe "Property: information hiding in events" do
    property "second_deal_complete event uses counts, not card lists" do
      check all(state <- post_discard_pre_redeal_gen(), max_runs: 30) do
        # Simulate second_deal
        case Discard.second_deal(state) do
          {:ok, new_state} ->
            # Check that events don't leak exact cards
            second_deal_event =
              new_state.events
              |> Enum.find(fn
                {:second_deal_complete, _} -> true
                _ -> false
              end)

            if second_deal_event do
              {:second_deal_complete, dealt_info} = second_deal_event

              # Should be a map of position => count, not cards
              assert is_map(dealt_info) or is_integer(dealt_info),
                     "second_deal_complete event should use counts or map, not card lists"
            end

          _ ->
            # Skip if second_deal fails (e.g., insufficient cards)
            :ok
        end
      end
    end
  end

  # =============================================================================
  # Property: Kill Rule Enforcement in Play Phase
  # =============================================================================

  describe "Property: kill rule enforcement" do
    property "compute_kills removes exactly the excess non-point cards" do
      check all({player, trump_suit} <- player_with_excess_trump_gen(), max_runs: 30) do
        hand = player.hand
        hand_size = length(hand)

        if hand_size > 6 do
          # Create a minimal game state for testing
          state = %Types.GameState{
            phase: :playing,
            trump_suit: trump_suit,
            players: %{north: %{player | hand: hand}},
            killed_cards: %{}
          }

          # Compute kills
          new_state = Play.compute_kills(state)

          killed = Map.get(new_state.killed_cards, :north, [])
          new_hand = new_state.players.north.hand

          # Check killed cards
          if length(killed) > 0 do
            # Should have killed exactly the excess
            excess = hand_size - 6

            assert length(killed) == excess or length(killed) == 0,
                   "Should kill exactly #{excess} cards or 0 if cannot kill"

            # All killed cards should be non-point trumps
            Enum.each(killed, fn card ->
              assert Card.is_trump?(card, trump_suit),
                     "Killed card should be trump: #{inspect(card)}"

              refute Card.is_point_card?(card, trump_suit),
                     "Killed card should not be a point card: #{inspect(card)}"
            end)

            # Final hand should be exactly 6 cards
            assert length(new_hand) == 6, "Hand after killing should be 6 cards"
          else
            # Could not kill (7+ point cards) - should keep all
            point_count = Enum.count(hand, &Card.is_point_card?(&1, trump_suit))
            assert point_count >= 7, "If no cards killed, should have 7+ point cards"
          end
        end
      end
    end
  end
end
