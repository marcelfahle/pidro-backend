defmodule Pidro.Core.StateView do
  @moduledoc """
  Creates player-specific views of game state for secure WebSocket broadcasting.

  This module provides pure functions that mask sensitive game data based on
  the viewing player's position. It ensures each client only receives information
  they're allowed to see, preventing cheating via WebSocket inspection.

  ## Visibility Rules

  | Data | Own Player | Opponents | Spectators |
  |------|------------|-----------|------------|
  | Hand contents | Full cards | Count only | Count only |
  | Deck | Hidden | Hidden | Hidden |
  | Bids | Visible | Visible | Visible |
  | Current trick | Visible | Visible | Visible |
  | Completed tricks | Visible | Visible | Visible |
  | Killed cards | Visible | Visible | Visible |
  | Trump suit | Visible | Visible | Visible |
  | Scores | Visible | Visible | Visible |
  | Events | Hidden | Hidden | Hidden |
  | Cache | Hidden | Hidden | Hidden |

  ## Usage

      # For a player
      masked = StateView.for_player(game_state, :north)

      # For a spectator
      masked = StateView.for_spectator(game_state)

      # For dev/admin (full state)
      full = StateView.full_state(game_state)
  """

  alias Pidro.Core.Types
  alias Pidro.Core.Types.GameState

  @doc """
  Creates a masked view of the game state for a specific player position.

  The viewing player sees their own hand in full, but opponent hands are
  replaced with card counts. Deck, events, and cache are stripped.

  ## Parameters

    - `state` - The full GameState struct
    - `viewer_position` - The position of the viewing player (:north, :east, :south, :west)

  ## Returns

  A map (not struct) containing the masked game state suitable for serialization.

  ## Examples

      iex> masked = StateView.for_player(game_state, :north)
      iex> masked.players[:north].hand
      [{14, :hearts}, {13, :hearts}, ...]  # Full cards
      iex> masked.players[:south].hand
      5  # Just the count
      iex> masked.deck
      nil
  """
  @spec for_player(GameState.t(), Types.position()) :: map()
  def for_player(%GameState{} = state, viewer_position)
      when viewer_position in [:north, :east, :south, :west] do
    %{
      # Core game state (public)
      phase: state.phase,
      hand_number: state.hand_number,
      variant: state.variant,
      current_dealer: state.current_dealer,
      current_turn: state.current_turn,

      # Players (masked based on viewer)
      players: mask_players(state.players, viewer_position),

      # Bidding (public)
      bids: state.bids,
      highest_bid: state.highest_bid,
      bidding_team: state.bidding_team,

      # Trump (public)
      trump_suit: state.trump_suit,

      # Tricks (public - cards on table and completed tricks)
      tricks: state.tricks,
      current_trick: state.current_trick,
      trick_number: state.trick_number,

      # Scoring (public)
      hand_points: state.hand_points,
      cumulative_scores: state.cumulative_scores,
      winner: state.winner,

      # Killed cards (public - face-up discards in Finnish Pidro)
      killed_cards: state.killed_cards,

      # Deck: visible to dealer during second_deal (rob phase), hidden otherwise
      deck: dealer_rob_deck(state, viewer_position),
      discarded_cards: nil,
      events: nil,
      cache: nil,
      cards_requested: nil,
      dealer_pool_size: state.dealer_pool_size,
      config: nil
    }
  end

  @doc """
  Creates a masked view of the game state for spectators.

  Spectators see public information only - no player hands are visible.
  All hands are replaced with card counts.

  ## Parameters

    - `state` - The full GameState struct

  ## Returns

  A map containing the spectator view of the game state.
  """
  @spec for_spectator(GameState.t()) :: map()
  def for_spectator(%GameState{} = state) do
    %{
      # Core game state (public)
      phase: state.phase,
      hand_number: state.hand_number,
      variant: state.variant,
      current_dealer: state.current_dealer,
      current_turn: state.current_turn,

      # Players (all hands masked)
      players: mask_all_players(state.players),

      # Bidding (public)
      bids: state.bids,
      highest_bid: state.highest_bid,
      bidding_team: state.bidding_team,

      # Trump (public)
      trump_suit: state.trump_suit,

      # Tricks (public)
      tricks: state.tricks,
      current_trick: state.current_trick,
      trick_number: state.trick_number,

      # Scoring (public)
      hand_points: state.hand_points,
      cumulative_scores: state.cumulative_scores,
      winner: state.winner,

      # Killed cards (public)
      killed_cards: state.killed_cards,

      # Stripped fields
      deck: nil,
      discarded_cards: nil,
      events: nil,
      cache: nil,
      cards_requested: nil,
      dealer_pool_size: nil,
      config: nil
    }
  end

  @doc """
  Returns the full game state as a map (for dev/admin use).

  This is used by the Dev UI "god mode" to display all game information
  including all player hands.

  ## Parameters

    - `state` - The full GameState struct

  ## Returns

  A map containing the complete game state (no masking applied).
  """
  @spec full_state(GameState.t()) :: map()
  def full_state(%GameState{} = state) do
    # Convert struct to map, keeping all fields
    # Strip only cache and config which are internal
    state
    |> Map.from_struct()
    |> Map.drop([:cache, :config])
  end

  # Private helpers

  @spec mask_players(map(), Types.position()) :: map()
  defp mask_players(players, viewer_position) do
    players
    |> Enum.map(fn {position, player} ->
      if position == viewer_position do
        # Viewer sees their own full hand
        {position, player_to_map(player)}
      else
        # Others see only hand count
        {position, mask_player(player)}
      end
    end)
    |> Enum.into(%{})
  end

  @spec mask_all_players(map()) :: map()
  defp mask_all_players(players) do
    players
    |> Enum.map(fn {position, player} ->
      {position, mask_player(player)}
    end)
    |> Enum.into(%{})
  end

  @spec player_to_map(Types.Player.t()) :: map()
  defp player_to_map(player) do
    %{
      position: player.position,
      team: player.team,
      hand: player.hand,
      eliminated: player.eliminated?,
      revealed_cards: player.revealed_cards,
      tricks_won: player.tricks_won
    }
  end

  @spec mask_player(Types.Player.t()) :: map()
  defp mask_player(player) do
    %{
      position: player.position,
      team: player.team,
      hand: length(player.hand),
      eliminated: player.eliminated?,
      revealed_cards: player.revealed_cards,
      tricks_won: player.tricks_won
    }
  end

  # During the second_deal phase, the dealer needs to see the remaining deck
  # cards (the "pool") to select their best 6 cards for the rob.
  @spec dealer_rob_deck(GameState.t(), Types.position()) :: list() | nil
  defp dealer_rob_deck(%GameState{phase: :second_deal} = state, viewer_position) do
    if viewer_position == state.current_dealer do
      state.deck
    else
      nil
    end
  end

  defp dealer_rob_deck(_state, _viewer_position), do: nil
end
