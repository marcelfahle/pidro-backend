defmodule Pidro.Core.PlayerTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Player

  describe "new/2" do
    test "creates player with correct position and team" do
      player = Player.new(:north, :north_south)

      assert player.position == :north
      assert player.team == :north_south
      assert player.hand == []
      assert player.eliminated? == false
      assert player.revealed_cards == []
      assert player.tricks_won == 0
    end

    test "creates players for all valid positions" do
      player_north = Player.new(:north, :north_south)
      assert player_north.position == :north
      assert player_north.team == :north_south

      player_south = Player.new(:south, :north_south)
      assert player_south.position == :south
      assert player_south.team == :north_south

      player_east = Player.new(:east, :east_west)
      assert player_east.position == :east
      assert player_east.team == :east_west

      player_west = Player.new(:west, :east_west)
      assert player_west.position == :west
      assert player_west.team == :east_west
    end

    test "creates player with empty hand by default" do
      player = Player.new(:north, :north_south)
      assert player.hand == []
      assert Player.hand_size(player) == 0
    end

    test "creates player as active (not eliminated) by default" do
      player = Player.new(:north, :north_south)
      assert player.eliminated? == false
      assert Player.active?(player) == true
    end

    test "creates player with no revealed cards by default" do
      player = Player.new(:north, :north_south)
      assert player.revealed_cards == []
    end

    test "creates player with zero tricks won by default" do
      player = Player.new(:north, :north_south)
      assert player.tricks_won == 0
    end

    test "raises FunctionClauseError for invalid position" do
      assert_raise FunctionClauseError, fn ->
        Player.new(:invalid, :north_south)
      end

      assert_raise FunctionClauseError, fn ->
        Player.new(:northeast, :north_south)
      end

      assert_raise FunctionClauseError, fn ->
        Player.new("north", :north_south)
      end
    end

    test "raises FunctionClauseError for invalid team" do
      assert_raise FunctionClauseError, fn ->
        Player.new(:north, :invalid)
      end

      assert_raise FunctionClauseError, fn ->
        Player.new(:north, :team1)
      end

      assert_raise FunctionClauseError, fn ->
        Player.new(:north, "north_south")
      end
    end
  end

  describe "add_cards/2" do
    test "adds cards to empty hand" do
      player = Player.new(:north, :north_south)
      cards = [{14, :hearts}, {13, :hearts}]

      player = Player.add_cards(player, cards)

      assert length(player.hand) == 2
      assert {14, :hearts} in player.hand
      assert {13, :hearts} in player.hand
    end

    test "adds cards to existing hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}])

      assert length(player.hand) == 1

      player = Player.add_cards(player, [{13, :hearts}, {12, :hearts}])

      assert length(player.hand) == 3
      assert {14, :hearts} in player.hand
      assert {13, :hearts} in player.hand
      assert {12, :hearts} in player.hand
    end

    test "appends cards to end of hand (maintains order)" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])
      player = Player.add_cards(player, [{12, :hearts}, {11, :hearts}])

      assert player.hand == [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}]
    end

    test "adds single card in a list" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}])

      assert length(player.hand) == 1
      assert player.hand == [{14, :hearts}]
    end

    test "adds empty list of cards (no change)" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}])

      original_hand = player.hand
      player = Player.add_cards(player, [])

      assert player.hand == original_hand
      assert length(player.hand) == 1
    end

    test "allows duplicate cards (though shouldn't occur in normal gameplay)" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {14, :hearts}])

      assert length(player.hand) == 2
      assert Enum.count(player.hand, fn c -> c == {14, :hearts} end) == 2
    end

    test "adds cards of different suits" do
      player = Player.new(:north, :north_south)
      cards = [
        {14, :hearts},
        {13, :diamonds},
        {12, :clubs},
        {11, :spades}
      ]

      player = Player.add_cards(player, cards)

      assert length(player.hand) == 4
      assert {14, :hearts} in player.hand
      assert {13, :diamonds} in player.hand
      assert {12, :clubs} in player.hand
      assert {11, :spades} in player.hand
    end

    test "adds typical initial deal of 9 cards" do
      player = Player.new(:north, :north_south)
      cards = [
        {14, :hearts}, {13, :hearts}, {12, :hearts},
        {11, :hearts}, {10, :hearts}, {9, :hearts},
        {8, :hearts}, {7, :hearts}, {6, :hearts}
      ]

      player = Player.add_cards(player, cards)

      assert length(player.hand) == 9
    end
  end

  describe "remove_card/2" do
    test "removes card from hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      player = Player.remove_card(player, {14, :hearts})

      assert length(player.hand) == 1
      assert player.hand == [{13, :hearts}]
      refute {14, :hearts} in player.hand
    end

    test "removes only first occurrence of duplicate card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}, {14, :hearts}])

      player = Player.remove_card(player, {14, :hearts})

      assert length(player.hand) == 2
      assert player.hand == [{13, :hearts}, {14, :hearts}]
      assert Enum.count(player.hand, fn c -> c == {14, :hearts} end) == 1
    end

    test "returns unchanged player if card not in hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      original_hand = player.hand
      player = Player.remove_card(player, {10, :clubs})

      assert player.hand == original_hand
      assert length(player.hand) == 2
    end

    test "handles removing card from empty hand" do
      player = Player.new(:north, :north_south)

      player = Player.remove_card(player, {14, :hearts})

      assert player.hand == []
    end

    test "removes last remaining card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}])

      player = Player.remove_card(player, {14, :hearts})

      assert player.hand == []
      assert length(player.hand) == 0
    end

    test "maintains order of remaining cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}
      ])

      player = Player.remove_card(player, {13, :hearts})

      assert player.hand == [{14, :hearts}, {12, :hearts}, {11, :hearts}]
    end

    test "removes card from middle of hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts}, {13, :hearts}, {12, :hearts}
      ])

      player = Player.remove_card(player, {13, :hearts})

      assert player.hand == [{14, :hearts}, {12, :hearts}]
    end

    test "removes card from beginning of hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts}, {13, :hearts}, {12, :hearts}
      ])

      player = Player.remove_card(player, {14, :hearts})

      assert player.hand == [{13, :hearts}, {12, :hearts}]
    end

    test "removes card from end of hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts}, {13, :hearts}, {12, :hearts}
      ])

      player = Player.remove_card(player, {12, :hearts})

      assert player.hand == [{14, :hearts}, {13, :hearts}]
    end
  end

  describe "has_card?/2" do
    test "returns true when player has the card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      assert Player.has_card?(player, {14, :hearts}) == true
      assert Player.has_card?(player, {13, :hearts}) == true
    end

    test "returns false when player does not have the card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      assert Player.has_card?(player, {10, :clubs}) == false
      assert Player.has_card?(player, {12, :hearts}) == false
    end

    test "returns false for empty hand" do
      player = Player.new(:north, :north_south)

      assert Player.has_card?(player, {14, :hearts}) == false
    end

    test "returns true for duplicate cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {14, :hearts}])

      assert Player.has_card?(player, {14, :hearts}) == true
    end

    test "checks all suits correctly" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {14, :diamonds},
        {14, :clubs},
        {14, :spades}
      ])

      assert Player.has_card?(player, {14, :hearts}) == true
      assert Player.has_card?(player, {14, :diamonds}) == true
      assert Player.has_card?(player, {14, :clubs}) == true
      assert Player.has_card?(player, {14, :spades}) == true
    end

    test "checks all ranks correctly" do
      player = Player.new(:north, :north_south)
      cards = for rank <- 2..14, do: {rank, :hearts}
      player = Player.add_cards(player, cards)

      for rank <- 2..14 do
        assert Player.has_card?(player, {rank, :hearts}) == true
      end
    end
  end

  describe "trump_cards/2" do
    test "returns trump cards matching trump suit" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {10, :hearts},
        {13, :clubs}
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 2
      assert {14, :hearts} in trumps
      assert {10, :hearts} in trumps
      refute {13, :clubs} in trumps
    end

    test "returns wrong 5 as trump card (Finnish Pidro rule)" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {5, :diamonds},  # Wrong 5 when hearts is trump
        {13, :clubs}
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 2
      assert {14, :hearts} in trumps
      assert {5, :diamonds} in trumps
      refute {13, :clubs} in trumps
    end

    test "returns both right 5 and wrong 5 as trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {5, :hearts},    # Right 5
        {5, :diamonds},  # Wrong 5
        {13, :clubs}
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 2
      assert {5, :hearts} in trumps
      assert {5, :diamonds} in trumps
      refute {13, :clubs} in trumps
    end

    test "returns empty list when no trump cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {13, :clubs},
        {7, :spades}
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert trumps == []
    end

    test "returns empty list for empty hand" do
      player = Player.new(:north, :north_south)

      trumps = Player.trump_cards(player, :hearts)

      assert trumps == []
    end

    test "wrong 5 rule works for all trump suits" do
      # Hearts trump -> 5 of diamonds is wrong 5
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{5, :diamonds}])
      trumps = Player.trump_cards(player, :hearts)
      assert {5, :diamonds} in trumps

      # Diamonds trump -> 5 of hearts is wrong 5
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{5, :hearts}])
      trumps = Player.trump_cards(player, :diamonds)
      assert {5, :hearts} in trumps

      # Clubs trump -> 5 of spades is wrong 5
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{5, :spades}])
      trumps = Player.trump_cards(player, :clubs)
      assert {5, :spades} in trumps

      # Spades trump -> 5 of clubs is wrong 5
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{5, :clubs}])
      trumps = Player.trump_cards(player, :spades)
      assert {5, :clubs} in trumps
    end

    test "returns all trump cards from mixed hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},   # Trump
        {13, :hearts},   # Trump
        {10, :hearts},   # Trump
        {5, :diamonds},  # Trump (wrong 5)
        {7, :clubs},     # Not trump
        {8, :spades},    # Not trump
        {12, :diamonds}  # Not trump
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 4
      assert {14, :hearts} in trumps
      assert {13, :hearts} in trumps
      assert {10, :hearts} in trumps
      assert {5, :diamonds} in trumps
    end

    test "returns all trump cards when hand is all trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {5, :diamonds}  # Wrong 5
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 6
    end

    test "5 of different color is NOT trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {5, :clubs},   # Not trump (different color)
        {5, :spades}   # Not trump (different color)
      ])

      trumps = Player.trump_cards(player, :hearts)

      assert trumps == []
    end
  end

  describe "non_trump_cards/2" do
    test "returns non-trump cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {13, :clubs},
        {7, :spades}
      ])

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert length(non_trumps) == 2
      assert {13, :clubs} in non_trumps
      assert {7, :spades} in non_trumps
      refute {14, :hearts} in non_trumps
    end

    test "excludes wrong 5 from non-trump cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {5, :diamonds},  # Wrong 5 is trump, not non-trump
        {13, :clubs}
      ])

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert length(non_trumps) == 1
      assert {13, :clubs} in non_trumps
      refute {5, :diamonds} in non_trumps
      refute {14, :hearts} in non_trumps
    end

    test "returns empty list when all cards are trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},
        {13, :hearts},
        {5, :diamonds}  # Wrong 5 is trump
      ])

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert non_trumps == []
    end

    test "returns empty list for empty hand" do
      player = Player.new(:north, :north_south)

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert non_trumps == []
    end

    test "returns all cards when no trump cards in hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {13, :clubs},
        {7, :spades},
        {10, :diamonds}
      ])

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert length(non_trumps) == 3
      assert {13, :clubs} in non_trumps
      assert {7, :spades} in non_trumps
      assert {10, :diamonds} in non_trumps
    end

    test "works correctly for all trump suits" do
      # Hearts trump
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :clubs}])
      non_trumps = Player.non_trump_cards(player, :hearts)
      assert {13, :clubs} in non_trumps
      refute {14, :hearts} in non_trumps

      # Diamonds trump
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :diamonds}, {13, :clubs}])
      non_trumps = Player.non_trump_cards(player, :diamonds)
      assert {13, :clubs} in non_trumps
      refute {14, :diamonds} in non_trumps

      # Clubs trump
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :clubs}, {13, :hearts}])
      non_trumps = Player.non_trump_cards(player, :clubs)
      assert {13, :hearts} in non_trumps
      refute {14, :clubs} in non_trumps

      # Spades trump
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :spades}, {13, :hearts}])
      non_trumps = Player.non_trump_cards(player, :spades)
      assert {13, :hearts} in non_trumps
      refute {14, :spades} in non_trumps
    end

    test "5 of different color IS non-trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {5, :clubs},   # Non-trump (different color)
        {5, :spades}   # Non-trump (different color)
      ])

      non_trumps = Player.non_trump_cards(player, :hearts)

      assert length(non_trumps) == 2
      assert {5, :clubs} in non_trumps
      assert {5, :spades} in non_trumps
    end
  end

  describe "hand_size/1" do
    test "returns 0 for empty hand" do
      player = Player.new(:north, :north_south)

      assert Player.hand_size(player) == 0
    end

    test "returns correct count for single card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}])

      assert Player.hand_size(player) == 1
    end

    test "returns correct count for multiple cards" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}, {12, :hearts}])

      assert Player.hand_size(player) == 3
    end

    test "returns correct count for initial deal (9 cards)" do
      player = Player.new(:north, :north_south)
      cards = for rank <- 2..10, do: {rank, :hearts}
      player = Player.add_cards(player, cards)

      assert Player.hand_size(player) == 9
    end

    test "returns correct count for final hand (6 cards)" do
      player = Player.new(:north, :north_south)
      cards = for rank <- 2..7, do: {rank, :hearts}
      player = Player.add_cards(player, cards)

      assert Player.hand_size(player) == 6
    end

    test "updates correctly after removing card" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      assert Player.hand_size(player) == 2

      player = Player.remove_card(player, {14, :hearts})

      assert Player.hand_size(player) == 1
    end

    test "counts duplicate cards separately" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {14, :hearts}])

      assert Player.hand_size(player) == 2
    end
  end

  describe "active?/1" do
    test "returns true for newly created player" do
      player = Player.new(:north, :north_south)

      assert Player.active?(player) == true
    end

    test "returns true when eliminated? is false" do
      player = Player.new(:north, :north_south)
      player = %{player | eliminated?: false}

      assert Player.active?(player) == true
    end

    test "returns false when player is eliminated" do
      player = Player.new(:north, :north_south)
      player = %{player | eliminated?: true}

      assert Player.active?(player) == false
    end

    test "returns false after player goes cold" do
      player = Player.new(:north, :north_south)
      player = Player.eliminate(player)

      assert Player.active?(player) == false
    end

    test "active status independent of hand size" do
      # Player can be active with empty hand (before dealing)
      player = Player.new(:north, :north_south)
      assert Player.active?(player) == true
      assert Player.hand_size(player) == 0

      # Player can be inactive with cards in hand
      player = Player.add_cards(player, [{13, :clubs}])
      player = Player.eliminate(player)
      assert Player.active?(player) == false
      assert Player.hand_size(player) == 1
    end
  end

  describe "eliminate/1" do
    test "marks player as eliminated" do
      player = Player.new(:north, :north_south)
      player = Player.eliminate(player)

      assert player.eliminated? == true
    end

    test "reveals cards when going cold" do
      player = Player.new(:north, :north_south)
      cards = [{13, :clubs}, {7, :spades}]
      player = Player.add_cards(player, cards)

      player = Player.eliminate(player)

      assert player.revealed_cards == [{13, :clubs}, {7, :spades}]
    end

    test "reveals empty list when no cards in hand" do
      player = Player.new(:north, :north_south)

      player = Player.eliminate(player)

      assert player.revealed_cards == []
    end

    test "makes player inactive" do
      player = Player.new(:north, :north_south)

      assert Player.active?(player) == true

      player = Player.eliminate(player)

      assert Player.active?(player) == false
    end

    test "preserves hand cards when eliminating" do
      player = Player.new(:north, :north_south)
      cards = [{13, :clubs}, {7, :spades}]
      player = Player.add_cards(player, cards)

      player = Player.eliminate(player)

      assert player.hand == cards
      assert player.revealed_cards == cards
    end

    test "revealed_cards is copy of hand at elimination time" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{13, :clubs}, {7, :spades}])

      player = Player.eliminate(player)
      original_revealed = player.revealed_cards

      # Removing card from hand doesn't affect revealed_cards
      player = Player.remove_card(player, {13, :clubs})

      assert player.revealed_cards == original_revealed
      assert length(player.revealed_cards) == 2
      assert length(player.hand) == 1
    end

    test "can eliminate player multiple times (idempotent)" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{13, :clubs}])

      player = Player.eliminate(player)
      assert player.eliminated? == true

      player = Player.eliminate(player)
      assert player.eliminated? == true
      assert player.revealed_cards == [{13, :clubs}]
    end

    test "preserves other player attributes" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{13, :clubs}])
      player = %{player | tricks_won: 3}

      player = Player.eliminate(player)

      assert player.position == :north
      assert player.team == :north_south
      assert player.tricks_won == 3
    end
  end

  describe "increment_tricks_won/1" do
    test "increments from 0 to 1" do
      player = Player.new(:north, :north_south)

      assert player.tricks_won == 0

      player = Player.increment_tricks_won(player)

      assert player.tricks_won == 1
    end

    test "increments multiple times" do
      player = Player.new(:north, :north_south)

      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 1

      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 2

      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 3
    end

    test "can increment up to maximum tricks per hand (6 tricks)" do
      player = Player.new(:north, :north_south)

      player =
        Enum.reduce(1..6, player, fn _, acc ->
          Player.increment_tricks_won(acc)
        end)

      assert player.tricks_won == 6
    end

    test "preserves other player attributes" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{14, :hearts}, {13, :hearts}])

      player = Player.increment_tricks_won(player)

      assert player.position == :north
      assert player.team == :north_south
      assert player.hand == [{14, :hearts}, {13, :hearts}]
      assert player.eliminated? == false
    end

    test "works for eliminated players" do
      player = Player.new(:north, :north_south)
      player = Player.eliminate(player)

      player = Player.increment_tricks_won(player)

      assert player.tricks_won == 1
      assert player.eliminated? == true
    end
  end

  describe "Finnish Pidro edge cases" do
    test "player can go cold with only non-trump cards remaining" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {13, :clubs},
        {7, :spades},
        {10, :diamonds}
      ])

      trumps = Player.trump_cards(player, :hearts)
      assert trumps == []

      # Player would go cold because they have no trump cards
      player = Player.eliminate(player)

      assert player.eliminated? == true
      assert length(player.revealed_cards) == 3
    end

    test "player with only wrong 5 is NOT out of trump" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [{5, :diamonds}])

      trumps = Player.trump_cards(player, :hearts)

      assert length(trumps) == 1
      assert {5, :diamonds} in trumps
      assert Player.active?(player) == true
    end

    test "typical game flow: 9 cards -> discard -> 6 cards -> play" do
      player = Player.new(:north, :north_south)

      # Initial deal: 9 cards
      initial_cards = [
        {14, :hearts}, {13, :hearts}, {10, :hearts},  # Trump
        {5, :diamonds},                               # Wrong 5 (trump)
        {13, :clubs}, {7, :spades},                   # Non-trump
        {10, :diamonds}, {8, :clubs}, {6, :spades}    # Non-trump
      ]
      player = Player.add_cards(player, initial_cards)
      assert Player.hand_size(player) == 9

      # Discard phase: remove non-trump cards
      non_trumps = Player.non_trump_cards(player, :hearts)
      assert length(non_trumps) == 5

      player = Enum.reduce(non_trumps, player, fn card, acc ->
        Player.remove_card(acc, card)
      end)

      assert Player.hand_size(player) == 4

      # Second deal: get 2 more trump cards to reach 6
      player = Player.add_cards(player, [{12, :hearts}, {11, :hearts}])
      assert Player.hand_size(player) == 6

      # Play: remove cards as played
      player = Player.remove_card(player, {14, :hearts})
      assert Player.hand_size(player) == 5
    end

    test "player can track multiple tricks won" do
      player = Player.new(:north, :north_south)

      # Win first trick
      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 1

      # Win second trick
      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 2

      # Win third trick
      player = Player.increment_tricks_won(player)
      assert player.tricks_won == 3
    end

    test "partnership tracking works correctly" do
      # North/South team
      north = Player.new(:north, :north_south)
      south = Player.new(:south, :north_south)

      assert north.team == south.team
      assert north.team == :north_south

      # East/West team
      east = Player.new(:east, :east_west)
      west = Player.new(:west, :east_west)

      assert east.team == west.team
      assert east.team == :east_west

      # Different teams
      refute north.team == east.team
    end
  end

  describe "trump_cards/2 and non_trump_cards/2 are complementary" do
    test "union of trump and non-trump cards equals full hand" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts},   # Trump
        {13, :hearts},   # Trump
        {5, :diamonds},  # Trump (wrong 5)
        {13, :clubs},    # Non-trump
        {7, :spades}     # Non-trump
      ])

      trumps = Player.trump_cards(player, :hearts)
      non_trumps = Player.non_trump_cards(player, :hearts)

      all_cards = trumps ++ non_trumps
      assert length(all_cards) == Player.hand_size(player)

      for card <- player.hand do
        assert card in all_cards
      end
    end

    test "no card appears in both trump and non-trump lists" do
      player = Player.new(:north, :north_south)
      player = Player.add_cards(player, [
        {14, :hearts}, {13, :hearts}, {5, :diamonds},
        {13, :clubs}, {7, :spades}, {10, :diamonds}
      ])

      trumps = Player.trump_cards(player, :hearts)
      non_trumps = Player.non_trump_cards(player, :hearts)

      for card <- trumps do
        refute card in non_trumps
      end

      for card <- non_trumps do
        refute card in trumps
      end
    end

    test "empty hand produces empty trump and non-trump lists" do
      player = Player.new(:north, :north_south)

      trumps = Player.trump_cards(player, :hearts)
      non_trumps = Player.non_trump_cards(player, :hearts)

      assert trumps == []
      assert non_trumps == []
    end
  end

  describe "Player struct is immutable" do
    test "adding cards returns new player struct" do
      original = Player.new(:north, :north_south)
      updated = Player.add_cards(original, [{14, :hearts}])

      assert original.hand == []
      assert updated.hand == [{14, :hearts}]
      refute original == updated
    end

    test "removing cards returns new player struct" do
      original = Player.new(:north, :north_south)
      original = Player.add_cards(original, [{14, :hearts}, {13, :hearts}])

      updated = Player.remove_card(original, {14, :hearts})

      assert length(original.hand) == 2
      assert length(updated.hand) == 1
      refute original == updated
    end

    test "eliminating player returns new player struct" do
      original = Player.new(:north, :north_south)
      updated = Player.eliminate(original)

      assert original.eliminated? == false
      assert updated.eliminated? == true
      refute original == updated
    end

    test "incrementing tricks returns new player struct" do
      original = Player.new(:north, :north_south)
      updated = Player.increment_tricks_won(original)

      assert original.tricks_won == 0
      assert updated.tricks_won == 1
      refute original == updated
    end
  end
end
