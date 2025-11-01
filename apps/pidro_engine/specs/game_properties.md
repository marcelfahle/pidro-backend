# game_properties.md

## Overview

This document defines the **invariants, properties, and testable rules** for the Pidro game engine. These are "laws of the world" that must ALWAYS hold true, regardless of game state or player actions.

This document is designed for:

- Property-based testing (StreamData)
- Validation of game state integrity
- Regression testing
- Automated verification

**Related Documents:**

- `pidro_complete_specification.md` - Narrative game rules
- `agents.md` - Development and validation workflow

## Core Invariants

### Points System Invariants

```elixir
property "total points in a suit always equals 14" do
  check all trump_suit <- suit_generator() do
    point_cards = get_all_point_cards(trump_suit)
    total_points = Enum.sum(point_cards, & &1.point_value)

    assert total_points == 14
  end
end

property "point distribution is exactly: A(1) + J(1) + 10(1) + Right5(5) + Wrong5(5) + 2(1)" do
  check all trump_suit <- suit_generator() do
    points = get_point_values(trump_suit)

    assert points.ace == 1
    assert points.jack == 1
    assert points.ten == 1
    assert points.right_five == 5
    assert points.wrong_five == 5
    assert points.two == 1
  end
end

property "player with 2 of trump always keeps 1 point (cannot be taken)" do
  check all game_state <- complete_game_generator() do
    player_with_two = find_player_with_two_of_trump(game_state)

    if player_with_two do
      assert player_points(game_state, player_with_two) >= 1
    end
  end
end
```

### Card Deck Invariants

```elixir
property "deck always contains exactly 52 cards" do
  check all deck <- deck_generator() do
    assert length(deck.cards) == 52
  end
end

property "each suit contains exactly 14 cards (including cross-color 5)" do
  check all trump_suit <- suit_generator() do
    trump_cards = get_trump_cards(deck, trump_suit)

    # Right 5 + Wrong 5 + 12 other cards
    assert length(trump_cards) == 14
  end
end

property "5 of hearts is trump when hearts OR diamonds is trump" do
  five_hearts = Card.new(:five, :hearts)

  assert Card.is_trump?(five_hearts, :hearts) == true
  assert Card.is_trump?(five_hearts, :diamonds) == true
  assert Card.is_trump?(five_hearts, :clubs) == false
  assert Card.is_trump?(five_hearts, :spades) == false
end

property "5 of clubs is trump when clubs OR spades is trump" do
  five_clubs = Card.new(:five, :clubs)

  assert Card.is_trump?(five_clubs, :clubs) == true
  assert Card.is_trump?(five_clubs, :spades) == true
  assert Card.is_trump?(five_clubs, :hearts) == false
  assert Card.is_trump?(five_clubs, :diamonds) == false
end
```

### Card Ranking Invariants

```elixir
property "trump ranking is always: A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2" do
  check all trump_suit <- suit_generator() do
    ordered = [
      {:ace, trump_suit},
      {:king, trump_suit},
      {:queen, trump_suit},
      {:jack, trump_suit},
      {:ten, trump_suit},
      {:nine, trump_suit},
      {:eight, trump_suit},
      {:seven, trump_suit},
      {:six, trump_suit},
      {:five, trump_suit},  # Right 5
      {:five, same_color_suit(trump_suit)},  # Wrong 5
      {:four, trump_suit},
      {:three, trump_suit},
      {:two, trump_suit}
    ]

    # Verify each card beats the next
    ordered
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [higher, lower] ->
      assert Card.compare(higher, lower, trump_suit) == :gt
    end)
  end
end

property "right pidro always beats wrong pidro" do
  check all trump_suit <- suit_generator() do
    right_five = Card.new(:five, trump_suit)
    wrong_five = Card.new(:five, same_color_suit(trump_suit))

    assert Card.compare(right_five, wrong_five, trump_suit) == :gt
  end
end
```

## Game Flow Invariants

### Dealing Phase

```elixir
property "initial deal gives exactly 9 cards to each player" do
  check all game <- dealt_game_generator() do
    game.players
    |> Enum.all?(fn player ->
      length(player.hand) == 9
    end)
    |> assert()
  end
end

property "initial deal distributes cards in batches of 3" do
  # This is procedural, but we can test the result
  check all game <- dealt_game_generator() do
    # All 36 cards (9 × 4 players) are dealt
    total_dealt = game.players
                  |> Enum.map(&length(&1.hand))
                  |> Enum.sum()

    assert total_dealt == 36
  end
end

property "after initial deal, 16 cards remain in deck" do
  check all game <- dealt_game_generator() do
    assert length(game.deck.cards) == 16
  end
end
```

### Bidding Phase

