defmodule Pidro.Core.GameStateTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.GameState
  alias Pidro.Core.Types.GameState, as: GameStateStruct
  alias Pidro.Core.Types.Player

  @dialyzer :no_match

  describe "new/0" do
    test "creates initial state in :dealer_selection phase" do
      state = GameState.new()

      assert state.phase == :dealer_selection
    end

    test "creates state with hand_number set to 1" do
      state = GameState.new()

      assert state.hand_number == 1
    end

    test "creates state with :finnish variant" do
      state = GameState.new()

      assert state.variant == :finnish
    end

    test "creates 4 players" do
      state = GameState.new()

      assert map_size(state.players) == 4
      assert Map.has_key?(state.players, :north)
      assert Map.has_key?(state.players, :east)
      assert Map.has_key?(state.players, :south)
      assert Map.has_key?(state.players, :west)
    end

    test "creates players with correct positions" do
      state = GameState.new()

      assert state.players[:north].position == :north
      assert state.players[:east].position == :east
      assert state.players[:south].position == :south
      assert state.players[:west].position == :west
    end

    test "creates players with correct team assignments" do
      state = GameState.new()

      # North/South partnership
      assert state.players[:north].team == :north_south
      assert state.players[:south].team == :north_south

      # East/West partnership
      assert state.players[:east].team == :east_west
      assert state.players[:west].team == :east_west
    end

    test "creates players with empty hands" do
      state = GameState.new()

      assert state.players[:north].hand == []
      assert state.players[:east].hand == []
      assert state.players[:south].hand == []
      assert state.players[:west].hand == []
    end

    test "creates players as active (not eliminated)" do
      state = GameState.new()

      assert state.players[:north].eliminated? == false
      assert state.players[:east].eliminated? == false
      assert state.players[:south].eliminated? == false
      assert state.players[:west].eliminated? == false
    end

    test "creates players with no revealed cards" do
      state = GameState.new()

      assert state.players[:north].revealed_cards == []
      assert state.players[:east].revealed_cards == []
      assert state.players[:south].revealed_cards == []
      assert state.players[:west].revealed_cards == []
    end

    test "creates players with zero tricks won" do
      state = GameState.new()

      assert state.players[:north].tricks_won == 0
      assert state.players[:east].tricks_won == 0
      assert state.players[:south].tricks_won == 0
      assert state.players[:west].tricks_won == 0
    end

    test "initializes current_dealer as nil" do
      state = GameState.new()

      assert state.current_dealer == nil
    end

    test "initializes current_turn as nil" do
      state = GameState.new()

      assert state.current_turn == nil
    end

    test "initializes deck as empty list" do
      state = GameState.new()

      assert state.deck == []
    end

    test "initializes discarded_cards as empty list" do
      state = GameState.new()

      assert state.discarded_cards == []
    end

    test "initializes bids as empty list" do
      state = GameState.new()

      assert state.bids == []
    end

    test "initializes highest_bid as nil" do
      state = GameState.new()

      assert state.highest_bid == nil
    end

    test "initializes bidding_team as nil" do
      state = GameState.new()

      assert state.bidding_team == nil
    end

    test "initializes trump_suit as nil" do
      state = GameState.new()

      assert state.trump_suit == nil
    end

    test "initializes tricks as empty list" do
      state = GameState.new()

      assert state.tricks == []
    end

    test "initializes current_trick as nil" do
      state = GameState.new()

      assert state.current_trick == nil
    end

    test "initializes trick_number to 0" do
      state = GameState.new()

      assert state.trick_number == 0
    end

    test "initializes hand_points with both teams at 0" do
      state = GameState.new()

      assert state.hand_points == %{north_south: 0, east_west: 0}
      assert state.hand_points[:north_south] == 0
      assert state.hand_points[:east_west] == 0
    end

    test "initializes cumulative_scores with both teams at 0" do
      state = GameState.new()

      assert state.cumulative_scores == %{north_south: 0, east_west: 0}
      assert state.cumulative_scores[:north_south] == 0
      assert state.cumulative_scores[:east_west] == 0
    end

    test "initializes winner as nil" do
      state = GameState.new()

      assert state.winner == nil
    end

    test "initializes events as empty list" do
      state = GameState.new()

      assert state.events == []
    end

    test "initializes config with default values" do
      state = GameState.new()

      assert state.config.min_bid == 6
      assert state.config.max_bid == 14
      assert state.config.winning_score == 62
      assert state.config.initial_deal_count == 9
      assert state.config.final_hand_size == 6
      assert state.config.allow_negative_scores == true
    end

    test "initializes cache as empty map" do
      state = GameState.new()

      assert state.cache == %{}
    end

    test "creates valid GameState struct" do
      state = GameState.new()

      assert %GameStateStruct{} = state
    end

    test "all players have valid Player structs" do
      state = GameState.new()

      assert %Player{} = state.players[:north]
      assert %Player{} = state.players[:east]
      assert %Player{} = state.players[:south]
      assert %Player{} = state.players[:west]
    end
  end

  describe "update/3" do
    test "updates phase field" do
      state = GameState.new()

      state = GameState.update(state, :phase, :dealing)

      assert state.phase == :dealing
    end

    test "updates phase through all game phases" do
      state = GameState.new()
      assert state.phase == :dealer_selection

      state = GameState.update(state, :phase, :dealing)
      assert state.phase == :dealing

      state = GameState.update(state, :phase, :bidding)
      assert state.phase == :bidding

      state = GameState.update(state, :phase, :declaring)
      assert state.phase == :declaring

      state = GameState.update(state, :phase, :discarding)
      assert state.phase == :discarding

      state = GameState.update(state, :phase, :second_deal)
      assert state.phase == :second_deal

      state = GameState.update(state, :phase, :playing)
      assert state.phase == :playing

      state = GameState.update(state, :phase, :scoring)
      assert state.phase == :scoring

      state = GameState.update(state, :phase, :complete)
      assert state.phase == :complete
    end

    test "updates current_dealer field" do
      state = GameState.new()

      state = GameState.update(state, :current_dealer, :north)

      assert state.current_dealer == :north
    end

    test "updates current_dealer to all valid positions" do
      state = GameState.new()

      state = GameState.update(state, :current_dealer, :north)
      assert state.current_dealer == :north

      state = GameState.update(state, :current_dealer, :east)
      assert state.current_dealer == :east

      state = GameState.update(state, :current_dealer, :south)
      assert state.current_dealer == :south

      state = GameState.update(state, :current_dealer, :west)
      assert state.current_dealer == :west
    end

    test "updates current_turn field" do
      state = GameState.new()

      state = GameState.update(state, :current_turn, :east)

      assert state.current_turn == :east
    end

    test "updates trump_suit field" do
      state = GameState.new()

      state = GameState.update(state, :trump_suit, :hearts)

      assert state.trump_suit == :hearts
    end

    test "updates trump_suit to all valid suits" do
      state = GameState.new()

      state = GameState.update(state, :trump_suit, :hearts)
      assert state.trump_suit == :hearts

      state = GameState.update(state, :trump_suit, :diamonds)
      assert state.trump_suit == :diamonds

      state = GameState.update(state, :trump_suit, :clubs)
      assert state.trump_suit == :clubs

      state = GameState.update(state, :trump_suit, :spades)
      assert state.trump_suit == :spades
    end

    test "updates hand_number field" do
      state = GameState.new()

      state = GameState.update(state, :hand_number, 2)

      assert state.hand_number == 2
    end

    test "updates trick_number field" do
      state = GameState.new()

      state = GameState.update(state, :trick_number, 3)

      assert state.trick_number == 3
    end

    test "updates bidding_team field" do
      state = GameState.new()

      state = GameState.update(state, :bidding_team, :north_south)

      assert state.bidding_team == :north_south
    end

    test "updates highest_bid field" do
      state = GameState.new()

      state = GameState.update(state, :highest_bid, {:north, 10})

      assert state.highest_bid == {:north, 10}
    end

    test "updates winner field" do
      state = GameState.new()

      state = GameState.update(state, :winner, :east_west)

      assert state.winner == :east_west
    end

    test "updates deck field" do
      state = GameState.new()
      cards = [{14, :hearts}, {13, :hearts}]

      state = GameState.update(state, :deck, cards)

      assert state.deck == cards
    end

    test "updates discarded_cards field" do
      state = GameState.new()
      cards = [{7, :clubs}, {8, :spades}]

      state = GameState.update(state, :discarded_cards, cards)

      assert state.discarded_cards == cards
    end

    test "updates bids field" do
      state = GameState.new()
      bids = [%{position: :north, amount: 8}, %{position: :east, amount: 10}]

      state = GameState.update(state, :bids, bids)

      assert state.bids == bids
    end

    test "updates tricks field" do
      state = GameState.new()
      tricks = [%{number: 1, leader: :north, plays: [], winner: nil, points: 0}]

      state = GameState.update(state, :tricks, tricks)

      assert state.tricks == tricks
    end

    test "updates current_trick field" do
      state = GameState.new()
      trick = %{number: 1, leader: :north, plays: [], winner: nil, points: 0}

      state = GameState.update(state, :current_trick, trick)

      assert state.current_trick == trick
    end

    test "updates hand_points field" do
      state = GameState.new()
      points = %{north_south: 10, east_west: 4}

      state = GameState.update(state, :hand_points, points)

      assert state.hand_points == points
      assert state.hand_points[:north_south] == 10
      assert state.hand_points[:east_west] == 4
    end

    test "updates cumulative_scores field" do
      state = GameState.new()
      scores = %{north_south: 35, east_west: 27}

      state = GameState.update(state, :cumulative_scores, scores)

      assert state.cumulative_scores == scores
      assert state.cumulative_scores[:north_south] == 35
      assert state.cumulative_scores[:east_west] == 27
    end

    test "updates events field" do
      state = GameState.new()
      events = [{:dealer_selected, :north, {14, :hearts}}]

      state = GameState.update(state, :events, events)

      assert state.events == events
    end

    test "updates config field" do
      state = GameState.new()
      new_config = %{min_bid: 7, max_bid: 14, winning_score: 52}

      state = GameState.update(state, :config, new_config)

      assert state.config == new_config
    end

    test "updates cache field" do
      state = GameState.new()
      cache_data = %{some_key: "some_value"}

      state = GameState.update(state, :cache, cache_data)

      assert state.cache == cache_data
    end

    test "updates players field with modified player map" do
      state = GameState.new()
      updated_players = Map.put(state.players, :north, %{state.players[:north] | tricks_won: 2})

      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].tricks_won == 2
    end

    test "returns new GameState struct (immutability)" do
      original = GameState.new()
      updated = GameState.update(original, :phase, :dealing)

      assert original.phase == :dealer_selection
      assert updated.phase == :dealing
      refute original == updated
    end

    test "preserves other fields when updating one field" do
      state = GameState.new()
      original_hand_number = state.hand_number
      original_players = state.players

      state = GameState.update(state, :phase, :dealing)

      assert state.phase == :dealing
      assert state.hand_number == original_hand_number
      assert state.players == original_players
    end

    test "can chain multiple updates" do
      state = GameState.new()

      state =
        state
        |> GameState.update(:phase, :dealing)
        |> GameState.update(:current_dealer, :north)
        |> GameState.update(:trump_suit, :hearts)

      assert state.phase == :dealing
      assert state.current_dealer == :north
      assert state.trump_suit == :hearts
    end

    test "can update same field multiple times" do
      state = GameState.new()

      state = GameState.update(state, :trick_number, 1)
      assert state.trick_number == 1

      state = GameState.update(state, :trick_number, 2)
      assert state.trick_number == 2

      state = GameState.update(state, :trick_number, 3)
      assert state.trick_number == 3
    end

    test "can update field to nil" do
      state = GameState.new()
      state = GameState.update(state, :current_dealer, :north)

      state = GameState.update(state, :current_dealer, nil)

      assert state.current_dealer == nil
    end

    test "can update field back to original value" do
      state = GameState.new()
      state = GameState.update(state, :phase, :dealing)

      state = GameState.update(state, :phase, :dealer_selection)

      assert state.phase == :dealer_selection
    end
  end

  describe "update/3 edge cases" do
    test "can update to empty lists" do
      state = GameState.new()
      state = GameState.update(state, :events, [{:dealer_selected, :north, {14, :hearts}}])

      state = GameState.update(state, :events, [])

      assert state.events == []
    end

    test "can update to empty maps" do
      state = GameState.new()
      state = GameState.update(state, :cache, %{key: "value"})

      state = GameState.update(state, :cache, %{})

      assert state.cache == %{}
    end

    test "can update scores to negative values (when allowed)" do
      state = GameState.new()

      state = GameState.update(state, :cumulative_scores, %{north_south: -5, east_west: 10})

      assert state.cumulative_scores[:north_south] == -5
      assert state.cumulative_scores[:east_west] == 10
    end

    test "can update hand_number to higher values" do
      state = GameState.new()

      state = GameState.update(state, :hand_number, 15)

      assert state.hand_number == 15
    end

    test "can update trick_number through all possible tricks (0-6)" do
      state = GameState.new()

      for trick_num <- 0..6 do
        state = GameState.update(state, :trick_number, trick_num)
        assert state.trick_number == trick_num
      end
    end

    test "preserves struct type after update" do
      state = GameState.new()

      state = GameState.update(state, :phase, :dealing)

      assert %GameStateStruct{} = state
    end

    test "update with atom key works correctly" do
      state = GameState.new()

      state = GameState.update(state, :phase, :bidding)

      assert state.phase == :bidding
    end
  end

  describe "update/3 with nested player updates" do
    test "can update individual player in players map" do
      state = GameState.new()
      north_player = state.players[:north]
      updated_north = %{north_player | tricks_won: 3}
      updated_players = Map.put(state.players, :north, updated_north)

      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].tricks_won == 3
      assert state.players[:east].tricks_won == 0
    end

    test "can update player hand through players map" do
      state = GameState.new()
      north_player = state.players[:north]
      cards = [{14, :hearts}, {13, :hearts}]
      updated_north = %{north_player | hand: cards}
      updated_players = Map.put(state.players, :north, updated_north)

      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].hand == cards
      assert state.players[:east].hand == []
    end

    test "can eliminate player through players map" do
      state = GameState.new()
      north_player = state.players[:north]
      updated_north = %{north_player | eliminated?: true}
      updated_players = Map.put(state.players, :north, updated_north)

      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].eliminated? == true
      assert state.players[:east].eliminated? == false
    end

    test "multiple player updates preserve independence" do
      state = GameState.new()

      # Update north player
      north_player = state.players[:north]
      updated_north = %{north_player | tricks_won: 2}
      updated_players = Map.put(state.players, :north, updated_north)
      state = GameState.update(state, :players, updated_players)

      # Update east player
      east_player = state.players[:east]
      updated_east = %{east_player | tricks_won: 1}
      updated_players = Map.put(state.players, :east, updated_east)
      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].tricks_won == 2
      assert state.players[:east].tricks_won == 1
      assert state.players[:south].tricks_won == 0
      assert state.players[:west].tricks_won == 0
    end
  end

  describe "update/3 invalid updates" do
    test "raises FunctionClauseError when key is not an atom" do
      state = GameState.new()

      assert_raise FunctionClauseError, fn ->
        GameState.update(state, "phase", :dealing)
      end
    end

    test "raises FunctionClauseError when first argument is not a GameState" do
      # These intentionally pass invalid types to test error handling
      # Using apply/3 to bypass compile-time type checking
      assert_raise FunctionClauseError, fn ->
        apply(GameState, :update, [%{}, :phase, :dealing])
      end

      assert_raise FunctionClauseError, fn ->
        apply(GameState, :update, [nil, :phase, :dealing])
      end

      assert_raise FunctionClauseError, fn ->
        apply(GameState, :update, ["not a state", :phase, :dealing])
      end
    end
  end

  describe "GameState immutability" do
    test "new/0 returns structs with equal values" do
      state1 = GameState.new()
      state2 = GameState.new()

      # They have equal values
      assert state1.phase == state2.phase
      assert state1 == state2
    end

    test "update returns new struct, original unchanged" do
      original = GameState.new()
      updated = GameState.update(original, :phase, :dealing)

      assert original.phase == :dealer_selection
      assert updated.phase == :dealing
    end

    test "multiple updates create new structs each time" do
      state1 = GameState.new()
      state2 = GameState.update(state1, :phase, :dealing)
      state3 = GameState.update(state2, :current_dealer, :north)

      assert state1.phase == :dealer_selection
      assert state1.current_dealer == nil

      assert state2.phase == :dealing
      assert state2.current_dealer == nil

      assert state3.phase == :dealing
      assert state3.current_dealer == :north

      refute state1 == state2
      refute state2 == state3
      refute state1 == state3
    end

    test "updating nested players doesn't affect original" do
      original = GameState.new()
      north_player = original.players[:north]
      updated_north = %{north_player | tricks_won: 5}
      updated_players = Map.put(original.players, :north, updated_north)
      updated_state = GameState.update(original, :players, updated_players)

      assert original.players[:north].tricks_won == 0
      assert updated_state.players[:north].tricks_won == 5
    end
  end

  describe "typical game flow with GameState" do
    test "can progress through dealer selection to dealing" do
      state = GameState.new()
      assert state.phase == :dealer_selection

      # Select dealer
      state = GameState.update(state, :current_dealer, :north)
      state = GameState.update(state, :phase, :dealing)

      assert state.current_dealer == :north
      assert state.phase == :dealing
    end

    test "can progress through bidding phase" do
      state = GameState.new()

      # Move to bidding
      state = GameState.update(state, :phase, :bidding)
      state = GameState.update(state, :current_turn, :north)

      # Record a bid
      state = GameState.update(state, :highest_bid, {:north, 10})
      state = GameState.update(state, :bidding_team, :north_south)

      assert state.phase == :bidding
      assert state.highest_bid == {:north, 10}
      assert state.bidding_team == :north_south
    end

    test "can declare trump and move to discarding" do
      state = GameState.new()

      state = GameState.update(state, :phase, :declaring)
      state = GameState.update(state, :trump_suit, :hearts)
      state = GameState.update(state, :phase, :discarding)

      assert state.trump_suit == :hearts
      assert state.phase == :discarding
    end

    test "can progress to playing phase" do
      state = GameState.new()

      state = GameState.update(state, :phase, :playing)
      state = GameState.update(state, :trick_number, 1)
      state = GameState.update(state, :current_turn, :north)

      assert state.phase == :playing
      assert state.trick_number == 1
      assert state.current_turn == :north
    end

    test "can track hand points during play" do
      state = GameState.new()

      state = GameState.update(state, :phase, :playing)
      state = GameState.update(state, :hand_points, %{north_south: 8, east_west: 6})

      assert state.hand_points[:north_south] == 8
      assert state.hand_points[:east_west] == 6
    end

    test "can complete game with winner" do
      state = GameState.new()

      state = GameState.update(state, :phase, :scoring)
      state = GameState.update(state, :cumulative_scores, %{north_south: 62, east_west: 45})
      state = GameState.update(state, :winner, :north_south)
      state = GameState.update(state, :phase, :complete)

      assert state.cumulative_scores[:north_south] == 62
      assert state.winner == :north_south
      assert state.phase == :complete
    end

    test "can simulate multiple hands" do
      state = GameState.new()
      assert state.hand_number == 1

      # Complete first hand
      state = GameState.update(state, :phase, :scoring)
      state = GameState.update(state, :cumulative_scores, %{north_south: 14, east_west: 0})

      # Start second hand
      state = GameState.update(state, :hand_number, 2)
      state = GameState.update(state, :phase, :dealing)
      state = GameState.update(state, :hand_points, %{north_south: 0, east_west: 0})

      assert state.hand_number == 2
      assert state.phase == :dealing
      assert state.cumulative_scores[:north_south] == 14
    end
  end

  describe "Finnish Pidro specific scenarios" do
    test "can track player going cold" do
      state = GameState.new()
      north_player = state.players[:north]
      revealed = [{7, :clubs}, {8, :spades}]
      updated_north = %{north_player | eliminated?: true, revealed_cards: revealed}
      updated_players = Map.put(state.players, :north, updated_north)

      state = GameState.update(state, :players, updated_players)

      assert state.players[:north].eliminated? == true
      assert state.players[:north].revealed_cards == revealed
    end

    test "supports all trump suits for Finnish variant" do
      state = GameState.new()

      # Hearts trump
      state = GameState.update(state, :trump_suit, :hearts)
      assert state.trump_suit == :hearts

      # Diamonds trump
      state = GameState.update(state, :trump_suit, :diamonds)
      assert state.trump_suit == :diamonds

      # Clubs trump
      state = GameState.update(state, :trump_suit, :clubs)
      assert state.trump_suit == :clubs

      # Spades trump
      state = GameState.update(state, :trump_suit, :spades)
      assert state.trump_suit == :spades
    end

    test "can handle negative scores when allowed" do
      state = GameState.new()
      assert state.config.allow_negative_scores == true

      # Team fails to make bid
      state = GameState.update(state, :cumulative_scores, %{north_south: -10, east_west: 10})

      assert state.cumulative_scores[:north_south] == -10
      assert state.cumulative_scores[:east_west] == 10
    end

    test "config has Finnish Pidro default values" do
      state = GameState.new()

      assert state.config.initial_deal_count == 9
      assert state.config.final_hand_size == 6
      assert state.config.min_bid == 6
      assert state.config.max_bid == 14
      assert state.config.winning_score == 62
    end
  end

  describe "event sourcing support" do
    test "can record dealer selection event" do
      state = GameState.new()
      event = {:dealer_selected, :north, {14, :hearts}}

      state = GameState.update(state, :events, [event])

      assert state.events == [event]
    end

    test "can accumulate multiple events" do
      state = GameState.new()
      event1 = {:dealer_selected, :north, {14, :hearts}}
      event2 = {:cards_dealt, %{north: [{13, :hearts}], east: [{12, :hearts}]}}
      event3 = {:bid_made, :north, 10}

      state = GameState.update(state, :events, [event1])
      state = GameState.update(state, :events, [event1, event2])
      state = GameState.update(state, :events, [event1, event2, event3])

      assert length(state.events) == 3
      assert event1 in state.events
      assert event2 in state.events
      assert event3 in state.events
    end

    test "events list maintains order" do
      state = GameState.new()
      event1 = {:dealer_selected, :north, {14, :hearts}}
      event2 = {:bid_made, :north, 10}
      event3 = {:trump_declared, :hearts}

      state = GameState.update(state, :events, [event1, event2, event3])

      assert state.events == [event1, event2, event3]
    end
  end

  describe "cache field usage" do
    test "can store computed values in cache" do
      state = GameState.new()

      state = GameState.update(state, :cache, %{active_players: [:north, :east, :south, :west]})

      assert state.cache.active_players == [:north, :east, :south, :west]
    end

    test "can update cache with multiple keys" do
      state = GameState.new()

      cache = %{
        active_players: [:north, :south],
        trump_count: 14,
        tricks_remaining: 4
      }

      state = GameState.update(state, :cache, cache)

      assert state.cache.active_players == [:north, :south]
      assert state.cache.trump_count == 14
      assert state.cache.tricks_remaining == 4
    end

    test "cache can be cleared" do
      state = GameState.new()
      state = GameState.update(state, :cache, %{key: "value"})

      state = GameState.update(state, :cache, %{})

      assert state.cache == %{}
    end
  end
end
