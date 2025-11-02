defmodule Pidro.Generators do
  @moduledoc """
  StreamData generators for property-based testing of Pidro game components.
  """

  use ExUnitProperties

  @doc """
  Generates valid card ranks for Pidro.
  """
  def rank do
    StreamData.member_of([
      :ace,
      :two,
      :three,
      :four,
      :five,
      :six,
      :seven,
      :eight,
      :nine,
      :ten,
      :jack,
      :queen,
      :king
    ])
  end

  @doc """
  Generates valid card suits.
  """
  def suit do
    StreamData.member_of([:hearts, :diamonds, :clubs, :spades])
  end

  @doc """
  Generates a valid card.
  """
  def card do
    StreamData.tuple({rank(), suit()})
  end

  @doc """
  Generates a list of unique cards.
  """
  def cards(opts \\ []) do
    min_length = Keyword.get(opts, :min_length, 0)
    max_length = Keyword.get(opts, :max_length, 52)

    StreamData.uniq_list_of(card(), min_length: min_length, max_length: max_length)
  end

  @doc """
  Generates a valid hand of cards (9 cards for Pidro).
  """
  def hand do
    cards(min_length: 9, max_length: 9)
  end

  @doc """
  Generates a valid bid value.
  """
  def bid do
    StreamData.integer(5..14)
  end

  @doc """
  Generates a player ID.
  """
  def player_id do
    StreamData.member_of([:north, :south, :east, :west])
  end

  @doc """
  Generates a team ID.
  """
  def team_id do
    StreamData.member_of([:team1, :team2])
  end

  @doc """
  Generates a trump suit.
  """
  def trump_suit do
    suit()
  end

  # =============================================================================
  # Redeal Mechanics Generators
  # =============================================================================

  @doc """
  Generates a position (player seat).
  """
  def position do
    StreamData.member_of([:north, :east, :south, :west])
  end

  @doc """
  Generates a game state at the pre-dealer-selection stage (second_deal phase).

  This represents the state after players have discarded non-trumps and are
  ready for the dealer to rob the pack.

  ## Returns

  A `GameState` where:
  - Phase is `:second_deal`
  - Each player has 0-6 trump cards
  - Dealer has 0-3 trump cards (to leave room for robbing)
  - Remaining deck has cards for redeal
  - Trump suit is declared
  """
  def pre_dealer_selection_generator do
    StreamData.bind(trump_suit(), fn trump ->
      StreamData.bind(position(), fn dealer_pos ->
        StreamData.fixed_map(%{
          trump_suit: StreamData.constant(trump),
          dealer_position: StreamData.constant(dealer_pos),
          dealer_trump_count: StreamData.integer(0..3),
          non_dealer_trump_counts: StreamData.list_of(StreamData.integer(0..6), length: 3)
        })
      end)
    end)
    |> StreamData.map(&build_pre_dealer_selection_state/1)
  end

  @doc """
  Generates a game state after the dealer has robbed the pack.

  This represents the state where:
  - Dealer has selected their best 6 cards from the combined pool
  - `dealer_pool_size` is tracked
  - All non-dealers have exactly 6 cards
  - Game is ready to transition to playing phase

  ## Returns

  A `GameState` with dealer rob complete.
  """
  def post_dealer_rob_generator do
    pre_dealer_selection_generator()
    |> StreamData.map(&simulate_dealer_rob/1)
  end

  @doc """
  Generates a game state after second deal is complete.

  This represents the state where:
  - Non-dealers have been dealt cards to reach 6 total
  - `cards_requested` map is populated
  - Dealer has not yet robbed the pack
  - Deck may still have remaining cards

  ## Returns

  A `GameState` after second_deal with cards_requested tracked.
  """
  def post_second_deal_generator do
    pre_dealer_selection_generator()
    |> StreamData.map(&simulate_second_deal/1)
  end

  @doc """
  Generates a dealer with >6 trump cards after robbing.

  This represents the edge case where the dealer combines their hand with
  the remaining deck and ends up with more than 6 trump cards total.

  ## Returns

  A tuple of `{player, trump_suit}` where player has 7-14 trump cards.
  """
  def dealer_with_excess_trump_generator do
    gen all(
          trump <- trump_suit(),
          trump_count <- StreamData.integer(7..14)
        ) do
      {build_player_with_trump(:north, trump, trump_count), trump}
    end
  end

  @doc """
  Generates a player with killed cards.

  This represents a player who had >6 trump cards after redeal and had to
  kill excess non-point cards.

  ## Returns

  A tuple of `{state, player_position}` where the player has killed cards.
  """
  def player_with_killed_cards_generator do
    gen all(
          trump <- trump_suit(),
          pos <- position(),
          trump_count <- StreamData.integer(7..10)
        ) do
      build_state_with_killed_cards(pos, trump, trump_count)
    end
  end

  # =============================================================================
  # Private Helper Functions for Building Test States
  # =============================================================================

  defp build_pre_dealer_selection_state(%{
         trump_suit: trump,
         dealer_position: dealer,
         dealer_trump_count: dealer_trumps,
         non_dealer_trump_counts: non_dealer_counts
       }) do
    alias Pidro.Core.{GameState, Types}

    positions = [:north, :east, :south, :west]
    non_dealers = positions -- [dealer]

    # Build players
    players =
      positions
      |> Enum.with_index()
      |> Enum.map(fn {pos, _idx} ->
        trump_count =
          if pos == dealer do
            dealer_trumps
          else
            # Get corresponding non-dealer count
            non_dealer_idx = Enum.find_index(non_dealers, &(&1 == pos))
            Enum.at(non_dealer_counts, non_dealer_idx, 0)
          end

        hand = generate_trump_hand(trump, trump_count)

        player = %Types.Player{
          position: pos,
          team: Types.position_to_team(pos),
          hand: hand
        }

        {pos, player}
      end)
      |> Map.new()

    # Create remaining deck (16 cards typical after initial deal)
    remaining_deck = generate_mixed_deck(16)

    # Build game state
    GameState.new()
    |> GameState.update(:phase, :second_deal)
    |> GameState.update(:current_dealer, dealer)
    |> GameState.update(:trump_suit, trump)
    |> GameState.update(:bidding_team, Types.position_to_team(dealer))
    |> GameState.update(:highest_bid, {dealer, 10})
    |> GameState.update(:players, players)
    |> GameState.update(:deck, remaining_deck)
  end

  defp simulate_dealer_rob(state) do
    alias Pidro.Core.GameState

    dealer = state.current_dealer
    dealer_player = Map.get(state.players, dealer)
    remaining_deck = state.deck

    # Dealer combines hand + deck
    dealer_pool = dealer_player.hand ++ remaining_deck
    dealer_pool_size = length(dealer_pool)

    # Dealer selects best 6 (for testing, just take first 6)
    selected = Enum.take(dealer_pool, 6)

    # Update dealer's hand
    updated_players = Map.put(state.players, dealer, %{dealer_player | hand: selected})

    state
    |> GameState.update(:players, updated_players)
    |> GameState.update(:dealer_pool_size, dealer_pool_size)
    |> GameState.update(:deck, [])
  end

  defp simulate_second_deal(state) do
    alias Pidro.Core.GameState

    dealer = state.current_dealer
    positions = [:north, :east, :south, :west]
    non_dealers = positions -- [dealer]

    # Calculate cards requested for each non-dealer
    cards_requested =
      non_dealers
      |> Enum.map(fn pos ->
        player = Map.get(state.players, pos)
        cards_needed = max(0, 6 - length(player.hand))
        {pos, cards_needed}
      end)
      |> Map.new()

    # Deal cards to bring non-dealers to 6
    {updated_players, remaining_deck} =
      Enum.reduce(non_dealers, {state.players, state.deck}, fn pos, {players, deck} ->
        player = Map.get(players, pos)
        cards_needed = Map.get(cards_requested, pos, 0)

        {dealt_cards, new_deck} = Enum.split(deck, cards_needed)
        updated_player = %{player | hand: player.hand ++ dealt_cards}

        {Map.put(players, pos, updated_player), new_deck}
      end)

    state
    |> GameState.update(:players, updated_players)
    |> GameState.update(:deck, remaining_deck)
    |> GameState.update(:cards_requested, cards_requested)
  end

  defp build_player_with_trump(pos, trump_suit, trump_count) do
    alias Pidro.Core.Types

    hand = generate_trump_hand(trump_suit, trump_count)

    %Types.Player{
      position: pos,
      team: Types.position_to_team(pos),
      hand: hand
    }
  end

  defp build_state_with_killed_cards(pos, trump, trump_count) do
    alias Pidro.Core.{GameState, Types, Card}

    # Generate excess trump (more than 6)
    hand = generate_trump_hand(trump, trump_count)

    # Determine what can be killed
    non_point = Card.non_point_trumps(hand, trump)
    excess = trump_count - 6

    # Kill the excess non-point cards
    killed =
      if length(non_point) >= excess do
        Enum.take(non_point, excess)
      else
        # Cannot kill enough - player keeps all (7+ point cards case)
        []
      end

    # Remove killed cards from hand
    final_hand = hand -- killed

    player = %Types.Player{
      position: pos,
      team: Types.position_to_team(pos),
      hand: final_hand
    }

    players =
      Map.new([:north, :east, :south, :west], fn p ->
        if p == pos do
          {p, player}
        else
          {p,
           %Types.Player{
             position: p,
             team: Types.position_to_team(p),
             hand: []
           }}
        end
      end)

    killed_cards = if length(killed) > 0, do: %{pos => killed}, else: %{}

    state =
      GameState.new()
      |> GameState.update(:phase, :playing)
      |> GameState.update(:trump_suit, trump)
      |> GameState.update(:players, players)
      |> GameState.update(:killed_cards, killed_cards)
      |> GameState.update(:current_dealer, :north)
      |> GameState.update(:bidding_team, :north_south)
      |> GameState.update(:highest_bid, {:north, 10})

    {state, pos}
  end

  defp generate_trump_hand(trump_suit, count) do
    # Generate count trump cards with varied ranks
    1..count
    |> Enum.map(fn i ->
      # Cycle through ranks 2-14
      rank = rem(i - 1, 13) + 2
      {rank, trump_suit}
    end)
  end

  defp generate_mixed_deck(count) do
    # Generate a mix of cards for the remaining deck
    all_cards =
      for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades] do
        {rank, suit}
      end

    all_cards
    |> Enum.shuffle()
    |> Enum.take(count)
  end
end