```elixir
property "bid must be between 6 and 14 inclusive" do
  check all bid <- integer() do
    result = validate_bid_value(bid)

    if bid >= 6 and bid <= 14 do
      assert result == :ok
    else
      assert {:error, _} = result
    end
  end
end

property "bid must be higher than current bid (except pass)" do
  check all current_bid <- integer(6..14),
            new_bid <- integer() do
    result = validate_bid_higher(new_bid, current_bid)

    if new_bid > current_bid and new_bid <= 14 do
      assert result == :ok
    else
      assert {:error, _} = result
    end
  end
end

property "if all players pass, dealer must bid 6" do
  check all game <- all_players_passed_generator() do
    game_after_passes = process_all_passes(game)

    assert game_after_passes.current_bid == 6
    assert game_after_passes.bidding_player == :dealer
  end
end

property "exactly one round of bidding occurs" do
  check all game <- complete_bidding_generator() do
    # Each player gets exactly one chance to bid
    bid_count = length(game.bid_history)
    assert bid_count <= 4
  end
end

property "dealer is always last to bid" do
  check all game <- complete_bidding_generator() do
    last_bidder = List.last(game.bid_history).player
    assert last_bidder == game.dealer
  end
end
```

### Discarding and Re-dealing Phase

```elixir
property "after trump selection, all non-trump cards are discarded (except wrong 5)" do
  check all game <- trump_selected_generator() do
    game.players
    |> Enum.all?(fn player ->
      Enum.all?(player.hand, fn card ->
        Card.is_trump?(card, game.trump_suit)
      end)
    end)
    |> assert()
  end
end

property "after re-deal, each player has exactly 6 cards" do
  check all game <- re_dealt_game_generator() do
    game.players
    |> Enum.all?(fn player ->
      length(player.hand) == 6
    end)
    |> assert()
  end
end

property "dealer takes all remaining cards and selects 6" do
  check all game <- dealer_robbing_pack_generator() do
    dealer = find_dealer(game)
    assert length(dealer.hand) == 6
  end
end

property "if player has >6 trump after re-deal, must discard non-point cards" do
  check all player <- player_with_excess_trump_generator() do
    result = Player.discard_to_six(player)

    assert {:ok, updated_player} = result
    assert length(updated_player.hand) == 6

    # All point cards must remain
    point_cards_before = count_point_cards(player.hand)
    point_cards_after = count_point_cards(updated_player.hand)
    assert point_cards_after == point_cards_before
  end
end

property "cannot discard point cards when reducing hand to 6" do
  check all player <- player_with_excess_trump_generator() do
    # Attempt to discard a point card should fail
    point_card = find_point_card(player.hand)
    result = Player.discard_specific(player, point_card)

    assert {:error, _} = result
  end
end

property "discarded cards are laid face up and out of game" do
  check all game <- discarding_complete_generator() do
    # Discarded cards should be tracked separately
    assert is_list(game.discarded_cards)
    assert Enum.all?(game.discarded_cards, & &1.face_up == true)
  end
end
```

## Playing Phase Invariants

### Trick-Taking Rules

```elixir
property "only trump cards are valid plays" do
  check all game <- playing_phase_generator() do
    # All cards played must be trump
    game.tricks
    |> Enum.flat_map(& &1.cards_played)
    |> Enum.all?(fn card ->
      Card.is_trump?(card, game.trump_suit)
    end)
    |> assert()
  end
end

property "highest trump card wins the trick (except for 2)" do
  check all trick <- completed_trick_generator() do
    unless has_two_of_trump?(trick) do
      winner = Trick.winner(trick)
      winner_card = find_card_played_by(trick, winner)

      # Winner's card must be highest
      other_cards = Enum.reject(trick.cards_played, &(&1.player == winner))

      Enum.all?(other_cards, fn card ->
        Card.compare(winner_card, card, trick.trump_suit) == :gt
      end)
      |> assert()
    end
  end
end

property "player who wins trick leads next trick" do
  check all game <- mid_game_generator() do
    last_trick = List.last(game.completed_tricks)
    current_trick = game.current_trick

    if last_trick do
      assert current_trick.leader == last_trick.winner
    end
  end
end

property "when player has no trump, they go 'cold' and lay down remaining cards" do
  check all game <- player_out_of_trump_generator() do
    player = find_player_out_of_trump(game)

    assert player.is_cold == true
    assert player.hand == []
    assert length(player.revealed_cards) > 0
  end
end

property "cold player does not participate in remaining tricks" do
  check all game <- game_with_cold_players_generator() do
    cold_players = Enum.filter(game.players, & &1.is_cold)

    game.tricks
    |> Enum.all?(fn trick ->
      trick_players = Enum.map(trick.cards_played, & &1.player)

      Enum.all?(cold_players, fn cold ->
        cold.id not in trick_players
      end)
    end)
    |> assert()
  end
end
```

### Point Scoring

