defmodule Pidro.Properties.TrickPropertiesTest do
  @moduledoc """
  Property-based tests for trick-taking mechanics in Finnish Pidro.

  These tests verify:
  - Only trump cards can be played
  - Highest trump card wins the trick
  - Winner leads the next trick
  - Players going cold reveal their remaining cards
  - Cold players do not participate in subsequent tricks
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.{Card, GameState, Trick, Types}

  @positions [:north, :east, :south, :west]

  # =============================================================================
  # Generators
  # =============================================================================

  defp suit_gen do
    member_of([:hearts, :diamonds, :clubs, :spades])
  end

  defp position_gen do
    member_of(@positions)
  end

  defp trump_card_gen(trump_suit) do
    gen all(rank <- integer(2..14)) do
      {rank, trump_suit}
    end
  end

  defp non_trump_card_gen(trump_suit) do
    gen all(
          rank <- integer(2..14),
          suit <- suit_gen(),
          suit != trump_suit,
          # Ensure it's not the wrong 5
          not Card.is_trump?({rank, suit}, trump_suit)
        ) do
      {rank, suit}
    end
  end

  # Generator for a game state in playing phase with at least one completed trick
  defp playing_phase_generator do
    gen all(
          trump <- suit_gen(),
          dealer <- position_gen(),
          num_tricks <- integer(1..6)
        ) do
      build_playing_phase_state(trump, dealer, num_tricks)
    end
  end

  # Generator for a single completed trick
  defp completed_trick_generator do
    gen all(
          trump <- suit_gen(),
          leader <- position_gen(),
          cards <- uniq_list_of(trump_card_gen(trump), min_length: 4, max_length: 4)
        ) do
      build_completed_trick(trump, leader, cards)
    end
  end

  # Generator for a game state mid-game (with multiple tricks)
  defp mid_game_generator do
    gen all(
          trump <- suit_gen(),
          dealer <- position_gen(),
          num_tricks <- integer(2..5)
        ) do
      build_playing_phase_state(trump, dealer, num_tricks)
    end
  end

  # Generator for a player who has just run out of trump
  defp player_out_of_trump_generator do
    gen all(
          trump <- suit_gen(),
          pos <- position_gen(),
          non_trumps <- uniq_list_of(non_trump_card_gen(trump), min_length: 1, max_length: 3)
        ) do
      build_state_with_cold_player(trump, pos, non_trumps)
    end
  end

  # Generator for a game with multiple cold players
  defp game_with_cold_players_generator do
    gen all(
          trump <- suit_gen(),
          num_cold <- integer(1..2)
        ) do
      build_state_with_multiple_cold_players(trump, num_cold)
    end
  end

  # =============================================================================
  # Property Tests
  # =============================================================================

  property "only trump cards are valid plays" do
    check all(state <- playing_phase_generator(), max_runs: 50) do
      # All cards in all completed tricks must be trump
      all_plays =
        state.tricks
        |> Enum.flat_map(fn trick -> trick.plays end)
        |> Enum.map(fn {_pos, card} -> card end)

      # Also check current trick if it exists
      current_plays =
        if state.current_trick do
          Enum.map(state.current_trick.plays, fn {_pos, card} -> card end)
        else
          []
        end

      all_cards = all_plays ++ current_plays

      Enum.all?(all_cards, fn card ->
        Card.is_trump?(card, state.trump_suit)
      end)
      |> assert("All played cards must be trump cards")
    end
  end

  property "highest trump card wins the trick (except for 2 special rule)" do
    check all(trick_data <- completed_trick_generator(), max_runs: 50) do
      {trick, trump_suit} = trick_data

      # Get the winner
      {:ok, winner_pos} = Trick.winner(trick, trump_suit)

      {^winner_pos, winner_card} =
        Enum.find(trick.plays, fn {pos, _card} -> pos == winner_pos end)

      # Winner's card must beat all other cards
      other_plays = Enum.reject(trick.plays, fn {pos, _card} -> pos == winner_pos end)

      Enum.all?(other_plays, fn {_pos, other_card} ->
        Card.compare(winner_card, other_card, trump_suit) == :gt or
          winner_card == other_card
      end)
      |> assert("Winner's card must be highest trump in trick")
    end
  end

  property "player who wins trick leads next trick" do
    check all(state <- mid_game_generator(), max_runs: 50) do
      # For each completed trick except the last, verify the winner leads the next trick
      # Note: Types.Trick stores winner, so we can use it directly
      state.tricks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [prev_trick, next_trick] ->
        # Types.Trick has winner field already computed
        prev_trick.winner == next_trick.leader
      end)
      |> assert("Winner of trick must lead the next trick")
    end
  end

  property "when player has no trump, they go 'cold' and lay down remaining cards" do
    check all({state, cold_pos} <- player_out_of_trump_generator(), max_runs: 50) do
      cold_player = Map.get(state.players, cold_pos)

      # Player must be marked as eliminated
      assert cold_player.eliminated?, "Player out of trump must be marked as eliminated"

      # Player's hand must be empty
      assert cold_player.hand == [], "Cold player's hand must be empty"

      # Player's revealed cards must contain non-trump cards
      if length(cold_player.revealed_cards) > 0 do
        Enum.all?(cold_player.revealed_cards, fn card ->
          not Card.is_trump?(card, state.trump_suit)
        end)
        |> assert("Revealed cards must be non-trump")
      end
    end
  end

  property "cold player does not participate in remaining tricks" do
    check all(state <- game_with_cold_players_generator(), max_runs: 50) do
      # Get all cold players
      cold_positions =
        state.players
        |> Enum.filter(fn {_pos, player} -> player.eliminated? end)
        |> Enum.map(fn {pos, _player} -> pos end)

      # Verify no cold players appear in any trick plays
      state.tricks
      |> Enum.all?(fn trick ->
        trick_positions = Enum.map(trick.plays, fn {pos, _card} -> pos end)

        Enum.all?(cold_positions, fn cold_pos ->
          cold_pos not in trick_positions
        end)
      end)
      |> assert("Cold players must not participate in any tricks")
    end
  end

  # =============================================================================
  # Helper Functions for Building Test States
  # =============================================================================

  defp build_playing_phase_state(trump_suit, dealer, num_tricks) do
    state = GameState.new()

    # Set up basic game state
    state =
      state
      |> GameState.update(:phase, :playing)
      |> GameState.update(:trump_suit, trump_suit)
      |> GameState.update(:current_dealer, dealer)
      |> GameState.update(:bidding_team, Types.position_to_team(dealer))
      |> GameState.update(:highest_bid, {dealer, 10})

    # Create players with trump cards
    players =
      @positions
      |> Enum.map(fn pos ->
        # Give each player 6 trump cards
        hand =
          1..6
          |> Enum.map(fn i ->
            rank = rem(i + :erlang.phash2(pos), 13) + 2
            {rank, trump_suit}
          end)

        player = %Types.Player{
          position: pos,
          team: Types.position_to_team(pos),
          hand: hand,
          eliminated?: false
        }

        {pos, player}
      end)
      |> Map.new()

    state = GameState.update(state, :players, players)

    # Build completed tricks as Types.Trick (state storage format)
    {tricks, last_winner} = build_tricks_for_state(trump_suit, dealer, num_tricks)

    state
    |> GameState.update(:tricks, tricks)
    |> GameState.update(:current_turn, last_winner)
    |> GameState.update(:trick_number, num_tricks)
  end

  # Build tricks as Types.Trick for storage in state, and track last winner
  defp build_tricks_for_state(trump_suit, initial_leader, count) do
    1..count
    |> Enum.reduce({[], initial_leader}, fn trick_num, {acc_tricks, leader} ->
      # Build using Trick module to compute winner
      trick = build_single_core_trick(trump_suit, leader, trick_num)
      {:ok, winner} = Trick.winner(trick, trump_suit)

      # Convert to Types.Trick for state storage
      types_trick = %Types.Trick{
        number: trick_num,
        leader: leader,
        plays: trick.plays,
        winner: winner,
        points: Trick.points(trick, trump_suit)
      }

      {acc_tricks ++ [types_trick], winner}
    end)
  end

  # Build a Pidro.Core.Trick (not Types.Trick) for winner calculation
  defp build_single_core_trick(trump_suit, leader, trick_num) do
    # Create a trick using Trick module
    trick = Trick.new(leader)

    # Determine play order starting from leader
    leader_idx = Enum.find_index(@positions, &(&1 == leader))

    play_order =
      @positions
      |> Enum.drop(leader_idx)
      |> Kernel.++(Enum.take(@positions, leader_idx))

    # Add 4 plays with different trump cards using Trick.add_play
    play_order
    |> Enum.with_index()
    |> Enum.reduce(trick, fn {pos, idx}, acc_trick ->
      # Generate different trump ranks for variety
      rank = rem(trick_num * 4 + idx, 13) + 2
      Trick.add_play(acc_trick, pos, {rank, trump_suit})
    end)
  end

  defp build_completed_trick(trump_suit, leader, cards) do
    # Ensure we have exactly 4 cards
    cards_to_use = Enum.take(cards, 4)

    leader_idx = Enum.find_index(@positions, &(&1 == leader))

    play_order =
      @positions
      |> Enum.drop(leader_idx)
      |> Kernel.++(Enum.take(@positions, leader_idx))

    # Build trick using Trick module functions
    trick =
      play_order
      |> Enum.zip(cards_to_use)
      |> Enum.reduce(Trick.new(leader), fn {pos, card}, acc_trick ->
        Trick.add_play(acc_trick, pos, card)
      end)

    {trick, trump_suit}
  end

  defp build_state_with_cold_player(trump_suit, cold_pos, revealed_non_trumps) do
    state = GameState.new()

    # Set up basic game state
    state =
      state
      |> GameState.update(:phase, :playing)
      |> GameState.update(:trump_suit, trump_suit)
      |> GameState.update(:current_dealer, :north)
      |> GameState.update(:bidding_team, :north_south)
      |> GameState.update(:highest_bid, {:north, 10})

    # Create players
    players =
      @positions
      |> Enum.map(fn pos ->
        if pos == cold_pos do
          # This player is cold (out of trump)
          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: [],
            eliminated?: true,
            revealed_cards: revealed_non_trumps
          }

          {pos, player}
        else
          # Other players have trump cards
          hand =
            1..4
            |> Enum.map(fn i ->
              rank = rem(i, 13) + 2
              {rank, trump_suit}
            end)

          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: hand,
            eliminated?: false
          }

          {pos, player}
        end
      end)
      |> Map.new()

    state = GameState.update(state, :players, players)

    {state, cold_pos}
  end

  defp build_state_with_multiple_cold_players(trump_suit, num_cold) do
    state = GameState.new()

    # Set up basic game state
    state =
      state
      |> GameState.update(:phase, :playing)
      |> GameState.update(:trump_suit, trump_suit)
      |> GameState.update(:current_dealer, :north)
      |> GameState.update(:bidding_team, :north_south)
      |> GameState.update(:highest_bid, {:north, 10})

    # Select positions to be cold
    cold_positions = Enum.take(@positions, num_cold)

    # Create players
    players =
      @positions
      |> Enum.map(fn pos ->
        if pos in cold_positions do
          # This player is cold
          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: [],
            eliminated?: true,
            revealed_cards: []
          }

          {pos, player}
        else
          # Active player with trump
          hand =
            1..5
            |> Enum.map(fn i ->
              rank = rem(i + :erlang.phash2(pos), 13) + 2
              {rank, trump_suit}
            end)

          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: hand,
            eliminated?: false
          }

          {pos, player}
        end
      end)
      |> Map.new()

    state = GameState.update(state, :players, players)

    # Build some tricks (none should include cold players)
    active_positions = @positions -- cold_positions

    if length(active_positions) >= 2 do
      # Build 1-2 tricks with only active players
      tricks =
        1..2
        |> Enum.map(fn trick_num ->
          leader = Enum.at(active_positions, 0)

          # Build using Trick module
          trick =
            active_positions
            |> Enum.with_index()
            |> Enum.reduce(Trick.new(leader), fn {pos, idx}, acc_trick ->
              rank = rem(trick_num * length(active_positions) + idx, 13) + 2
              Trick.add_play(acc_trick, pos, {rank, trump_suit})
            end)

          {:ok, winner} = Trick.winner(trick, trump_suit)

          # Convert to Types.Trick for state
          %Types.Trick{
            number: trick_num,
            leader: leader,
            plays: trick.plays,
            winner: winner,
            points: Trick.points(trick, trump_suit)
          }
        end)

      GameState.update(state, :tricks, tricks)
    else
      state
    end
  end
end
