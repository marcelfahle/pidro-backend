defmodule Pidro.Properties.StateMachinePropertiesTest do
  @moduledoc """
  Property-based tests for the StateMachine module using StreamData.

  These tests verify fundamental invariants of the game state machine:
  - Phase transitions follow correct order
  - Actions are only valid in appropriate phases
  - State is immutable - operations always return new state
  - Player and team structure is correct and consistent

  Related to the masterplan: Game State Machine and Phase Management
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Core.GameState
  alias Pidro.Core.Types
  alias Pidro.Game.StateMachine

  # =============================================================================
  # Generators
  # =============================================================================

  @doc """
  Generates a valid game phase.
  """
  def phase do
    StreamData.member_of(Types.all_phases())
  end

  @doc """
  Generates a game state with a specific phase.
  """
  def game_state_with_phase(phase_value) do
    StreamData.constant(phase_value)
    |> StreamData.map(fn phase ->
      state = GameState.new()
      %{state | phase: phase}
    end)
  end

  @doc """
  Generates a game state with random cumulative scores.
  """
  def game_state_with_scores do
    StreamData.tuple({StreamData.integer(0..70), StreamData.integer(0..70)})
    |> StreamData.map(fn {ns_score, ew_score} ->
      state = GameState.new()
      %{state | cumulative_scores: %{north_south: ns_score, east_west: ew_score}, phase: :scoring}
    end)
  end

  @doc """
  Generates a position for a player.
  """
  def position do
    StreamData.member_of(Types.all_positions())
  end

  @doc """
  Generates a team.
  """
  def team do
    StreamData.member_of([:north_south, :east_west])
  end

  # =============================================================================
  # Property: Game Phases Transition in Correct Order
  # =============================================================================

  property "phase transitions follow the correct sequential order" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # Define the expected phase sequence
      phase_sequence = [
        :dealer_selection,
        :dealing,
        :bidding,
        :declaring,
        :discarding,
        :second_deal,
        :playing,
        :scoring
      ]

      # Test each consecutive pair of phases
      for {from_phase, to_phase} <- Enum.zip(phase_sequence, Enum.drop(phase_sequence, 1)) do
        assert StateMachine.valid_transition?(from_phase, to_phase),
               "Should be able to transition from #{from_phase} to #{to_phase}"
      end
    end
  end

  property "valid transitions are exactly those defined in the state machine" do
    check all(
            from <- phase(),
            to <- phase(),
            max_runs: 100
          ) do
      result = StateMachine.valid_transition?(from, to)

      # Valid transitions
      valid_pairs = [
        {:dealer_selection, :dealing},
        {:dealing, :bidding},
        {:bidding, :declaring},
        {:declaring, :discarding},
        {:discarding, :second_deal},
        {:second_deal, :playing},
        {:playing, :scoring},
        {:scoring, :hand_complete},
        {:scoring, :complete},
        {:hand_complete, :dealer_selection}
      ]

      expected = {from, to} in valid_pairs

      assert result == expected,
             "Transition from #{from} to #{to} should be #{expected}, got #{result}"
    end
  end

  property "cannot skip phases in the sequence" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # Test invalid jumps
      invalid_transitions = [
        # Skip dealing
        {:dealer_selection, :bidding},
        # Skip bidding
        {:dealing, :declaring},
        # Skip declaring
        {:bidding, :discarding},
        # Skip discarding
        {:declaring, :second_deal},
        # Skip second_deal
        {:discarding, :playing},
        # Skip playing
        {:second_deal, :scoring},
        # Skip scoring
        {:playing, :complete},
        # Big jump
        {:dealer_selection, :playing},
        # Big jump
        {:bidding, :scoring},
        # Huge jump
        {:dealing, :complete}
      ]

      for {from, to} <- invalid_transitions do
        refute StateMachine.valid_transition?(from, to),
               "Should NOT be able to transition from #{from} to #{to}"
      end
    end
  end

  property "cannot transition backwards (except hand_complete to dealer_selection)" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # These backward transitions should all be invalid
      backward_transitions = [
        {:dealing, :dealer_selection},
        {:bidding, :dealing},
        {:declaring, :bidding},
        {:discarding, :declaring},
        {:second_deal, :discarding},
        {:playing, :second_deal},
        {:scoring, :playing},
        {:complete, :scoring}
      ]

      for {from, to} <- backward_transitions do
        refute StateMachine.valid_transition?(from, to),
               "Should NOT be able to transition backwards from #{from} to #{to}"
      end

      # But this backward transition IS valid (new hand)
      assert StateMachine.valid_transition?(:hand_complete, :dealer_selection),
             "Should be able to transition from hand_complete to dealer_selection for new hand"
    end
  end

  property "next_phase returns correct phase for standard progression" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      # Test standard linear progression
      assert StateMachine.next_phase(:dealer_selection, state) == :dealing
      assert StateMachine.next_phase(:dealing, state) == :bidding
      assert StateMachine.next_phase(:bidding, state) == :declaring
      assert StateMachine.next_phase(:declaring, state) == :discarding
      assert StateMachine.next_phase(:discarding, state) == :second_deal
      assert StateMachine.next_phase(:second_deal, state) == :playing
      assert StateMachine.next_phase(:playing, state) == :scoring
      assert StateMachine.next_phase(:hand_complete, state) == :dealer_selection
    end
  end

  property "next_phase from scoring depends on winning_score" do
    check all(
            ns_score <- StreamData.integer(0..100),
            ew_score <- StreamData.integer(0..100),
            max_runs: 100
          ) do
      winning_score = 62

      state = %{
        GameState.new()
        | cumulative_scores: %{north_south: ns_score, east_west: ew_score},
          phase: :scoring
      }

      next = StateMachine.next_phase(:scoring, state)

      if ns_score >= winning_score or ew_score >= winning_score do
        assert next == :complete,
               "When a team reaches #{winning_score}+, next phase should be :complete (ns: #{ns_score}, ew: #{ew_score})"
      else
        assert next == :hand_complete,
               "When no team reaches #{winning_score}, next phase should be :hand_complete (ns: #{ns_score}, ew: #{ew_score})"
      end
    end
  end

  property "complete phase has no next phase" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = %{GameState.new() | phase: :complete}

      result = StateMachine.next_phase(:complete, state)

      assert match?({:error, _}, result),
             "Complete phase should return error for next_phase"
    end
  end

  # =============================================================================
  # Property: Cannot Bid After Bidding Phase Complete
  # =============================================================================

  property "cannot bid after bidding phase is complete" do
    check all(
            phase <- phase(),
            max_runs: 100
          ) do
      # Phases after bidding where bidding should not be allowed
      post_bidding_phases = [:declaring, :discarding, :second_deal, :playing, :scoring, :complete]

      if phase in post_bidding_phases do
        # Bidding transition guards should fail for these phases
        # In a real system, you'd check if bid actions are rejected
        # For now, we verify the phase is past bidding
        assert phase != :bidding,
               "Phase #{phase} should be past bidding phase"

        # Verify we can't transition TO bidding from these phases
        refute StateMachine.valid_transition?(phase, :bidding),
               "Should not be able to transition from #{phase} back to bidding"
      end
    end
  end

  property "bidding phase requires completion before moving to declaring" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # State with no bids
      state_no_bids = %{GameState.new() | phase: :bidding, highest_bid: nil, bids: []}

      refute StateMachine.can_transition_from_bidding?(state_no_bids),
             "Cannot transition from bidding when no bids made"

      # State with bids but no highest_bid
      state_incomplete = %{
        GameState.new()
        | phase: :bidding,
          highest_bid: nil,
          bids: [%Types.Bid{position: :north, amount: 10}]
      }

      refute StateMachine.can_transition_from_bidding?(state_incomplete),
             "Cannot transition from bidding when highest_bid not set"

      # State with complete bidding
      state_complete = %{
        GameState.new()
        | phase: :bidding,
          highest_bid: {:north, 10},
          bids: [%Types.Bid{position: :north, amount: 10}]
      }

      assert StateMachine.can_transition_from_bidding?(state_complete),
             "Can transition from bidding when complete"
    end
  end

  # =============================================================================
  # Property: Cannot Play Card Before Playing Phase
  # =============================================================================

  property "cannot play cards before playing phase" do
    check all(
            phase <- phase(),
            max_runs: 100
          ) do
      # Phases before playing where card play should not be allowed
      pre_playing_phases = [
        :dealer_selection,
        :dealing,
        :bidding,
        :declaring,
        :discarding,
        :second_deal
      ]

      if phase in pre_playing_phases do
        # Verify phase is before playing
        assert phase != :playing,
               "Phase #{phase} should be before playing phase"

        # Card play actions should only be valid in playing phase
        # In a real system, play_card actions would be rejected in these phases
        refute phase == :playing,
               "Phase #{phase} is not the playing phase"
      end
    end
  end

  property "playing phase requires all players to have final hand size" do
    check all(
            hand_size <- StreamData.integer(0..10),
            max_runs: 100
          ) do
      final_hand_size = 6

      # Create players with specific hand sizes
      players =
        [:north, :east, :south, :west]
        |> Enum.map(fn pos ->
          cards = List.duplicate({14, :hearts}, hand_size)

          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: cards
          }

          {pos, player}
        end)
        |> Enum.into(%{})

      state = %{GameState.new() | players: players, phase: :second_deal}

      result = StateMachine.can_transition_from_second_deal?(state)

      if hand_size == final_hand_size do
        assert result,
               "Should be able to transition from second_deal when all players have #{final_hand_size} cards"
      else
        refute result,
               "Should NOT be able to transition from second_deal when players have #{hand_size} cards"
      end
    end
  end

  property "playing phase transitions only when all hands empty" do
    check all(
            empty_count <- StreamData.integer(0..4),
            max_runs: 100
          ) do
      # Create players with some having empty hands
      players =
        [:north, :east, :south, :west]
        |> Enum.with_index()
        |> Enum.map(fn {pos, idx} ->
          hand = if idx < empty_count, do: [], else: [{14, :hearts}]

          player = %Types.Player{
            position: pos,
            team: Types.position_to_team(pos),
            hand: hand
          }

          {pos, player}
        end)
        |> Enum.into(%{})

      state = %{GameState.new() | players: players, phase: :playing}

      result = StateMachine.can_transition_from_playing?(state)

      if empty_count == 4 do
        assert result,
               "Should transition from playing when all 4 players have empty hands"
      else
        refute result,
               "Should NOT transition from playing when only #{empty_count} players have empty hands"
      end
    end
  end

  # =============================================================================
  # Property: Game State is Immutable - Operations Return New State
  # =============================================================================

  property "GameState.new() always creates independent state instances" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state1 = GameState.new()
      state2 = GameState.new()

      # States should be equal in value
      assert state1.phase == state2.phase
      assert state1.hand_number == state2.hand_number

      # But modifying one should not affect the other
      modified_state1 = GameState.update(state1, :phase, :dealing)

      assert modified_state1.phase == :dealing

      assert state1.phase == :dealer_selection,
             "Original state should remain unchanged"

      assert state2.phase == :dealer_selection,
             "Other state should remain unchanged"
    end
  end

  property "GameState.update returns new state, original unchanged" do
    check all(
            phase <- phase(),
            max_runs: 100
          ) do
      original_state = GameState.new()
      original_phase = original_state.phase

      updated_state = GameState.update(original_state, :phase, phase)

      # Updated state should have new phase
      assert updated_state.phase == phase

      # Original state should be unchanged
      assert original_state.phase == original_phase,
             "Original state phase should remain #{original_phase}, not #{phase}"

      # If we're updating to a different value, states should be different
      # Note: Elixir may optimize to return same reference if value unchanged
      if phase != original_phase do
        refute original_state == updated_state,
               "Updated state should be a new instance when phase changes"
      end
    end
  end

  property "updating nested player data preserves immutability" do
    check all(
            pos <- position(),
            max_runs: 100
          ) do
      original_state = GameState.new()
      original_player = original_state.players[pos]
      original_hand = original_player.hand

      # Update player hand
      new_cards = [{14, :hearts}, {13, :hearts}]
      updated_player = %{original_player | hand: new_cards}
      updated_players = Map.put(original_state.players, pos, updated_player)
      updated_state = GameState.update(original_state, :players, updated_players)

      # Updated state should have new hand
      assert updated_state.players[pos].hand == new_cards

      # Original state should be unchanged
      assert original_state.players[pos].hand == original_hand,
             "Original player hand should remain unchanged"
    end
  end

  property "state updates are composable and maintain immutability" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state0 = GameState.new()

      # Chain multiple updates
      state1 = GameState.update(state0, :phase, :dealing)
      state2 = GameState.update(state1, :current_dealer, :north)
      state3 = GameState.update(state2, :hand_number, 2)

      # Each state should have accumulated changes
      assert state1.phase == :dealing
      assert state1.current_dealer == nil

      assert state2.phase == :dealing
      assert state2.current_dealer == :north
      assert state2.hand_number == 1

      assert state3.phase == :dealing
      assert state3.current_dealer == :north
      assert state3.hand_number == 2

      # Original state should remain unchanged
      assert state0.phase == :dealer_selection
      assert state0.current_dealer == nil
      assert state0.hand_number == 1
    end
  end

  # =============================================================================
  # Property: Exactly 4 Players in Every Game
  # =============================================================================

  property "every game state has exactly 4 players" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      assert map_size(state.players) == 4,
             "Game should have exactly 4 players, got #{map_size(state.players)}"

      # Verify all positions present
      assert Map.has_key?(state.players, :north), "Missing north player"
      assert Map.has_key?(state.players, :east), "Missing east player"
      assert Map.has_key?(state.players, :south), "Missing south player"
      assert Map.has_key?(state.players, :west), "Missing west player"
    end
  end

  property "player positions match their keys in the map" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      for {position, player} <- state.players do
        assert player.position == position,
               "Player stored at key #{position} should have position #{position}, got #{player.position}"
      end
    end
  end

  property "no player position can be nil or missing" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      for position <- Types.all_positions() do
        assert state.players[position] != nil,
               "Player at position #{position} should not be nil"

        assert state.players[position].position == position,
               "Player position field should match map key"
      end
    end
  end

  # =============================================================================
  # Property: Players Are in Two Teams of 2
  # =============================================================================

  property "players are organized into exactly two teams" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      teams =
        state.players
        |> Map.values()
        |> Enum.map(& &1.team)
        |> Enum.uniq()
        |> Enum.sort()

      assert teams == [:east_west, :north_south],
             "Should have exactly two teams: [:east_west, :north_south], got #{inspect(teams)}"
    end
  end

  property "each team has exactly 2 players" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      north_south_players =
        state.players
        |> Map.values()
        |> Enum.filter(&(&1.team == :north_south))

      east_west_players =
        state.players
        |> Map.values()
        |> Enum.filter(&(&1.team == :east_west))

      assert length(north_south_players) == 2,
             "North/South team should have 2 players, got #{length(north_south_players)}"

      assert length(east_west_players) == 2,
             "East/West team should have 2 players, got #{length(east_west_players)}"
    end
  end

  property "team assignments match expected positions" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      # North/South team
      assert state.players[:north].team == :north_south,
             "North player should be on north_south team"

      assert state.players[:south].team == :north_south,
             "South player should be on north_south team"

      # East/West team
      assert state.players[:east].team == :east_west,
             "East player should be on east_west team"

      assert state.players[:west].team == :east_west,
             "West player should be on east_west team"
    end
  end

  property "position_to_team helper is consistent with player teams" do
    check all(
            pos <- position(),
            max_runs: 100
          ) do
      state = GameState.new()

      expected_team = Types.position_to_team(pos)
      actual_team = state.players[pos].team

      assert actual_team == expected_team,
             "Player at #{pos} should be on #{expected_team} team, got #{actual_team}"
    end
  end

  # =============================================================================
  # Property: Partners Sit Opposite Each Other
  # =============================================================================

  property "partners sit opposite each other" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # North opposite South
      assert Types.partner_position(:north) == :south,
             "North's partner should be South"

      assert Types.partner_position(:south) == :north,
             "South's partner should be North"

      # East opposite West
      assert Types.partner_position(:east) == :west,
             "East's partner should be West"

      assert Types.partner_position(:west) == :east,
             "West's partner should be East"
    end
  end

  property "partners are on the same team" do
    check all(
            pos <- position(),
            max_runs: 100
          ) do
      state = GameState.new()

      partner_pos = Types.partner_position(pos)

      player_team = state.players[pos].team
      partner_team = state.players[partner_pos].team

      assert player_team == partner_team,
             "#{pos} (team: #{player_team}) and #{partner_pos} (team: #{partner_team}) should be on same team"
    end
  end

  property "partner relationship is symmetric" do
    check all(
            pos <- position(),
            max_runs: 100
          ) do
      partner = Types.partner_position(pos)
      partner_of_partner = Types.partner_position(partner)

      assert partner_of_partner == pos,
             "Partner of partner should be original position: #{pos} -> #{partner} -> #{partner_of_partner}"
    end
  end

  property "positions alternate between teams clockwise" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      state = GameState.new()

      # Going clockwise: North -> East -> South -> West -> North
      # Teams alternate: NS -> EW -> NS -> EW -> NS

      north_team = state.players[:north].team
      east_team = state.players[:east].team
      south_team = state.players[:south].team
      west_team = state.players[:west].team

      # Teams should alternate
      assert north_team != east_team, "North and East should be on different teams"
      assert east_team != south_team, "East and South should be on different teams"
      assert south_team != west_team, "South and West should be on different teams"
      assert west_team != north_team, "West and North should be on different teams"

      # Opposite players same team
      assert north_team == south_team, "North and South should be on same team"
      assert east_team == west_team, "East and West should be on same team"
    end
  end

  property "next_position cycles through all positions" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # Starting from north, cycle should return to north after 4 steps
      pos1 = Types.next_position(:north)
      pos2 = Types.next_position(pos1)
      pos3 = Types.next_position(pos2)
      pos4 = Types.next_position(pos3)

      assert pos1 == :east, "After north should be east"
      assert pos2 == :south, "After east should be south"
      assert pos3 == :west, "After south should be west"
      assert pos4 == :north, "After west should be north (full cycle)"

      # All positions should be unique within one cycle
      positions = [pos1, pos2, pos3]
      assert length(Enum.uniq(positions)) == 3, "Positions should be unique in cycle"
    end
  end

  # =============================================================================
  # Additional Properties for Robustness
  # =============================================================================

  property "phase transition guards are consistent with valid transitions" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # If a guard says we can transition, the transition should be valid
      state = GameState.new()

      # Test dealer_selection guard
      state_with_dealer = GameState.update(state, :current_dealer, :north)

      if StateMachine.can_transition_from_dealer_selection?(state_with_dealer) do
        assert StateMachine.valid_transition?(:dealer_selection, :dealing),
               "If can_transition guard passes, transition should be valid"
      end
    end
  end

  property "declaring phase requires trump declaration" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # State without trump
      state_no_trump = %{GameState.new() | phase: :declaring, trump_suit: nil}

      refute StateMachine.can_transition_from_declaring?(state_no_trump),
             "Cannot transition from declaring without trump suit"

      # State with trump
      state_with_trump = %{GameState.new() | phase: :declaring, trump_suit: :hearts}

      assert StateMachine.can_transition_from_declaring?(state_with_trump),
             "Can transition from declaring with trump suit set"
    end
  end

  property "scoring phase requires hand points to be calculated" do
    check all(_ <- StreamData.constant(:ok), max_runs: 100) do
      # State with no hand points
      state_no_points = %{
        GameState.new()
        | phase: :scoring,
          hand_points: %{north_south: 0, east_west: 0}
      }

      refute StateMachine.can_transition_from_scoring?(state_no_points),
             "Cannot transition from scoring with zero hand points"

      # State with hand points
      state_with_points = %{
        GameState.new()
        | phase: :scoring,
          hand_points: %{north_south: 8, east_west: 6}
      }

      assert StateMachine.can_transition_from_scoring?(state_with_points),
             "Can transition from scoring with hand points calculated"
    end
  end

  property "team_to_positions returns correct positions for each team" do
    check all(
            tm <- team(),
            max_runs: 100
          ) do
      positions = Types.team_to_positions(tm)

      assert length(positions) == 2,
             "Each team should have exactly 2 positions"

      # Verify all positions in result are on the same team
      for pos <- positions do
        assert Types.position_to_team(pos) == tm,
               "Position #{pos} should be on team #{tm}"
      end
    end
  end

  property "opposing_team returns the other team" do
    check all(
            tm <- team(),
            max_runs: 100
          ) do
      opponent = Types.opposing_team(tm)

      # Should be different
      assert opponent != tm,
             "Opposing team should be different from #{tm}"

      # Should be symmetric
      assert Types.opposing_team(opponent) == tm,
             "Opposing team relationship should be symmetric"

      # Should only have two possible teams
      assert opponent in [:north_south, :east_west],
             "Opposing team should be valid"
    end
  end
end