```elixir
property "highest card in trick wins all points in trick (except 2)" do
  check all trick <- completed_trick_generator() do
    winner = Trick.winner(trick)
    points_won = Trick.points(trick)
    two_points = if has_two_of_trump?(trick), do: 1, else: 0

    expected_points = sum_point_values(trick.cards_played) - two_points
    assert points_won == expected_points
  end
end

property "team with cards remaining after all others cold keeps all remaining points" do
  check all game <- only_one_team_has_cards_generator() do
    team_with_cards = find_team_with_cards(game)
    remaining_points = calculate_remaining_points(game)

    final_game = complete_round(game)
    team_score = get_team_score(final_game, team_with_cards)

    assert team_score >= remaining_points
  end
end
```

## Scoring Invariants

### Round Scoring

```elixir
property "if bidding team makes bid, they score points taken" do
  check all game <- completed_round_generator() do
    if bidding_team_made_bid?(game) do
      bidding_team = game.bidding_team
      points_taken = get_team_points_taken(game, bidding_team)
      score_awarded = get_team_score_awarded(game, bidding_team)

      assert score_awarded == points_taken
    end
  end
end

property "if bidding team fails bid, they lose bid amount (can go negative)" do
  check all game <- completed_round_generator() do
    unless bidding_team_made_bid?(game) do
      bidding_team = game.bidding_team
      previous_score = game.scores_before_round[bidding_team]
      current_score = game.current_scores[bidding_team]

      assert current_score == previous_score - game.bid_amount
    end
  end
end

property "defending team always keeps points they took" do
  check all game <- completed_round_generator() do
    defending_team = get_defending_team(game)
    points_taken = get_team_points_taken(game, defending_team)
    previous_score = game.scores_before_round[defending_team]
    current_score = game.current_scores[defending_team]

    assert current_score == previous_score + points_taken
  end
end

property "sum of points taken by both teams equals 14" do
  check all game <- completed_round_generator() do
    team1_points = get_team_points_taken(game, :team1)
    team2_points = get_team_points_taken(game, :team2)

    assert team1_points + team2_points == 14
  end
end
```

### Game End Conditions

```elixir
property "game ends when one team reaches 62 points" do
  check all game <- completed_game_generator() do
    winner_score = get_winning_team_score(game)
    assert winner_score >= 62
  end
end

property "if both teams reach 62, bidding team wins" do
  check all game <- both_teams_at_62_generator() do
    assert game.winner == game.bidding_team_final_round
  end
end

property "game cannot end mid-round" do
  check all game <- all_game_states_generator() do
    if game.phase == :complete do
      # Ensure we're not in middle of a trick
      assert game.current_trick == nil
      assert game.phase == :complete
    end
  end
end
```

## State Machine Invariants

### Valid State Transitions

```elixir
property "game phases transition in correct order" do
  valid_transitions = %{
    :not_started => [:bidding],
    :bidding => [:discarding],
    :discarding => [:playing],
    :playing => [:complete, :playing],  # Can stay in playing for multiple tricks
    :complete => []
  }

  check all game_sequence <- game_state_sequence_generator() do
    game_sequence
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [from_state, to_state] ->
      to_state.phase in valid_transitions[from_state.phase]
    end)
    |> assert()
  end
end

property "cannot bid after bidding phase complete" do
  check all game <- post_bidding_game_generator() do
    result = Game.place_bid(game, player_id, 7)
    assert {:error, _} = result
  end
end

property "cannot play card before playing phase" do
  check all game <- pre_playing_game_generator() do
    result = Game.play_card(game, player_id, card)
    assert {:error, _} = result
  end
end

property "game state is immutable - operations return new state" do
  check all game <- any_game_state_generator() do
    original_id = :erlang.phash2(game)

    _result = Game.some_operation(game)

    # Original game unchanged
    assert :erlang.phash2(game) == original_id
  end
end
```

## Player Invariants

```elixir
property "exactly 4 players in every game" do
  check all game <- any_game_state_generator() do
    assert length(game.players) == 4
  end
end

property "players are in two teams of 2" do
  check all game <- any_game_state_generator() do
    team1 = Enum.filter(game.players, &(&1.team == :team1))
    team2 = Enum.filter(game.players, &(&1.team == :team2))

    assert length(team1) == 2
    assert length(team2) == 2
  end
end

property "partners sit opposite each other" do
  check all game <- any_game_state_generator() do
    positions = [:north, :south, :east, :west]

    # North and South are partners
    # East and West are partners
    north = find_player_at(game, :north)
    south = find_player_at(game, :south)
    assert north.team == south.team

    east = find_player_at(game, :east)
    west = find_player_at(game, :west)
    assert east.team == west.team
  end
end

property "player hands never exceed 9 cards initially, then 6 after re-deal" do
  check all game <- any_game_state_generator() do
    max_cards = case game.phase do
      :not_started -> 0
      :bidding -> 9
      _ -> 6
    end

    game.players
    |> Enum.all?(fn player ->
      length(player.hand) <= max_cards
    end)
    |> assert()
  end
end
```

