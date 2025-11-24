defmodule Pidro.Game.Discard do
  @moduledoc """
  Discard and second dealing logic for the Pidro game engine.

  This module handles the discard phase in Finnish Pidro, which includes:
  - Automatic discarding of all non-trump cards from all players' hands
  - Validating discard operations
  - Second deal to bring players up to 6 cards
  - Dealer robbing the pack (taking remaining cards and selecting final 6)
  - Handling edge cases where players already have 6+ trump cards

  ## Finnish Pidro Discard Rules

  ### Discard Phase
  - After trump is declared, all players automatically discard their non-trump cards
  - Non-trump cards are "camouflage" and cannot be played
  - Players with 6 or more trump cards keep all their trumps
  - Discarded cards go to the discard pile (not back into play)

  ### Second Deal
  - After discarding, players are dealt additional cards to reach 6 total
  - Cards are dealt clockwise starting from the left of the dealer
  - If a player already has 6+ trump cards, they receive no additional cards
  - Remaining cards (if any) are left for the dealer to rob

  ### Dealer Robs the Pack
  - After the second deal, dealer takes all remaining cards
  - Dealer selects any 6 cards from their enlarged hand
  - Discards the rest (even if they are trumps)
  - This gives the dealer a strategic advantage

  ## Examples

      # Discard all non-trumps for all players
      iex> state = %{GameState.new() | phase: :discarding, trump_suit: :hearts}
      iex> {:ok, state} = Discard.discard_non_trumps(state)
      iex> state.phase
      :second_deal

      # Validate cards can be discarded
      iex> cards = [{10, :clubs}, {7, :spades}]
      iex> Discard.validate_discard(cards, :hearts)
      :ok

      # Second deal to bring players to 6 cards
      iex> state = %{GameState.new() | phase: :second_deal, current_dealer: :north}
      iex> {:ok, state} = Discard.second_deal(state)

      # Dealer robs the pack
      iex> selected_cards = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
      iex> {:ok, state} = Discard.dealer_rob_pack(state, selected_cards)
  """

  alias Pidro.Core.{Types, Card, GameState}
  alias Pidro.Game.{Errors, Trump}

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type suit :: Types.suit()
  @type card :: Types.card()
  @type error :: Errors.error()

  # =============================================================================
  # Automatic Discard
  # =============================================================================

  @doc """
  Automatically discards all non-trump cards from all players' hands.

  This function processes all players simultaneously, removing any cards
  that are not trump cards (including the wrong 5). Discarded cards are
  recorded in events and moved to the discard pile.

  ## Parameters
  - `state` - Current game state (must be in `:discarding` phase with trump declared)

  ## Returns
  - `{:ok, state}` - Updated state with non-trumps discarded
  - `{:error, reason}` - If discarding is invalid

  ## State Changes
  - Removes non-trump cards from each player's hand
  - Adds discarded cards to `discarded_cards` pile
  - Records `{:cards_discarded, position, [card]}` events for each player
  - Transitions `phase` to `:second_deal`

  ## Validation
  - Game must be in `:discarding` phase
  - Trump suit must be declared

  ## Examples

      iex> state = %{GameState.new() | phase: :discarding, trump_suit: :hearts}
      iex> state = put_in(state.players[:north].hand, [{14, :hearts}, {10, :clubs}, {7, :hearts}])
      iex> {:ok, state} = Discard.discard_non_trumps(state)
      iex> state.players[:north].hand
      [{14, :hearts}, {7, :hearts}]
      iex> state.phase
      :second_deal

      iex> state = %{GameState.new() | phase: :bidding, trump_suit: :hearts}
      iex> Discard.discard_non_trumps(state)
      {:error, {:invalid_phase, :discarding, :bidding}}
  """
  @spec discard_non_trumps(game_state()) :: {:ok, game_state()} | {:error, error()}
  def discard_non_trumps(%Types.GameState{} = state) do
    with :ok <- validate_discarding_phase(state),
         :ok <- validate_trump_declared(state) do
      # Process each player's hand
      {updated_players, all_discarded_cards, events} =
        state.players
        |> Enum.reduce({state.players, [], []}, fn {position, player},
                                                   {players_acc, discards_acc, events_acc} ->
          # Categorize player's hand into trump and non-trump
          %{trump: trump_cards, non_trump: non_trump_cards} =
            Trump.categorize_hand(player.hand, state.trump_suit)

          # Update player's hand to only contain trump cards
          updated_player = %{player | hand: trump_cards}
          updated_players = Map.put(players_acc, position, updated_player)

          # Record discard event if player discarded any cards
          event =
            if length(non_trump_cards) > 0 do
              [{:cards_discarded, position, non_trump_cards}]
            else
              []
            end

          {updated_players, discards_acc ++ non_trump_cards, events_acc ++ event}
        end)

      # Update game state
      updated_state =
        state
        |> GameState.update(:players, updated_players)
        |> GameState.update(:discarded_cards, state.discarded_cards ++ all_discarded_cards)
        |> GameState.update(:events, state.events ++ events)
        |> GameState.update(:phase, :second_deal)

      {:ok, updated_state}
    end
  end

  # =============================================================================
  # Discard Validation
  # =============================================================================

  @doc """
  Validates that cards can be discarded (must be non-trump, non-point cards).

  In Finnish Pidro, players must discard all non-trump cards. This function
  validates that the provided cards are legal to discard (i.e., they are not
  trump cards).

  ## Parameters
  - `cards` - List of cards to validate for discarding
  - `trump_suit` - The declared trump suit

  ## Returns
  - `:ok` - All cards are valid to discard
  - `{:error, reason}` - If any card cannot be discarded

  ## Validation Rules
  - Cards must be non-trump (not of trump suit, not wrong 5)
  - Cards can have point values (validation focuses on trump status)

  ## Examples

      # Valid discard: all non-trumps
      iex> Discard.validate_discard([{10, :clubs}, {7, :spades}], :hearts)
      :ok

      # Invalid discard: contains trump card
      iex> Discard.validate_discard([{10, :hearts}, {7, :spades}], :hearts)
      {:error, {:cannot_discard_trump, {10, :hearts}}}

      # Invalid discard: contains wrong 5
      iex> Discard.validate_discard([{5, :diamonds}, {7, :spades}], :hearts)
      {:error, {:cannot_discard_trump, {5, :diamonds}}}
  """
  @spec validate_discard([card()], suit()) :: :ok | {:error, error()}
  def validate_discard(cards, trump_suit) when is_list(cards) do
    # Check if any card is a trump card
    case Enum.find(cards, fn card -> Card.is_trump?(card, trump_suit) end) do
      nil ->
        :ok

      trump_card ->
        {:error, {:cannot_discard_trump, trump_card}}
    end
  end

  # =============================================================================
  # Second Deal
  # =============================================================================

  @doc """
  Deals remaining cards to bring players up to 6 cards each.

  After discarding, players receive additional cards from the deck to reach
  6 total cards. Players who already have 6 or more trump cards do not
  receive additional cards.

  ## Parameters
  - `state` - Current game state (must be in `:second_deal` phase)

  ## Returns
  - `{:ok, state}` - Updated state with second deal complete
  - `{:error, reason}` - If second deal is invalid

  ## State Changes
  - Deals cards to players who have fewer than 6 cards
  - Updates each player's `hand` with dealt cards
  - Removes dealt cards from `deck`
  - Records `{:second_deal_complete, %{position => [card]}}` event
  - Transitions `phase` to `:playing` if dealer has no cards to rob
  - Otherwise, stays in `:second_deal` phase for dealer to rob pack

  ## Dealing Order
  - Starts with the player to the left of the dealer
  - Proceeds clockwise around the table
  - Each player receives cards to reach exactly 6 (unless they already have 6+)

  ## Edge Cases
  - Players with 6+ trump cards receive no cards
  - If deck runs out before all players reach 6, dealing stops
  - Remaining cards (if any) are for the dealer to rob

  ## Examples

      iex> state = %{GameState.new() | phase: :second_deal, current_dealer: :north}
      iex> state = put_in(state.players[:east].hand, [{14, :hearts}, {13, :hearts}])
      iex> state = put_in(state.deck, [{10, :hearts}, {9, :hearts}, {8, :hearts}, {7, :hearts}])
      iex> {:ok, state} = Discard.second_deal(state)
      iex> length(state.players[:east].hand)
      6
  """
  @spec second_deal(game_state()) :: {:ok, game_state()} | {:error, error()}
  def second_deal(%Types.GameState{} = state) do
    with :ok <- validate_second_deal_phase(state),
         :ok <- validate_dealer_exists(state) do
      # Determine dealing order: start left of dealer, go clockwise
      # IMPORTANT: Exclude the dealer - they don't get dealt to, they rob the pack
      first_player = Types.next_position(state.current_dealer)
      deal_order = get_deal_order_non_dealer(first_player, state.current_dealer)

      # Deal cards to each NON-DEALER player to reach 6 cards (or skip if they have 6+)
      {updated_players, remaining_deck, dealt_cards_map, cards_requested_map} =
        Enum.reduce(deal_order, {state.players, state.deck, %{}, %{}}, fn position,
                                                                          {players_acc, deck_acc,
                                                                           dealt_acc,
                                                                           requested_acc} ->
          player = Map.get(players_acc, position)
          current_hand_size = length(player.hand)

          if current_hand_size >= 6 do
            # Player already has 6+ cards, skip
            {players_acc, deck_acc, Map.put(dealt_acc, position, []),
             Map.put(requested_acc, position, 0)}
          else
            # Deal cards to reach 6
            cards_needed = 6 - current_hand_size
            {dealt_cards, new_deck} = Enum.split(deck_acc, cards_needed)

            # Update player's hand
            updated_player = %{player | hand: player.hand ++ dealt_cards}
            updated_players = Map.put(players_acc, position, updated_player)

            {updated_players, new_deck, Map.put(dealt_acc, position, dealt_cards),
             Map.put(requested_acc, position, cards_needed)}
          end
        end)

      # Record second deal complete event
      event = {:second_deal_complete, dealt_cards_map}

      # Check if dealer should rob the pack (if there are cards remaining)
      # Dealer is the last to be dealt to, and gets to rob any remaining cards
      dealer_hand_size = length(Map.get(updated_players, state.current_dealer).hand)
      dealer_needs_rob = length(remaining_deck) > 0 and dealer_hand_size < 6

      # Update game state
      updated_state =
        state
        |> GameState.update(:players, updated_players)
        |> GameState.update(:deck, remaining_deck)
        |> GameState.update(:cards_requested, cards_requested_map)
        |> GameState.update(:events, state.events ++ [event])

      # If dealer needs to rob the pack, stay in second_deal phase
      # Otherwise, transition to playing phase
      if dealer_needs_rob do
        # Dealer should rob the pack - stay in second_deal phase but set turn to dealer
        final_state = GameState.update(updated_state, :current_turn, state.current_dealer)
        {:ok, final_state}
      else
        # No cards left for dealer to rob, or dealer already has 6 cards
        # Transition directly to playing phase; highest bidder leads the first trick
        leader = bidding_winner(updated_state)

        final_state =
          updated_state
          |> GameState.update(:phase, :playing)
          |> GameState.update(:current_turn, leader)

        {:ok, final_state}
      end
    end
  end

  # =============================================================================
  # Dealer Rob Pack
  # =============================================================================

  @doc """
  Dealer takes remaining cards and selects their final 6 cards.

  After the second deal, if there are cards remaining in the deck, the dealer
  adds them to their hand and then selects exactly 6 cards to keep. The rest
  are discarded, even if they are trump cards.

  ## Parameters
  - `state` - Current game state (must be in `:second_deal` phase, dealer's turn)
  - `selected_cards` - List of exactly 6 cards the dealer chooses to keep

  ## Returns
  - `{:ok, state}` - Updated state with dealer's hand finalized
  - `{:error, reason}` - If robbing is invalid

  ## State Changes
  - Sets dealer's `hand` to the selected 6 cards
  - Adds remaining cards to `discarded_cards` pile
  - Records `{:dealer_robbed_pack, position, taken_count, kept_count}` event
  - Stores `dealer_pool_size` in game state (total cards before selection)
  - Transitions `phase` to `:playing`
  - Sets `current_turn` to the highest bidder (to lead the first trick)

  ## Validation
  - Game must be in `:second_deal` phase
  - Current turn must be the dealer
  - Must select exactly 6 cards
  - All selected cards must be in dealer's current hand (including robbed cards)

  ## Examples

      iex> state = %{GameState.new() | phase: :second_deal, current_dealer: :north, current_turn: :north}
      iex> state = put_in(state.players[:north].hand, [{14, :hearts}, {13, :hearts}, {12, :hearts}])
      iex> state = put_in(state.deck, [{11, :hearts}, {10, :hearts}, {9, :hearts}, {8, :hearts}])
      iex> # Dealer takes remaining cards and selects 6 to keep
      iex> selected = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
      # Mock highest bid for example context
      iex> state = %{state | highest_bid: {:north, 10}}
      iex> {:ok, state} = Discard.dealer_rob_pack(state, selected)
      iex> length(state.players[:north].hand)
      6
      iex> state.phase
      :playing
  """
  @spec dealer_rob_pack(game_state(), [card()]) :: {:ok, game_state()} | {:error, error()}
  def dealer_rob_pack(%Types.GameState{} = state, selected_cards) when is_list(selected_cards) do
    with :ok <- validate_second_deal_phase(state),
         :ok <- validate_dealer_exists(state),
         :ok <- validate_dealer_turn(state),
         :ok <- validate_six_cards(selected_cards) do
      dealer = state.current_dealer
      dealer_player = Map.get(state.players, dealer)

      # Dealer takes all remaining cards from deck
      remaining_cards = state.deck
      dealer_full_hand = dealer_player.hand ++ remaining_cards

      # Calculate pool size (total cards dealer has before selection)
      dealer_pool_size = length(dealer_full_hand)

      # Validate selected cards are all in dealer's full hand
      case validate_cards_in_hand(selected_cards, dealer_full_hand) do
        :ok ->
          # Calculate discarded cards
          discarded = dealer_full_hand -- selected_cards

          # Update dealer's hand
          updated_dealer = %{dealer_player | hand: selected_cards}
          updated_players = Map.put(state.players, dealer, updated_dealer)

          # Record dealer robbed pack event (emit counts only for hidden info protection)
          event = {:dealer_robbed_pack, dealer, length(remaining_cards), length(selected_cards)}

          leader = bidding_winner(state)

          # Update game state
          updated_state =
            state
            |> GameState.update(:players, updated_players)
            |> GameState.update(:deck, [])
            |> GameState.update(:discarded_cards, state.discarded_cards ++ discarded)
            |> GameState.update(:dealer_pool_size, dealer_pool_size)
            |> GameState.update(:events, state.events ++ [event])
            |> GameState.update(:phase, :playing)
            |> GameState.update(:current_turn, leader)

          {:ok, updated_state}

        error ->
          error
      end
    end
  end

  # =============================================================================
  # Private Validation Functions
  # =============================================================================

  # Validates game is in discarding phase
  @spec validate_discarding_phase(game_state()) :: :ok | {:error, error()}
  defp validate_discarding_phase(%Types.GameState{phase: :discarding}), do: :ok

  defp validate_discarding_phase(%Types.GameState{phase: actual_phase}) do
    {:error, {:invalid_phase, :discarding, actual_phase}}
  end

  # Validates game is in second_deal phase
  @spec validate_second_deal_phase(game_state()) :: :ok | {:error, error()}
  defp validate_second_deal_phase(%Types.GameState{phase: :second_deal}), do: :ok

  defp validate_second_deal_phase(%Types.GameState{phase: actual_phase}) do
    {:error, {:invalid_phase, :second_deal, actual_phase}}
  end

  # Validates trump suit has been declared
  @spec validate_trump_declared(game_state()) :: :ok | {:error, error()}
  defp validate_trump_declared(%Types.GameState{trump_suit: nil}) do
    {:error, {:trump_not_declared, "Cannot discard cards before trump is declared"}}
  end

  defp validate_trump_declared(%Types.GameState{trump_suit: _suit}), do: :ok

  # Validates dealer exists
  @spec validate_dealer_exists(game_state()) :: :ok | {:error, error()}
  defp validate_dealer_exists(%Types.GameState{current_dealer: nil}) do
    {:error, {:no_dealer, "Cannot perform second deal without a dealer"}}
  end

  defp validate_dealer_exists(%Types.GameState{current_dealer: _dealer}), do: :ok

  # Validates it's the dealer's turn
  @spec validate_dealer_turn(game_state()) :: :ok | {:error, error()}
  defp validate_dealer_turn(%Types.GameState{current_dealer: dealer, current_turn: dealer}),
    do: :ok

  defp validate_dealer_turn(%Types.GameState{current_dealer: dealer, current_turn: turn}) do
    {:error, {:not_dealer_turn, dealer, turn}}
  end

  # Validates exactly 6 cards selected
  @spec validate_six_cards([card()]) :: :ok | {:error, error()}
  defp validate_six_cards(cards) when length(cards) == 6, do: :ok

  defp validate_six_cards(cards) do
    {:error, {:invalid_card_count, 6, length(cards)}}
  end

  # Validates all selected cards are in dealer's hand
  @spec validate_cards_in_hand([card()], [card()]) :: :ok | {:error, error()}
  defp validate_cards_in_hand(selected_cards, hand) do
    case Enum.find(selected_cards, fn card -> card not in hand end) do
      nil ->
        :ok

      missing_card ->
        {:error, {:card_not_in_hand, missing_card}}
    end
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

  # Helper to get the bidding winner (highest bidder)
  @spec bidding_winner(game_state()) :: position()
  defp bidding_winner(%Types.GameState{highest_bid: {position, _amount}}), do: position

  # Returns deal order excluding the dealer (3 positions, not 4)
  defp get_deal_order_non_dealer(start_position, dealer) do
    get_deal_order(start_position)
    |> Enum.reject(&(&1 == dealer))
  end
end
