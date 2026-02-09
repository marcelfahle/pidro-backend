defmodule Pidro.Game.Play do
  @moduledoc """
  Card playing and trick management for the Finnish Pidro variant.

  This module handles all aspects of the playing phase, including:
  - Playing cards from a player's hand
  - Validating card plays (must be trump in Finnish variant)
  - Completing tricks and determining winners
  - Eliminating players who go "cold" (run out of trumps)
  - Revealing non-trump cards when a player goes cold
  - Managing trick leadership and turn rotation

  ## Finnish Pidro Playing Rules

  ### Card Playing
  - Only trump cards can be played (non-trumps are "camouflage")
  - Players must play a trump card if they have one
  - The highest trump card wins the trick
  - The trick winner leads the next trick

  ### Going "Cold"
  - When a player runs out of trump cards, they go "cold" (eliminated)
  - Their remaining non-trump cards are revealed to all players
  - They no longer participate in the remaining tricks
  - Their team can still win points through their partner

  ### Trick Completion
  - A trick is complete when all non-eliminated players have played
  - Points are awarded to the winning team based on card values
  - The trick winner leads the next trick

  ## Examples

      # Play a card from a player's hand
      iex> state = %GameState{phase: :playing, trump_suit: :hearts, current_turn: :north}
      iex> {:ok, state} = Play.play_card(state, :north, {14, :hearts})
      iex> length(state.current_trick.plays)
      1

      # Complete a trick
      iex> trick = %Trick{plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}], ...}
      iex> {:ok, winner, points} = Play.complete_trick(trick)
      iex> winner
      :north
      iex> points
      2

      # Eliminate a player who runs out of trumps
      iex> state = %GameState{trump_suit: :hearts}
      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> {:ok, state} = Play.eliminate_player(state, :north)
      iex> state.players[:north].eliminated?
      true
  """

  alias Pidro.Core.{Types, Card, GameState}
  alias Pidro.Core.Types.{Player, Trick}
  alias Pidro.Game.{Errors, Trump}

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type card :: Types.card()
  @type suit :: Types.suit()
  @type error :: Errors.error()

  # =============================================================================
  # Kill Rule (Redeal)
  # =============================================================================

  @doc """
  Compute killed cards for all players entering playing phase.

  Players with >6 trump must kill down to 6 using non-point cards.
  If a player has 7+ point cards, they cannot kill and keep all their cards.

  ## Parameters
  - `state` - Current game state with players' hands set

  ## Returns
  Updated game state with killed cards removed from hands and stored in state.killed_cards

  ## State Changes
  - Updates `killed_cards` map with {position => [cards]} entries
  - Removes killed cards from players' hands
  - Records `{:cards_killed, killed_map}` event

  ## Examples

      iex> player = %Player{hand: [{7, :h}, {6, :h}, {4, :h}, {3, :h}, {2, :h}, {14, :h}, {11, :h}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> state = Play.compute_kills(state)
      iex> length(state.players[:north].hand)
      6
  """
  @spec compute_kills(game_state()) :: game_state()
  def compute_kills(%Types.GameState{players: players, trump_suit: trump} = state) do
    killed_cards =
      players
      |> Enum.reduce(%{}, fn {pos, player}, acc ->
        hand_size = length(player.hand)

        if hand_size > 6 do
          # Must kill excess cards
          excess = hand_size - 6
          non_point = Card.non_point_trumps(player.hand, trump)

          if length(non_point) >= excess do
            # Kill oldest non-point cards (arbitrary choice)
            to_kill = Enum.take(non_point, excess)
            Map.put(acc, pos, to_kill)
          else
            # Cannot kill (7+ point cards) - keep all cards
            Map.put(acc, pos, [])
          end
        else
          acc
        end
      end)

    # Remove killed cards from hands and store in state
    new_players =
      players
      |> Enum.map(fn {pos, player} ->
        kills = Map.get(killed_cards, pos, [])
        new_hand = player.hand -- kills
        {pos, %{player | hand: new_hand}}
      end)
      |> Map.new()

    # After killing excess cards, eliminate players with no trump cards.
    # This can happen when a player receives only non-trump cards during
    # the second deal (the deck contains both trump and non-trump cards).
    final_players =
      new_players
      |> Enum.map(fn {pos, player} ->
        if not player.eliminated? and length(player.hand) > 0 do
          trump_cards = Trump.get_trump_cards(player.hand, trump)

          if trump_cards == [] do
            # No trump at all — go cold, reveal hand
            {pos, %{player | eliminated?: true, revealed_cards: player.hand, hand: []}}
          else
            {pos, player}
          end
        else
          {pos, player}
        end
      end)
      |> Map.new()

    # Update state with killed cards and new hands
    state
    |> GameState.update(:killed_cards, killed_cards)
    |> GameState.update(:players, final_players)
    |> record_cards_killed_event(killed_cards)
  end

  # =============================================================================
  # Card Playing
  # =============================================================================

  @doc """
  Plays a card from a player's hand during the playing phase.

  This function validates that the card play is legal, removes the card from
  the player's hand, adds it to the current trick, and updates the turn order.
  If the trick is complete after this play, it automatically completes the trick.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player playing the card
  - `card` - The card to play

  ## Returns
  - `{:ok, state}` - Updated state with card played
  - `{:error, reason}` - If the play is invalid

  ## State Changes
  - Removes card from player's hand
  - Adds play to current trick
  - Advances turn to next player (or trick leader if trick complete)
  - Records `{:card_played, position, card}` event
  - If player has no more trumps after playing, marks them as eliminated
  - If trick is complete, determines winner and awards points

  ## Validation
  - Game must be in `:playing` phase
  - Trump suit must be declared
  - Card must be in player's hand
  - Card must be a trump card (Finnish variant rule)
  - Must be player's turn

  ## Examples

      iex> state = %GameState{phase: :playing, trump_suit: :hearts, current_turn: :north}
      iex> player = %Player{hand: [{14, :hearts}, {10, :hearts}]}
      iex> state = put_in(state.players[:north], player)
      iex> {:ok, state} = Play.play_card(state, :north, {14, :hearts})
      iex> length(state.players[:north].hand)
      1
      iex> length(state.current_trick.plays)
      1
  """
  @spec play_card(game_state(), position(), card()) :: {:ok, game_state()} | {:error, error()}
  def play_card(%Types.GameState{} = state, position, card) do
    with :ok <- validate_playing_phase(state),
         :ok <- validate_trump_declared(state),
         {:ok, card} <- Errors.validate_card(card),
         :ok <- validate_play(state, position, card),
         {:ok, state} <- remove_card_from_hand(state, position, card),
         {:ok, state} <- add_card_to_trick(state, position, card),
         {:ok, state} <- record_card_played_event(state, position, card),
         {:ok, state} <- check_player_elimination(state, position),
         {:ok, state} <- advance_turn_or_complete_trick(state) do
      {:ok, state}
    end
  end

  # =============================================================================
  # Play Validation
  # =============================================================================

  @doc """
  Validates that a card play is legal.

  In the Finnish variant, players must play trump cards. This function ensures:
  - The card is in the player's hand
  - The card is a trump card
  - The player has no trumps, they are eliminated and cannot play

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player
  - `card` - The card to validate

  ## Returns
  - `:ok` - If the play is valid
  - `{:error, reason}` - If the play is invalid

  ## Examples

      iex> state = %GameState{trump_suit: :hearts}
      iex> player = %Player{hand: [{14, :hearts}, {10, :clubs}]}
      iex> Play.validate_play(state, :north, {14, :hearts})
      :ok

      iex> Play.validate_play(state, :north, {10, :clubs})
      {:error, {:cannot_play_non_trump, {10, :clubs}, :hearts}}
  """
  @spec validate_play(game_state(), position(), card()) :: :ok | {:error, error()}
  def validate_play(%Types.GameState{} = state, position, card) do
    player = state.players[position]
    trump_suit = state.trump_suit

    with :ok <- validate_card_in_hand(player, card),
         :ok <- validate_trump_card(card, trump_suit) do
      :ok
    end
  end

  # Validates card is in player's hand
  @spec validate_card_in_hand(Player.t(), card()) :: :ok | {:error, error()}
  defp validate_card_in_hand(%Player{hand: hand}, card) do
    if card in hand do
      :ok
    else
      {:error, {:card_not_in_hand, card}}
    end
  end

  # Validates card is a trump card
  @spec validate_trump_card(card(), suit()) :: :ok | {:error, error()}
  defp validate_trump_card(card, trump_suit) do
    if Card.is_trump?(card, trump_suit) do
      :ok
    else
      {:error, {:cannot_play_non_trump, card, trump_suit}}
    end
  end

  # =============================================================================
  # Trick Completion
  # =============================================================================

  @doc """
  Completes the current trick, determines the winner, and awards points.

  This function analyzes all plays in the current trick, determines which
  card (and therefore which player) won the trick, calculates the point value
  of the trick, and updates the game state accordingly.

  ## Parameters
  - `state` - Current game state with a complete trick

  ## Returns
  - `{:ok, state}` - Updated state with trick completed
  - `{:error, reason}` - If trick cannot be completed

  ## State Changes
  - Moves current_trick to tricks history
  - Sets current_trick to nil
  - Awards points to winning team
  - Increments tricks_won for winning player
  - Records `{:trick_won, position, points}` event
  - Sets current_turn to trick winner (for next trick)
  - Creates new trick if more cards remain to be played

  ## Trick Winner Determination
  - The highest trump card wins
  - Trump ranking: A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
  - First card played wins ties (shouldn't happen with unique cards)

  ## Examples

      iex> trick = %Trick{
      ...>   plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}],
      ...>   leader: :north
      ...> }
      iex> state = %GameState{current_trick: trick, trump_suit: :hearts}
      iex> {:ok, state} = Play.complete_trick(state)
      iex> state.current_trick
      nil
      iex> length(state.tricks)
      1
  """
  @spec complete_trick(game_state()) :: {:ok, game_state()} | {:error, error()}
  def complete_trick(%Types.GameState{current_trick: nil} = _state) do
    {:error, :no_current_trick}
  end

  def complete_trick(%Types.GameState{current_trick: trick, trump_suit: trump_suit} = state) do
    with {:ok, winner, points} <- determine_trick_winner(trick, trump_suit),
         {:ok, state} <- award_trick_points(state, winner, points),
         {:ok, state} <- record_trick_won_event(state, winner, points),
         {:ok, state} <- move_trick_to_history(state),
         {:ok, state} <- set_next_trick_leader(state, winner),
         {:ok, state} <- maybe_start_next_trick(state) do
      {:ok, state}
    end
  end

  @doc """
  Determines the winner of a completed trick and calculates points.

  Analyzes all plays in the trick to find the highest trump card.
  Calculates total point value from all cards in the trick.

  ## Parameters
  - `trick` - The completed trick
  - `trump_suit` - The declared trump suit

  ## Returns
  - `{:ok, winner_position, points}` - Winner and point value
  - `{:error, reason}` - If winner cannot be determined

  ## Examples

      iex> trick = %Trick{plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}]}
      iex> Play.determine_trick_winner(trick, :hearts)
      {:ok, :north, 2}
  """
  @spec determine_trick_winner(Trick.t(), suit()) ::
          {:ok, position(), non_neg_integer()} | {:error, error()}
  def determine_trick_winner(%Trick{plays: []}, _trump_suit) do
    {:error, :trick_has_no_plays}
  end

  def determine_trick_winner(%Trick{plays: plays}, trump_suit) do
    # Find the highest card and its player
    {winner_position, _winning_card} =
      plays
      |> Enum.max_by(fn {_pos, card} -> card_sort_value(card, trump_suit) end)

    # Calculate total points in the trick
    points =
      plays
      |> Enum.map(fn {_pos, card} -> Card.point_value(card, trump_suit) end)
      |> Enum.sum()

    {:ok, winner_position, points}
  end

  # Helper to get a sortable value for a card (for finding highest trump)
  # Uses trump_ranking logic from Card module
  @spec card_sort_value(card(), suit()) :: float()
  defp card_sort_value({rank, card_suit}, trump_suit) do
    cond do
      # Not a trump card: very low value
      not Card.is_trump?({rank, card_suit}, trump_suit) ->
        -1000.0

      # Ace of trump: highest rank
      rank == 14 and card_suit == trump_suit ->
        14.0

      # King, Queen, Jack, 10, 9, 8, 7, 6 of trump: standard ranks
      rank in [13, 12, 11, 10, 9, 8, 7, 6] and card_suit == trump_suit ->
        rank * 1.0

      # Right 5 (5 of trump suit): ranks between 6 and 4
      rank == 5 and card_suit == trump_suit ->
        5.0

      # Wrong 5 (5 of same-color suit): ranks just below Right 5
      rank == 5 and card_suit == Card.same_color_suit(trump_suit) ->
        4.5

      # 4 of trump: ranks below Wrong 5
      rank == 4 and card_suit == trump_suit ->
        4.0

      # 3 of trump
      rank == 3 and card_suit == trump_suit ->
        3.0

      # 2 of trump: lowest rank
      rank == 2 and card_suit == trump_suit ->
        2.0

      # Default case
      true ->
        0.0
    end
  end

  # =============================================================================
  # Player Elimination
  # =============================================================================

  @doc """
  Marks a player as eliminated ("going cold") when they run out of trump cards.

  In Finnish Pidro, when a player has no more trump cards, they are eliminated
  from the rest of the hand. Their remaining non-trump cards are revealed to
  all players, and they cannot play in subsequent tricks.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player to eliminate

  ## Returns
  - `{:ok, state}` - Updated state with player eliminated
  - `{:error, reason}` - If elimination fails

  ## State Changes
  - Sets player's `eliminated?` to `true`
  - Moves non-trump cards from hand to `revealed_cards`
  - Clears player's hand
  - Records `{:player_went_cold, position, revealed_cards}` event

  ## Examples

      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> {:ok, state} = Play.eliminate_player(state, :north)
      iex> state.players[:north].eliminated?
      true
      iex> state.players[:north].revealed_cards
      [{10, :clubs}, {7, :spades}]
  """
  @spec eliminate_player(game_state(), position()) :: {:ok, game_state()} | {:error, error()}
  def eliminate_player(%Types.GameState{} = state, position) do
    player = state.players[position]
    trump_suit = state.trump_suit

    # Get non-trump cards to reveal
    non_trump_cards = Trump.get_non_trump_cards(player.hand, trump_suit)

    # Update player state
    updated_player = %{
      player
      | eliminated?: true,
        revealed_cards: non_trump_cards,
        hand: []
    }

    # Update state
    updated_players = Map.put(state.players, position, updated_player)
    updated_state = GameState.update(state, :players, updated_players)

    # Record event
    event = {:player_went_cold, position, non_trump_cards}
    updated_events = state.events ++ [event]
    final_state = GameState.update(updated_state, :events, updated_events)

    {:ok, final_state}
  end

  @doc """
  Reveals a player's non-trump cards when they go cold.

  This is called as part of the elimination process. In Finnish Pidro,
  when a player runs out of trumps, their remaining non-trump "camouflage"
  cards are revealed to all other players.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player

  ## Returns
  - `{:ok, revealed_cards}` - List of non-trump cards that were revealed

  ## Examples

      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> Play.reveal_non_trumps(state, :north)
      {:ok, [{10, :clubs}, {7, :spades}]}
  """
  @spec reveal_non_trumps(game_state(), position()) :: {:ok, [card()]}
  def reveal_non_trumps(%Types.GameState{} = state, position) do
    player = state.players[position]
    trump_suit = state.trump_suit

    non_trump_cards = Trump.get_non_trump_cards(player.hand, trump_suit)
    {:ok, non_trump_cards}
  end

  # =============================================================================
  # Turn Management
  # =============================================================================

  @doc """
  Handles trick leadership and turn rotation.

  After a trick is complete, the winner becomes the leader of the next trick.
  During a trick, turns rotate clockwise through non-eliminated players.

  ## Parameters
  - `state` - Current game state
  - `next_leader` - Position of the next trick leader

  ## Returns
  - `{:ok, state}` - Updated state with new leader

  ## Examples

      iex> state = %GameState{current_turn: :north}
      iex> {:ok, state} = Play.set_trick_leader(state, :east)
      iex> state.current_turn
      :east
  """
  @spec set_trick_leader(game_state(), position()) :: {:ok, game_state()}
  def set_trick_leader(%Types.GameState{} = state, leader) do
    updated_state = GameState.update(state, :current_turn, leader)
    {:ok, updated_state}
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Validates game is in playing phase
  @spec validate_playing_phase(game_state()) :: :ok | {:error, error()}
  defp validate_playing_phase(%Types.GameState{phase: :playing}), do: :ok

  defp validate_playing_phase(%Types.GameState{phase: actual_phase}) do
    {:error, {:invalid_phase, :playing, actual_phase}}
  end

  # Validates trump suit is declared
  @spec validate_trump_declared(game_state()) :: :ok | {:error, error()}
  defp validate_trump_declared(%Types.GameState{trump_suit: nil}) do
    {:error, {:trump_not_declared, "Trump suit must be declared before playing cards"}}
  end

  defp validate_trump_declared(%Types.GameState{trump_suit: _suit}), do: :ok

  # Removes card from player's hand
  @spec remove_card_from_hand(game_state(), position(), card()) ::
          {:ok, game_state()} | {:error, error()}
  defp remove_card_from_hand(state, position, card) do
    player = state.players[position]
    updated_hand = List.delete(player.hand, card)
    updated_player = %{player | hand: updated_hand}
    updated_players = Map.put(state.players, position, updated_player)
    updated_state = GameState.update(state, :players, updated_players)
    {:ok, updated_state}
  end

  # Adds card to current trick
  @spec add_card_to_trick(game_state(), position(), card()) :: {:ok, game_state()}
  defp add_card_to_trick(state, position, card) do
    trick = state.current_trick || create_new_trick(state)
    updated_plays = trick.plays ++ [{position, card}]
    updated_trick = %{trick | plays: updated_plays}
    updated_state = GameState.update(state, :current_trick, updated_trick)
    {:ok, updated_state}
  end

  # Creates a new trick
  @spec create_new_trick(game_state()) :: Trick.t()
  defp create_new_trick(state) do
    %Trick{
      number: state.trick_number + 1,
      leader: state.current_turn,
      plays: [],
      winner: nil,
      points: 0
    }
  end

  # Records card played event
  @spec record_card_played_event(game_state(), position(), card()) :: {:ok, game_state()}
  defp record_card_played_event(state, position, card) do
    event = {:card_played, position, card}
    updated_events = state.events ++ [event]
    updated_state = GameState.update(state, :events, updated_events)
    {:ok, updated_state}
  end

  # Checks if player should be eliminated after playing a card
  @spec check_player_elimination(game_state(), position()) :: {:ok, game_state()}
  defp check_player_elimination(state, position) do
    player = state.players[position]
    trump_suit = state.trump_suit

    # Check if player has no more trump cards
    has_trumps = Trump.has_trump?(player.hand, trump_suit)

    if has_trumps or player.eliminated? do
      # Player still has trumps or is already eliminated
      {:ok, state}
    else
      # Player is out of trumps, eliminate them
      eliminate_player(state, position)
    end
  end

  # Advances turn to next player or completes trick if all have played
  @spec advance_turn_or_complete_trick(game_state()) :: {:ok, game_state()}
  defp advance_turn_or_complete_trick(state) do
    if trick_complete?(state) do
      complete_trick(state)
    else
      next_turn = find_next_active_player(state)
      updated_state = GameState.update(state, :current_turn, next_turn)
      {:ok, updated_state}
    end
  end

  # Checks if current trick is complete (all active players have played)
  @spec trick_complete?(game_state()) :: boolean()
  defp trick_complete?(state) do
    played_positions =
      state.current_trick.plays
      |> Enum.map(fn {pos, _} -> pos end)

    active_positions =
      state.players
      |> Enum.filter(fn {_pos, player} -> not player.eliminated? end)
      |> Enum.map(fn {pos, _} -> pos end)

    # Check if all active positions are in played positions
    Enum.all?(active_positions, fn pos -> pos in played_positions end)
  end

  @doc """
  Finds next non-eliminated player clockwise from the given position.

  Used after compute_kills to advance current_turn past eliminated players.
  """
  @spec find_next_active_player(game_state()) :: position() | nil
  def find_next_active_player(state) do
    current = state.current_turn

    current
    |> Stream.iterate(&Types.next_position/1)
    |> Stream.drop(1)
    |> Enum.find(fn pos ->
      not state.players[pos].eliminated?
    end)
  end

  # Awards trick points to winning team
  @spec award_trick_points(game_state(), position(), non_neg_integer()) :: {:ok, game_state()}
  defp award_trick_points(state, winner_position, points) do
    # Get winner's team
    winner_team = Types.position_to_team(winner_position)

    # Update hand_points
    current_points = state.hand_points[winner_team]
    updated_hand_points = Map.put(state.hand_points, winner_team, current_points + points)
    state = GameState.update(state, :hand_points, updated_hand_points)

    # Increment tricks_won for winning player
    winner = state.players[winner_position]
    updated_winner = %{winner | tricks_won: winner.tricks_won + 1}
    updated_players = Map.put(state.players, winner_position, updated_winner)
    state = GameState.update(state, :players, updated_players)

    {:ok, state}
  end

  # Records trick won event
  @spec record_trick_won_event(game_state(), position(), non_neg_integer()) :: {:ok, game_state()}
  defp record_trick_won_event(state, winner, points) do
    event = {:trick_won, winner, points}
    updated_events = state.events ++ [event]
    updated_state = GameState.update(state, :events, updated_events)
    {:ok, updated_state}
  end

  # Moves current trick to history
  @spec move_trick_to_history(game_state()) :: {:ok, game_state()}
  defp move_trick_to_history(state) do
    trick = state.current_trick
    updated_tricks = state.tricks ++ [trick]
    state = GameState.update(state, :tricks, updated_tricks)
    state = GameState.update(state, :current_trick, nil)
    {:ok, state}
  end

  # Sets the leader for the next trick
  @spec set_next_trick_leader(game_state(), position()) :: {:ok, game_state()}
  defp set_next_trick_leader(state, leader) do
    players = state.players

    next_leader =
      case players[leader] do
        # Winner is still active – they lead next trick as usual
        %Player{eliminated?: false} ->
          leader

        # Winner went cold – choose next active clockwise from them
        _ ->
          leader
          |> Stream.iterate(&Types.next_position/1)
          |> Stream.drop(1)
          # Limit the stream to avoid infinite loops if everyone is cold
          |> Stream.take(4)
          |> Enum.find(fn pos ->
            case players[pos] do
              %Player{eliminated?: false} -> true
              _ -> false
            end
          end)
      end

    updated_state = GameState.update(state, :current_turn, next_leader)
    {:ok, updated_state}
  end

  # Maybe starts next trick if there are cards remaining
  @spec maybe_start_next_trick(game_state()) :: {:ok, game_state()}
  defp maybe_start_next_trick(state) do
    # Check if any player has cards remaining
    any_cards_remain =
      state.players
      |> Enum.any?(fn {_pos, player} ->
        not player.eliminated? and length(player.hand) > 0
      end)

    if any_cards_remain do
      # Increment trick number for next trick
      updated_trick_number = state.trick_number + 1
      state = GameState.update(state, :trick_number, updated_trick_number)
      {:ok, state}
    else
      # No more cards, playing phase is complete
      {:ok, state}
    end
  end

  # Records cards killed event
  @spec record_cards_killed_event(game_state(), map()) :: game_state()
  defp record_cards_killed_event(state, killed_cards) do
    event = {:cards_killed, killed_cards}
    updated_events = state.events ++ [event]
    GameState.update(state, :events, updated_events)
  end
end