## Edge Case Properties

### Special Rule Edge Cases

```elixir
property "bidding 14 can be topped by another bid of 14" do
  game = setup_game(current_bid: 14, bidder: "player1")

  result = Game.place_bid(game, "player2", 14)
  assert {:ok, updated_game} = result
  assert updated_game.current_bid == 14
  assert updated_game.bidding_player == "player2"
end

property "cannot discard point cards to reduce hand size" do
  point_cards = [
    Card.new(:ace, :hearts),
    Card.new(:jack, :hearts),
    Card.new(:ten, :hearts),
    Card.new(:five, :hearts),
    Card.new(:five, :diamonds),
    Card.new(:two, :hearts)
  ]

  check all card <- member_of(point_cards),
            player <- player_with_excess_trump(card) do
    result = Player.discard(player, card)
    assert {:error, "Cannot discard point cards"} = result
  end
end

property "dealer gets no cards if all players keep 6 trump cards" do
  check all game <- all_players_have_six_trump_generator() do
    dealer = find_dealer(game)
    cards_available_to_dealer = length(game.deck.cards)

    assert cards_available_to_dealer == 0
  end
end

property "player revealing non-trump when going cold shows violation" do
  # When player goes cold, revealed cards should all be non-trump
  check all game <- player_going_cold_generator() do
    cold_player = find_player_going_cold(game)

    cold_player.revealed_cards
    |> Enum.all?(fn card ->
      not Card.is_trump?(card, game.trump_suit)
    end)
    |> assert()
  end
end
```

## Performance Properties

```elixir
property "game state serialization is deterministic" do
  check all game <- any_game_state_generator() do
    serialized1 = serialize(game)
    serialized2 = serialize(game)

    assert serialized1 == serialized2
  end
end

property "card comparison is transitive" do
  # If A > B and B > C, then A > C
  check all card_a <- card_generator(),
            card_b <- card_generator(),
            card_c <- card_generator(),
            trump <- suit_generator() do
    if Card.compare(card_a, card_b, trump) == :gt and
       Card.compare(card_b, card_c, trump) == :gt do
      assert Card.compare(card_a, card_c, trump) == :gt
    end
  end
end

property "game operations complete in reasonable time" do
  check all game <- any_game_state_generator(),
            operation <- game_operation_generator() do
    {time_us, _result} = :timer.tc(fn ->
      apply_operation(game, operation)
    end)

    # No operation should take > 10ms
    assert time_us < 10_000
  end
end
```

## Test Data Generators

```elixir
# Example generators for StreamData

def suit_generator do
  member_of([:hearts, :diamonds, :clubs, :spades])
end

def rank_generator do
  member_of([
    :ace, :king, :queen, :jack, :ten,
    :nine, :eight, :seven, :six, :five,
    :four, :three, :two
  ])
end

def card_generator do
  gen all rank <- rank_generator(),
          suit <- suit_generator() do
    Card.new(rank, suit)
  end
end

def deck_generator do
  # Generate valid 52-card deck
  constant(Deck.new())
end

def game_generator do
  gen all phase <- member_of([:not_started, :bidding, :discarding, :playing, :complete]),
          # ... build valid game state for phase
  do
    build_game_state(phase: phase, ...)
  end
end

def valid_bid_generator do
  integer(6..14)
end

def complete_game_generator do
  # Generate a game that has completed
  # Use this to test end conditions
end
```

## Validation Commands

```bash
# Run all property tests
mix test --only property

# Run specific property test file
mix test test/properties/scoring_properties_test.exs

# Run with many iterations for confidence
mix test --only property --seed 0 --max-cases 1000

# Run with specific seed to reproduce failure
mix test --only property --seed 12345
```

## Property Test Organization

```
test/
└── properties/
    ├── card_properties_test.exs         # Card and deck invariants
    ├── bidding_properties_test.exs      # Bidding phase properties
    ├── dealing_properties_test.exs      # Deal and re-deal properties
    ├── trick_properties_test.exs        # Trick-taking properties
    ├── scoring_properties_test.exs      # Scoring invariants
    ├── state_machine_properties_test.exs # State transitions
    └── generators.ex                     # Shared test data generators
```

## Success Criteria

A feature is ONLY complete when:

- [ ] All relevant properties pass with 100 test cases
- [ ] Properties pass with random seeds (multiple runs)
- [ ] Edge case properties explicitly tested
- [ ] Generators produce valid game states
- [ ] Properties are documented with examples
- [ ] Property tests run in < 5 seconds total

---

**Philosophy**: If a property can be violated, the implementation is wrong. Properties define the "impossible states" - if you can generate them, you've found a bug.
