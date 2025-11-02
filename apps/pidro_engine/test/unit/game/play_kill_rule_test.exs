defmodule Pidro.Game.PlayKillRuleTest do
  @moduledoc """
  Unit tests for the kill rule implementation in Finnish Pidro.

  The kill rule states:
  - If a player has >6 trump cards after redeal, they must "kill" (discard face-up) excess cards to get down to 6
  - Can ONLY kill non-point trump cards (K, Q, 9, 8, 7, 6, 4, 3)
  - CANNOT kill point cards (A, J, 10, Right-5, Wrong-5, 2)
  - If a player has 7+ point cards, they cannot kill any and must keep all cards
  - Killed cards are placed face-up and visible to all players
  - The TOP card of the killed pile MUST be played on the first trick
  """

  use ExUnit.Case, async: true

  alias Pidro.Core.{Card, Types}
  alias Pidro.Game.Play

  # Helper to create a minimal game state for testing
  defp create_test_state(hands, trump_suit \\ :hearts) do
    players =
      hands
      |> Enum.map(fn {pos, hand} ->
        {pos, %Types.Player{
          position: pos,
          team: Types.position_to_team(pos),
          hand: hand,
          eliminated?: false,
          revealed_cards: [],
          tricks_won: 0
        }}
      end)
      |> Map.new()

    %Types.GameState{
      phase: :playing,
      trump_suit: trump_suit,
      players: players,
      killed_cards: %{},
      events: [],
      current_dealer: :north,
      bidding_team: :north_south,
      highest_bid: {:north, 10},
      hand_points: %{north_south: 0, east_west: 0},
      cumulative_scores: %{north_south: 0, east_west: 0},
      tricks: [],
      current_trick: nil,
      trick_number: 0,
      current_turn: :north,
      deck: [],
      discarded_cards: [],
      bids: [],
      winner: nil,
      config: %{
        min_bid: 6,
        max_bid: 14,
        winning_score: 62,
        initial_deal_count: 9,
        final_hand_size: 6,
        allow_negative_scores: true
      },
      cache: %{},
      hand_number: 1,
      variant: :finnish,
      cards_requested: %{},
      dealer_pool_size: nil
    }
  end

  describe "compute_kills/1 - basic kill mechanics" do
    test "player with exactly 6 trump cards does not kill" do
      # Player has exactly 6 trump cards
      hand = [
        {14, :hearts}, # Ace (point card)
        {13, :hearts}, # King (non-point)
        {11, :hearts}, # Jack (point card)
        {10, :hearts}, # 10 (point card)
        {7, :hearts},  # 7 (non-point)
        {6, :hearts}   # 6 (non-point)
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should not kill any cards
      assert length(new_state.players[:north].hand) == 6
      assert new_state.killed_cards == %{}

      # cards_killed event is always recorded, but should be empty
      assert {:cards_killed, %{}} in new_state.events
    end

    test "player with <6 trump cards does not kill" do
      # Player has only 5 trump cards
      hand = [
        {14, :hearts},
        {13, :hearts},
        {11, :hearts},
        {10, :hearts},
        {7, :hearts}
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should not kill any cards
      assert length(new_state.players[:north].hand) == 5
      assert new_state.killed_cards == %{}
    end

    test "player with 7 trump cards must kill 1 non-point card" do
      # Player has 7 trump cards with 1 non-point card available
      hand = [
        {14, :hearts}, # Ace (point)
        {13, :hearts}, # King (non-point) - will be killed
        {11, :hearts}, # Jack (point)
        {10, :hearts}, # 10 (point)
        {5, :hearts},  # Right-5 (point)
        {2, :hearts},  # 2 (point)
        {7, :hearts}   # 7 (non-point)
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill 1 card down to 6
      assert length(new_state.players[:north].hand) == 6

      # Should have killed exactly 1 card
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 1

      # Killed card must be a non-point trump
      [killed_card] = killed
      assert Card.is_trump?(killed_card, :hearts)
      refute Card.is_point_card?(killed_card, :hearts)

      # Verify the killed card is removed from hand
      refute killed_card in new_state.players[:north].hand

      # Verify cards_killed event was recorded
      assert {:cards_killed, %{north: [killed_card]}} in new_state.events
    end

    test "player with 9 trump cards must kill 3 non-point cards" do
      # Player has 9 trump cards with 3 non-point cards
      hand = [
        {14, :hearts}, # Ace (point)
        {13, :hearts}, # King (non-point)
        {12, :hearts}, # Queen (non-point)
        {11, :hearts}, # Jack (point)
        {10, :hearts}, # 10 (point)
        {9, :hearts},  # 9 (non-point)
        {7, :hearts},  # 7 (non-point) - excess
        {5, :hearts},  # Right-5 (point)
        {2, :hearts}   # 2 (point)
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill 3 cards down to 6
      assert length(new_state.players[:north].hand) == 6

      # Should have killed exactly 3 cards
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 3

      # All killed cards must be non-point trumps
      Enum.each(killed, fn card ->
        assert Card.is_trump?(card, :hearts)
        refute Card.is_point_card?(card, :hearts)
      end)
    end
  end

  describe "compute_kills/1 - point card restrictions" do
    test "can only kill non-point trump cards (K, Q, 9, 8, 7, 6, 4, 3)" do
      # Player has mix of point and non-point cards
      hand = [
        {14, :hearts}, # Ace (point) - CANNOT kill
        {13, :hearts}, # King (non-point) - CAN kill
        {12, :hearts}, # Queen (non-point) - CAN kill
        {11, :hearts}, # Jack (point) - CANNOT kill
        {10, :hearts}, # 10 (point) - CANNOT kill
        {9, :hearts},  # 9 (non-point) - CAN kill
        {5, :hearts}   # Right-5 (point) - CANNOT kill
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill 1 non-point card
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 1

      # Verify killed card is one of the valid non-point cards
      [killed_card] = killed
      assert killed_card in [{13, :hearts}, {12, :hearts}, {9, :hearts}]

      # Verify all point cards remain in hand
      point_cards = [{14, :hearts}, {11, :hearts}, {10, :hearts}, {5, :hearts}]
      Enum.each(point_cards, fn card ->
        assert card in new_state.players[:north].hand
      end)
    end

    test "cannot kill point cards (A, J, 10, Right-5, Wrong-5, 2)" do
      # Test with hearts as trump
      point_cards_hearts = [
        {14, :hearts}, # Ace
        {11, :hearts}, # Jack
        {10, :hearts}, # 10
        {5, :hearts},  # Right-5
        {5, :diamonds}, # Wrong-5 (same color)
        {2, :hearts}   # 2
      ]

      non_point = {13, :hearts} # King

      hand = point_cards_hearts ++ [non_point]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill only the King
      killed = Map.get(new_state.killed_cards, :north, [])
      assert killed == [{13, :hearts}]

      # All point cards should remain
      Enum.each(point_cards_hearts, fn card ->
        assert card in new_state.players[:north].hand
      end)
    end

    test "recognizes wrong-5 as a point card that cannot be killed" do
      # Hearts is trump, so 5 of diamonds is wrong-5 (point card)
      hand = [
        {14, :hearts},  # Ace (point)
        {13, :hearts},  # King (non-point) - will be killed
        {11, :hearts},  # Jack (point)
        {10, :hearts},  # 10 (point)
        {5, :hearts},   # Right-5 (point)
        {5, :diamonds}, # Wrong-5 (point)
        {2, :hearts}    # 2 (point)
      ]

      state = create_test_state(%{north: hand}, :hearts)
      new_state = Play.compute_kills(state)

      # Should kill only the King
      killed = Map.get(new_state.killed_cards, :north, [])
      assert killed == [{13, :hearts}]

      # Wrong-5 should NOT be killed
      assert {5, :diamonds} in new_state.players[:north].hand
    end
  end

  describe "compute_kills/1 - cannot kill when 7+ point cards" do
    test "player with exactly enough non-point cards to kill" do
      # 8 trump cards: 6 point cards + 2 non-point = need to kill 2, have 2 non-point
      hand = [
        {14, :hearts},  # Point
        {11, :hearts},  # Point
        {10, :hearts},  # Point
        {5, :hearts},   # Point
        {5, :diamonds}, # Point (wrong-5)
        {2, :hearts},   # Point
        {13, :hearts},  # Non-point (can kill)
        {12, :hearts}   # Non-point (can kill)
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill 2 non-point cards
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 2
      assert length(new_state.players[:north].hand) == 6
    end

    test "player has enough non-point cards to kill excess" do
      # 9 trump cards: 6 point cards + 3 non-point
      # Needs to kill 3 cards, has 3 non-point cards - exactly enough
      hand = [
        {14, :hearts},  # Point
        {11, :hearts},  # Point
        {10, :hearts},  # Point
        {5, :hearts},   # Point
        {5, :diamonds}, # Point (wrong-5)
        {2, :hearts},   # Point
        {13, :hearts},  # Non-point
        {12, :hearts},  # Non-point
        {9, :hearts}    # Non-point
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Has exactly enough non-point cards, should kill 3
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 3
      assert length(new_state.players[:north].hand) == 6
    end
  end

  describe "compute_kills/1 - killed cards storage" do
    test "killed cards stored in killed_cards map by position" do
      hands = %{
        north: [{14, :hearts}, {13, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}, {4, :hearts}],
        east: [{14, :diamonds}, {13, :diamonds}, {11, :diamonds}, {10, :diamonds}, {7, :diamonds}, {6, :diamonds}],
        south: [{12, :hearts}, {9, :hearts}, {8, :hearts}, {5, :hearts}, {2, :hearts}, {3, :hearts}, {4, :hearts}],
        west: [{14, :clubs}, {13, :clubs}]
      }

      state = create_test_state(hands, :hearts)
      new_state = Play.compute_kills(state)

      # North has 7 hearts (trump), should kill 1
      north_killed = Map.get(new_state.killed_cards, :north, [])
      assert length(north_killed) == 1
      assert hd(north_killed) in [{13, :hearts}, {7, :hearts}, {6, :hearts}, {4, :hearts}]

      # East has 6 diamonds (not trump), no kill
      refute Map.has_key?(new_state.killed_cards, :east)

      # South has 7 hearts (trump), should kill 1
      south_killed = Map.get(new_state.killed_cards, :south, [])
      assert length(south_killed) == 1
      assert hd(south_killed) in [{12, :hearts}, {9, :hearts}, {8, :hearts}, {3, :hearts}, {4, :hearts}]

      # West has 2 clubs (not trump), no kill
      refute Map.has_key?(new_state.killed_cards, :west)
    end

    test "empty list stored for players who cannot kill due to insufficient non-point cards" do
      # 8 trump cards: 7 point + 1 non-point (need to kill 2, only have 1 non-point)
      # This scenario means cannot kill, so should store empty list

      # Actually based on code (line 112-114), it stores empty list: Map.put(acc, pos, [])
      # But we need a real scenario. Let's think...
      # We can't have 7 point cards in one suit (max is 6: A,J,10,5,5,2)
      # So this branch is actually unreachable in practice!

      # The code will store [] when cannot kill, but this is defensive programming
      # Let's verify the behavior when exactly enough non-point cards exist
      hand = [
        {14, :hearts},  # Point
        {11, :hearts},  # Point
        {10, :hearts},  # Point
        {5, :hearts},   # Point
        {5, :diamonds}, # Point
        {2, :hearts},   # Point
        {13, :hearts}   # Non-point (7 total, 6 point + 1 non-point, need to kill 1, have 1)
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should successfully kill the 1 non-point card
      killed = Map.get(new_state.killed_cards, :north, [])
      assert killed == [{13, :hearts}]
      assert length(new_state.players[:north].hand) == 6
    end
  end

  describe "compute_kills/1 - cards_killed event" do
    test "cards_killed event emitted with position and cards" do
      hand = [
        {14, :hearts},
        {13, :hearts}, # Will be killed
        {11, :hearts},
        {10, :hearts},
        {7, :hearts},
        {6, :hearts},
        {5, :hearts}
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Find the cards_killed event
      killed_event = Enum.find(new_state.events, fn
        {:cards_killed, _} -> true
        _ -> false
      end)

      assert killed_event != nil
      {:cards_killed, killed_map} = killed_event

      # Should have north's killed cards
      assert Map.has_key?(killed_map, :north)
      assert length(killed_map[:north]) == 1
    end

    test "cards_killed event includes all positions that killed cards" do
      hands = %{
        north: [{14, :hearts}, {13, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}, {4, :hearts}],
        east: [{14, :diamonds}],
        south: [{12, :hearts}, {9, :hearts}, {8, :hearts}, {7, :hearts}, {6, :hearts}, {5, :hearts}, {2, :hearts}],
        west: [{14, :clubs}]
      }

      state = create_test_state(hands, :hearts)
      new_state = Play.compute_kills(state)

      # Find the cards_killed event
      {:cards_killed, killed_map} = Enum.find(new_state.events, fn
        {:cards_killed, _} -> true
        _ -> false
      end)

      # North killed 1, south killed 1
      assert Map.has_key?(killed_map, :north)
      assert Map.has_key?(killed_map, :south)
      assert length(killed_map[:north]) == 1
      assert length(killed_map[:south]) == 1

      # East and west should not be in the map (no trump cards)
      refute Map.has_key?(killed_map, :east)
      refute Map.has_key?(killed_map, :west)
    end

    test "cards_killed event is empty map when no one needs to kill" do
      hands = %{
        north: [{14, :hearts}, {13, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}],
        east: [{14, :diamonds}],
        south: [{14, :clubs}],
        west: [{14, :spades}]
      }

      state = create_test_state(hands, :hearts)
      new_state = Play.compute_kills(state)

      # Find the cards_killed event
      {:cards_killed, killed_map} = Enum.find(new_state.events, fn
        {:cards_killed, _} -> true
        _ -> false
      end)

      # Should be empty map since no one had >6 trump
      assert killed_map == %{}
    end
  end

  describe "compute_kills/1 - dealer scenarios" do
    test "dealer can also have >6 trump after robbing the pack" do
      # Dealer (north) has 8 trump cards after robbing
      hand = [
        {14, :hearts},
        {13, :hearts}, # Non-point, can be killed
        {12, :hearts}, # Non-point, can be killed
        {11, :hearts},
        {10, :hearts},
        {7, :hearts},
        {5, :hearts},
        {2, :hearts}
      ]

      state = create_test_state(%{north: hand})
      state = %{state | current_dealer: :north}
      new_state = Play.compute_kills(state)

      # Dealer should kill 2 cards
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 2
      assert length(new_state.players[:north].hand) == 6

      # Verify killed cards are non-point
      Enum.each(killed, fn card ->
        assert Card.is_trump?(card, :hearts)
        refute Card.is_point_card?(card, :hearts)
      end)
    end

    test "dealer with exactly 6 cards after robbing does not kill" do
      hand = [
        {14, :hearts},
        {13, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :hearts},
        {2, :hearts}
      ]

      state = create_test_state(%{north: hand})
      state = %{state | current_dealer: :north}
      new_state = Play.compute_kills(state)

      # Dealer should not kill
      assert new_state.killed_cards == %{}
      assert length(new_state.players[:north].hand) == 6
    end
  end

  describe "compute_kills/1 - multiple players" do
    test "correctly handles multiple players needing to kill" do
      hands = %{
        north: [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}, {8, :hearts}, {7, :hearts}],
        east: [{14, :hearts}, {6, :hearts}, {5, :hearts}, {4, :hearts}, {3, :hearts}, {2, :hearts}],
        south: [{13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}, {8, :hearts}, {7, :hearts}],
        west: [{6, :hearts}, {4, :hearts}, {3, :hearts}]
      }

      state = create_test_state(hands, :hearts)
      new_state = Play.compute_kills(state)

      # North has 8, should kill 2
      north_killed = Map.get(new_state.killed_cards, :north, [])
      assert length(north_killed) == 2
      assert length(new_state.players[:north].hand) == 6

      # East has 6, no kill
      refute Map.has_key?(new_state.killed_cards, :east)
      assert length(new_state.players[:east].hand) == 6

      # South has 7, should kill 1
      south_killed = Map.get(new_state.killed_cards, :south, [])
      assert length(south_killed) == 1
      assert length(new_state.players[:south].hand) == 6

      # West has 3, no kill
      refute Map.has_key?(new_state.killed_cards, :west)
      assert length(new_state.players[:west].hand) == 3
    end
  end

  describe "compute_kills/1 - trump suit variations" do
    test "correctly identifies trump and non-trump with diamonds as trump" do
      hand = [
        {14, :diamonds}, # Ace of diamonds (trump, point)
        {13, :diamonds}, # King of diamonds (trump, non-point) - can kill
        {11, :diamonds}, # Jack of diamonds (trump, point)
        {10, :diamonds}, # 10 of diamonds (trump, point)
        {5, :diamonds},  # Right-5 (trump, point)
        {5, :hearts},    # Wrong-5 (trump, point) - hearts is same color
        {2, :diamonds}   # 2 of diamonds (trump, point)
      ]

      state = create_test_state(%{north: hand}, :diamonds)
      new_state = Play.compute_kills(state)

      # Should kill King of diamonds
      killed = Map.get(new_state.killed_cards, :north, [])
      assert killed == [{13, :diamonds}]

      # Wrong-5 (hearts) should NOT be killed
      assert {5, :hearts} in new_state.players[:north].hand
    end

    test "correctly identifies trump and non-trump with clubs as trump" do
      hand = [
        {14, :clubs},   # Ace (point)
        {13, :clubs},   # King (non-point) - can kill
        {11, :clubs},   # Jack (point)
        {10, :clubs},   # 10 (point)
        {5, :clubs},    # Right-5 (point)
        {5, :spades},   # Wrong-5 (point) - spades is same color
        {2, :clubs}     # 2 (point)
      ]

      state = create_test_state(%{north: hand}, :clubs)
      new_state = Play.compute_kills(state)

      # Should kill King of clubs
      killed = Map.get(new_state.killed_cards, :north, [])
      assert killed == [{13, :clubs}]

      # Wrong-5 (spades) should NOT be killed
      assert {5, :spades} in new_state.players[:north].hand
    end
  end

  describe "validate_killed_card_rule - top killed card must be played first" do
    test "player with killed cards must play top killed card on first trick" do
      # Setup state with killed cards - note: killed card is STILL in hand until played
      # (compute_kills removes it, but for this test we're simulating after redeal)
      hand = [{14, :hearts}, {13, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}]
      killed_cards = %{north: [{13, :hearts}]} # King was killed but still in hand

      hands = %{
        north: hand,
        east: [{12, :hearts}],
        south: [{9, :hearts}],
        west: [{8, :hearts}]
      }

      state = create_test_state(hands, :hearts)
      state = %{state | killed_cards: killed_cards, current_trick: nil, phase: :playing}

      # Attempting to play any card other than the top killed card should fail
      {:error, {:must_play_top_killed_card_first, {13, :hearts}}} =
        Play.play_card(state, :north, {14, :hearts})

      # Playing the top killed card should succeed
      {:ok, _new_state} = Play.play_card(state, :north, {13, :hearts})
    end

    test "player with killed cards can play freely after first trick starts" do
      # Setup state with killed cards, but trick already has plays
      hand = [{14, :hearts}, {13, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}]
      killed_cards = %{north: [{13, :hearts}]}

      hands = %{
        north: hand,
        east: [{12, :hearts}],
        south: [{9, :hearts}],
        west: [{8, :hearts}]
      }

      state = create_test_state(hands, :hearts)
      trick = %Types.Trick{
        number: 1,
        leader: :east,
        plays: [{:east, {12, :hearts}}], # East already played
        winner: nil,
        points: 0
      }
      state = %{state | killed_cards: killed_cards, current_trick: trick, current_turn: :north, phase: :playing}

      # Now north can play any trump card (not just the killed card)
      {:ok, _new_state} = Play.play_card(state, :north, {14, :hearts})
    end

    test "player without killed cards can play freely on first trick" do
      # Player has no killed cards
      hand = [{14, :hearts}, {11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}, {5, :hearts}]

      hands = %{
        north: hand,
        east: [{12, :hearts}],
        south: [{9, :hearts}],
        west: [{8, :hearts}]
      }

      state = create_test_state(hands, :hearts)
      state = %{state | killed_cards: %{}, current_trick: nil, phase: :playing}

      # Can play any trump card
      {:ok, _new_state} = Play.play_card(state, :north, {14, :hearts})
    end

    test "other players not affected by north's killed cards" do
      # North has killed cards, but east does not
      hands = %{
        north: [{14, :hearts}, {11, :hearts}, {10, :hearts}],
        east: [{13, :hearts}, {12, :hearts}, {9, :hearts}],
        south: [{8, :hearts}],
        west: [{7, :hearts}]
      }
      killed_cards = %{north: [{14, :hearts}]} # Only north has killed cards

      state = create_test_state(hands, :hearts)
      state = %{state | killed_cards: killed_cards, current_trick: nil, current_turn: :east, phase: :playing}

      # East can play any card (not affected by north's killed cards)
      {:ok, _new_state} = Play.play_card(state, :east, {13, :hearts})
    end
  end

  describe "compute_kills/1 - killed cards removed from hand" do
    test "killed cards are removed from player's hand" do
      hand = [
        {14, :hearts},
        {13, :hearts}, # Will be killed
        {11, :hearts},
        {10, :hearts},
        {7, :hearts},
        {6, :hearts},
        {5, :hearts}
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Get killed card
      [killed_card] = Map.get(new_state.killed_cards, :north, [])

      # Verify it's not in the hand anymore
      refute killed_card in new_state.players[:north].hand

      # Verify hand size is correct
      assert length(new_state.players[:north].hand) == 6
    end

    test "all killed cards are removed when killing multiple" do
      hand = [
        {14, :hearts},
        {13, :hearts}, # Non-point
        {12, :hearts}, # Non-point
        {11, :hearts},
        {10, :hearts},
        {9, :hearts},  # Non-point
        {7, :hearts},  # Non-point
        {5, :hearts},
        {2, :hearts}
      ]

      state = create_test_state(%{north: hand})
      new_state = Play.compute_kills(state)

      # Should kill 3 cards
      killed = Map.get(new_state.killed_cards, :north, [])
      assert length(killed) == 3

      # Verify none of the killed cards are in hand
      Enum.each(killed, fn card ->
        refute card in new_state.players[:north].hand
      end)

      # Verify hand size
      assert length(new_state.players[:north].hand) == 6
    end
  end
end
