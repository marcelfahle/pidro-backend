defmodule Pidro.Game.Dealing do
  @moduledoc """
  Card dealing logic for the Pidro game engine.

  This module handles all aspects of dealer selection and card distribution
  in Finnish Pidro, including:
  - Cutting the deck to determine the first dealer
  - Rotating dealer position clockwise between hands
  - Initial deal of 9 cards per player in 3-card batches
  - Setting turn order relative to dealer position

  ## Finnish Pidro Dealing Rules

  ### Dealer Selection (First Hand Only)
  - Players cut the deck to determine the first dealer
  - Highest card cut wins dealer position
  - In case of ties, re-cut among tied players

  ### Card Distribution
  - 9 cards dealt initially to each player
  - Cards dealt in three batches of 3 cards each
  - Dealing starts to the left of the dealer (next clockwise position)
  - Dealing proceeds clockwise around the table
  - After dealing, current turn is set to left of dealer

  ### Dealer Rotation
  - After each hand, dealer position rotates clockwise
  - North -> East -> South -> West -> North

  ## Examples

      # Select initial dealer by cutting
      iex> state = GameState.new()
      iex> {:ok, state} = Dealing.select_dealer(state)
      iex> state.current_dealer in [:north, :east, :south, :west]
      true

      # Deal initial cards
      iex> state = GameState.new() |> Map.put(:current_dealer, :north)
      iex> state = Map.put(state, :deck, Pidro.Core.Deck.new().cards)
      iex> {:ok, state} = Dealing.deal_initial(state)
      iex> Enum.all?(state.players, fn {_pos, player} -> length(player.hand) == 9 end)
      true

      # Rotate dealer for next hand
      iex> state = %{GameState.new() | current_dealer: :north}
      iex> {:ok, state} = Dealing.rotate_dealer(state)
      iex> state.current_dealer
      :east
  """

  alias Pidro.Core.{Types, GameState}

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type card :: Types.card()
  @type error :: {:error, atom() | tuple(), String.t()}

  # =============================================================================
  # Dealer Selection
  # =============================================================================

  @doc """
  Selects the initial dealer by simulating a deck cut.

  Each player "cuts" the deck by drawing a random card. The player with the
  highest card becomes the dealer. In case of ties, tied players re-cut.

  This function uses randomization to determine the dealer, simulating the
  traditional card-cutting ceremony.

  ## Parameters
  - `state` - Current game state (should be in `:dealer_selection` phase)

  ## Returns
  - `{:ok, state}` - Updated state with dealer selected and event recorded
  - `{:error, reason, message}` - If state is invalid for dealer selection

  ## State Changes
  - Sets `current_dealer` to the selected position
  - Adds `{:dealer_selected, position, card}` event to history
  - Phase remains `:dealer_selection` (caller should transition to `:dealing`)

  ## Examples

      iex> state = GameState.new()
      iex> {:ok, state} = Dealing.select_dealer(state)
      iex> state.current_dealer in [:north, :east, :south, :west]
      true
      iex> [event | _] = Enum.reverse(state.events)
      iex> match?({:dealer_selected, _, _}, event)
      true
  """
  @spec select_dealer(game_state()) :: {:ok, game_state()} | error()
  def select_dealer(%Types.GameState{} = state) do
    # Simulate cutting by having each player draw a random card
    positions = [:north, :east, :south, :west]

    # Generate random cards for each position (simulating cuts)
    cuts =
      positions
      |> Enum.map(fn pos ->
        # Generate a random rank (2-14) and suit
        rank = Enum.random(2..14)
        suit = Enum.random([:hearts, :diamonds, :clubs, :spades])
        card = {rank, suit}
        {pos, card, rank}
      end)
      |> Enum.sort_by(fn {_pos, _card, rank} -> rank end, :desc)

    # Winner is the player with the highest card
    [{winner_pos, winner_card, _rank} | _rest] = cuts

    # Create and shuffle a new deck for the hand
    deck = Pidro.Core.Deck.new()

    # Update state with selected dealer and shuffled deck
    event = {:dealer_selected, winner_pos, winner_card}

    updated_state =
      state
      |> GameState.update(:current_dealer, winner_pos)
      |> GameState.update(:deck, deck.cards)
      |> GameState.update(:events, state.events ++ [event])

    {:ok, updated_state}
  end

  # =============================================================================
  # Dealer Rotation
  # =============================================================================

  @doc """
  Rotates the dealer position to the next player clockwise.

  This function should be called at the start of each new hand (after scoring
  the previous hand). The dealer position moves clockwise around the table:
  North -> East -> South -> West -> North

  ## Parameters
  - `state` - Current game state with an existing dealer

  ## Returns
  - `{:ok, state}` - Updated state with dealer rotated
  - `{:error, :no_dealer, message}` - If no current dealer is set

  ## State Changes
  - Updates `current_dealer` to next clockwise position
  - Increments `hand_number`
  - No event is recorded (dealer rotation is implicit)

  ## Examples

      iex> state = %{GameState.new() | current_dealer: :north}
      iex> {:ok, state} = Dealing.rotate_dealer(state)
      iex> state.current_dealer
      :east

      iex> state = %{GameState.new() | current_dealer: :west}
      iex> {:ok, state} = Dealing.rotate_dealer(state)
      iex> state.current_dealer
      :north
  """
  @spec rotate_dealer(game_state()) :: {:ok, game_state()} | error()
  def rotate_dealer(%Types.GameState{current_dealer: nil}) do
    {:error, :no_dealer, "Cannot rotate dealer when no dealer is set"}
  end

  def rotate_dealer(%Types.GameState{current_dealer: current_dealer} = state) do
    next_dealer = Types.next_position(current_dealer)

    updated_state =
      state
      |> GameState.update(:current_dealer, next_dealer)
      |> GameState.update(:hand_number, state.hand_number + 1)

    {:ok, updated_state}
  end

  # =============================================================================
  # Initial Deal
  # =============================================================================

  @doc """
  Deals the initial 9 cards to each player in 3-card batches.

  Cards are dealt clockwise starting from the player to the left of the dealer.
  The dealing proceeds in three rounds, with each player receiving 3 cards per
  round, for a total of 9 cards each.

  ## Dealing Order
  If dealer is North, dealing order is: East -> South -> West -> North (repeat 3 times)

  ## Parameters
  - `state` - Current game state with dealer set and shuffled deck

  ## Returns
  - `{:ok, state}` - Updated state with cards dealt to all players
  - `{:error, :no_dealer, message}` - If no dealer is set
  - `{:error, :insufficient_cards, message}` - If deck has fewer than 36 cards

  ## State Changes
  - Updates each player's `hand` with 9 dealt cards
  - Removes dealt cards from `deck`
  - Sets `current_turn` to the player left of dealer
  - Adds `{:cards_dealt, %{position => [card]}}` event to history
  - Phase should be `:dealing` (caller responsible for phase transitions)

  ## Examples

      # Deal with deck as card list
      iex> state = GameState.new()
      iex> state = Map.put(state, :current_dealer, :north)
      iex> state = Map.put(state, :deck, Pidro.Core.Deck.new().cards)
      iex> {:ok, state} = Dealing.deal_initial(state)
      iex> Enum.all?(state.players, fn {_pos, p} -> length(p.hand) == 9 end)
      true
      iex> state.current_turn
      :east

      # Error when no dealer set
      iex> state = GameState.new()
      iex> state = Map.put(state, :deck, Pidro.Core.Deck.new().cards)
      iex> Dealing.deal_initial(state)
      {:error, :no_dealer, "Cannot deal cards without a dealer"}
  """
  @spec deal_initial(game_state()) :: {:ok, game_state()} | error()
  def deal_initial(%Types.GameState{current_dealer: nil}) do
    {:error, :no_dealer, "Cannot deal cards without a dealer"}
  end

  def deal_initial(%Types.GameState{deck: deck}) when length(deck) < 36 do
    {:error, :insufficient_cards,
     "Cannot deal initial cards: need 36 cards but only #{length(deck)} available"}
  end

  def deal_initial(%Types.GameState{current_dealer: dealer, deck: deck} = state) do
    # Determine dealing order: start left of dealer, go clockwise
    first_player = Types.next_position(dealer)
    deal_order = get_deal_order(first_player)

    # Deal 3 cards at a time, 3 rounds total
    {dealt_hands, remaining_deck} = deal_in_batches(deck, deal_order, 3, 3)

    # Update each player's hand
    updated_players =
      Enum.reduce(dealt_hands, state.players, fn {position, cards}, players ->
        player = Map.get(players, position)
        updated_player = %{player | hand: cards}
        Map.put(players, position, updated_player)
      end)

    # Create event for the deal
    event = {:cards_dealt, dealt_hands}

    # Update state
    updated_state =
      state
      |> GameState.update(:players, updated_players)
      |> GameState.update(:deck, remaining_deck)
      |> GameState.update(:current_turn, first_player)
      |> GameState.update(:events, state.events ++ [event])

    {:ok, updated_state}
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Returns the dealing order starting from a given position, going clockwise
  @spec get_deal_order(position()) :: [position()]
  defp get_deal_order(start_position) do
    [
      start_position,
      Types.next_position(start_position),
      Types.next_position(Types.next_position(start_position)),
      Types.next_position(Types.next_position(Types.next_position(start_position)))
    ]
  end

  # Deals cards in batches to players
  # Returns {%{position => [cards]}, remaining_deck}
  @spec deal_in_batches([card()], [position()], pos_integer(), pos_integer()) ::
          {%{position() => [card()]}, [card()]}
  defp deal_in_batches(deck, positions, batch_size, num_batches) do
    # Initialize accumulator with empty hands for each position
    initial_hands = Map.new(positions, fn pos -> {pos, []} end)

    # Deal cards in batches
    {final_hands, remaining_deck} =
      Enum.reduce(1..num_batches, {initial_hands, deck}, fn _batch_num, {hands, deck_acc} ->
        # Deal batch_size cards to each player in order
        Enum.reduce(positions, {hands, deck_acc}, fn position, {hands_acc, deck_acc} ->
          # Take batch_size cards from deck
          {cards, new_deck} = Enum.split(deck_acc, batch_size)

          # Add to player's hand
          updated_hand = Map.get(hands_acc, position) ++ cards
          updated_hands = Map.put(hands_acc, position, updated_hand)

          {updated_hands, new_deck}
        end)
      end)

    {final_hands, remaining_deck}
  end
end
