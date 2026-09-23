defmodule Pidro.Core.GameState do
  @moduledoc """
  GameState construction and manipulation functions.

  This module provides functions for creating and updating game state in an
  immutable manner. The GameState struct itself is defined in `Pidro.Core.Types`.

  ## Usage

      iex> state = GameState.new(seed: 7)
      iex> state.phase
      :dealer_selection
      iex> state = GameState.update(state, :phase, :dealing)
      iex> state.phase
      :dealing

  ## Immutability

  All functions return new GameState structs; originals are never modified.
  This enables:
  - Safe concurrent reads
  - Easy undo/replay functionality
  - Event sourcing
  - Time-travel debugging
  """

  alias Pidro.Core.Chance
  alias Pidro.Core.Types.{GameState, Player}

  @doc """
  Creates a new game state with initial values.

  The game starts in the `:dealer_selection` phase with 4 players
  positioned at North, East, South, and West. Players are assigned to
  their respective teams:
  - North/South partnership (`:north_south` team)
  - East/West partnership (`:east_west` team)

  ## Options

  - `:seed` — **required**. The seed for this game's explicit chance stream,
    either an integer or a `{a, b, c}` triple. It is converted once, here, via
    `Pidro.Core.Chance.from_seed/1`, and every random draw the engine makes
    for this game derives from it.

  There is no default and no `new/0`: a game's randomness is an input, and the
  caller has to say where it comes from. `Pidro.Server` generates fresh
  entropy for live games; tests, simulations and CLI tooling pass a fixed seed.
  Restoring a saved game does **not** go through this function — a restored
  state already carries its chance value.

  ## Returns

  A new `GameState.t()` struct with:
  - Phase set to `:dealer_selection`
  - 4 players initialized in their positions with correct team assignments
  - Empty hands for all players
  - A chance stream derived from `:seed`
  - Default configuration (min_bid: 6, max_bid: 14, winning_score: 62)
  - All score fields initialized to 0

  ## Raises

  `KeyError` if `:seed` is missing.

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> state.phase
      :dealer_selection
      iex> map_size(state.players)
      4
      iex> state.players[:north].team
      :north_south
      iex> state.players[:east].team
      :east_west

      iex> GameState.new(seed: 7) == GameState.new(seed: 7)
      true
  """
  @spec new(keyword()) :: GameState.t()
  def new(opts) when is_list(opts) do
    chance = opts |> Keyword.fetch!(:seed) |> Chance.from_seed()

    %GameState{
      phase: :dealer_selection,
      hand_number: 1,
      variant: :finnish,
      players: %{
        north: %Player{
          position: :north,
          team: :north_south,
          hand: [],
          eliminated?: false,
          revealed_cards: [],
          tricks_won: 0
        },
        east: %Player{
          position: :east,
          team: :east_west,
          hand: [],
          eliminated?: false,
          revealed_cards: [],
          tricks_won: 0
        },
        south: %Player{
          position: :south,
          team: :north_south,
          hand: [],
          eliminated?: false,
          revealed_cards: [],
          tricks_won: 0
        },
        west: %Player{
          position: :west,
          team: :east_west,
          hand: [],
          eliminated?: false,
          revealed_cards: [],
          tricks_won: 0
        }
      },
      current_dealer: nil,
      current_turn: nil,
      deck: [],
      discarded_cards: [],
      bids: [],
      highest_bid: nil,
      bidding_team: nil,
      trump_suit: nil,
      tricks: [],
      current_trick: nil,
      trick_number: 0,
      hand_points: %{north_south: 0, east_west: 0},
      cumulative_scores: %{north_south: 0, east_west: 0},
      winner: nil,
      events: [],
      config: %{
        min_bid: 6,
        max_bid: 14,
        winning_score: 62,
        initial_deal_count: 9,
        final_hand_size: 6,
        allow_negative_scores: true
      },
      chance: chance,
      cache: %{}
    }
  end

  @doc """
  Updates a single field in the game state immutably.

  This is a convenience function for updating individual fields while
  maintaining immutability. It uses Elixir's `Map.put/3` under the hood.

  ## Parameters

  - `state` - The current GameState
  - `key` - The field name (atom) to update
  - `value` - The new value for the field

  ## Returns

  A new `GameState.t()` with the specified field updated.

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> state = GameState.update(state, :phase, :dealing)
      iex> state.phase
      :dealing

      iex> state = GameState.new(seed: 7)
      iex> state = GameState.update(state, :current_dealer, :north)
      iex> state.current_dealer
      :north

      iex> state = GameState.new(seed: 7)
      iex> state = GameState.update(state, :trump_suit, :hearts)
      iex> state.trump_suit
      :hearts

  ## Notes

  For updating nested structures like players or scores, you may need to
  construct the new nested value before passing it to this function:

      iex> state = GameState.new(seed: 7)
      iex> updated_players = Map.put(state.players, :north, updated_north_player)
      iex> state = GameState.update(state, :players, updated_players)
  """
  @spec update(GameState.t(), atom(), any()) :: GameState.t()
  def update(%GameState{} = state, key, value) when is_atom(key) do
    Map.put(state, key, value)
  end
end
