defmodule Pidro.IEx do
  @moduledoc """
  IEx helpers for interactive development and testing of the Pidro game engine.

  This module provides convenient functions for visualizing game state, exploring
  legal actions, and playing demo games directly from the IEx console.

  ## Quick Start

      iex> import Pidro.IEx
      iex> state = new_game()
      iex> pretty_print(state)
      # Shows formatted game state with ASCII cards
      iex> show_legal_actions(state, :north)
      # Shows available actions for North
      iex> {:ok, state} = step(state, :north, {:bid, 10})
      # Apply action and see updated state

  ## Demo Games

      iex> demo_game()
      # Runs a full automated demo game

  ## Available Functions

  - `pretty_print/1` - Visualize game state in a readable format
  - `show_legal_actions/2` - Display available actions for a position
  - `step/3` - Apply an action and pretty print result
  - `new_game/0` - Create a new game with dealer selection complete
  - `demo_game/0` - Run a sample game demonstration
  """

  alias Pidro.Core.{Types, Card, GameState, Deck}
  alias Pidro.Game.{Engine, Dealing}

  import IO.ANSI

  # =============================================================================
  # Main Helper Functions
  # =============================================================================

  @doc """
  Creates a new game with dealer selection already complete.

  This is the recommended starting point for interactive play, as it skips
  the automatic dealer selection step and puts you right into a ready-to-play state.

  ## Returns

  A new `GameState.t()` with:
  - Dealer selected
  - Phase set to `:dealing`
  - Deck shuffled and ready
  - All players initialized

  ## Examples

      iex> state = Pidro.IEx.new_game()
      iex> state.current_dealer in [:north, :east, :south, :west]
      true
      iex> state.phase
      :bidding
  """
  @spec new_game() :: Types.GameState.t()
  def new_game do
    state = GameState.new()

    # Create a shuffled deck
    deck = Deck.new()

    # Set the deck in state
    state = GameState.update(state, :deck, deck.cards)

    # Select dealer
    {:ok, state} = Dealing.select_dealer(state)

    # Transition to dealing phase
    state = GameState.update(state, :phase, :dealing)

    # Auto-deal initial cards
    {:ok, state} = Dealing.deal_initial(state)

    # Transition to bidding phase (ready for player interaction)
    state = GameState.update(state, :phase, :bidding)

    state
  end

  @doc """
  Pretty prints the game state in a human-readable format with ASCII cards.

  Displays:
  - Current phase and hand number
  - Dealer and current turn
  - Trump suit (if declared)
  - Scores (hand and cumulative)
  - Each player's hand with ASCII card representations
  - Current trick (if in playing phase)
  - Bidding history

  ## Parameters

  - `state` - The game state to display

  ## Examples

      iex> state = Pidro.IEx.new_game()
      iex> Pidro.IEx.pretty_print(state)
      # Outputs formatted game state
      :ok
  """
  @spec pretty_print(Types.GameState.t()) :: :ok
  def pretty_print(%Types.GameState{} = state) do
    IO.puts("\n#{bright()}#{blue()}╔═══════════════════════════════════════════════════════════╗#{reset()}")
    IO.puts("#{bright()}#{blue()}║#{reset()}              #{bright()}PIDRO - Finnish Variant#{reset()}                 #{bright()}#{blue()}║#{reset()}")
    IO.puts("#{bright()}#{blue()}╚═══════════════════════════════════════════════════════════╝#{reset()}\n")

    print_game_info(state)
    print_scores(state)
    print_bidding_info(state)
    print_trump_info(state)
    print_players(state)
    print_current_trick(state)
    print_game_status(state)

    :ok
  end

  @doc """
  Shows all legal actions available for a given position in the current game state.

  This is useful for:
  - Understanding what moves are available
  - Validating game logic
  - Helping players decide their next move

  ## Parameters

  - `state` - The current game state
  - `position` - The position to check (`:north`, `:east`, `:south`, or `:west`)

  ## Returns

  A list of legal actions (also prints them to the console)

  ## Examples

      iex> state = Pidro.IEx.new_game()
      iex> actions = Pidro.IEx.show_legal_actions(state, :north)
      iex> is_list(actions)
      true
  """
  @spec show_legal_actions(Types.GameState.t(), Types.position()) :: [Types.action()]
  def show_legal_actions(%Types.GameState{} = state, position) do
    actions = Engine.legal_actions(state, position)

    IO.puts("\n#{bright()}#{cyan()}Legal Actions for #{format_position(position)}:#{reset()}")

    if Enum.empty?(actions) do
      IO.puts("  #{red()}No legal actions available#{reset()}")
    else
      Enum.with_index(actions, 1)
      |> Enum.each(fn {action, idx} ->
        IO.puts("  #{green()}#{idx}.#{reset()} #{format_action(action, state)}")
      end)
    end

    IO.puts("")
    actions
  end

  @doc """
  Applies an action to the game state and pretty prints the result.

  This is the main function for interactive play. It:
  1. Applies the action
  2. Shows any errors if the action is invalid
  3. Pretty prints the new state on success

  ## Parameters

  - `state` - The current game state
  - `position` - The position making the action
  - `action` - The action to perform

  ## Returns

  - `{:ok, new_state}` - If the action was successful
  - `{:error, reason}` - If the action was invalid

  ## Examples

      iex> state = Pidro.IEx.new_game()
      iex> {:ok, new_state} = Pidro.IEx.step(state, :north, {:bid, 10})
      iex> new_state.phase
      :bidding

      iex> state = Pidro.IEx.new_game()
      iex> {:error, _reason} = Pidro.IEx.step(state, :south, {:play_card, {14, :hearts}})
  """
  @spec step(Types.GameState.t(), Types.position(), Types.action()) ::
          {:ok, Types.GameState.t()} | {:error, any()}
  def step(%Types.GameState{} = state, position, action) do
    IO.puts("\n#{bright()}#{yellow()}► #{format_position(position)} performs: #{format_action(action, state)}#{reset()}\n")

    case Engine.apply_action(state, position, action) do
      {:ok, new_state} ->
        IO.puts("#{green()}✓ Action successful!#{reset()}\n")
        pretty_print(new_state)
        {:ok, new_state}

      {:error, reason} ->
        IO.puts("#{red()}✗ Error: #{format_error(reason)}#{reset()}\n")
        {:error, reason}
    end
  end

  @doc """
  Runs a demonstration game with automated moves.

  This function creates a new game and plays through several phases automatically,
  showing the game state at each step. It's useful for:
  - Understanding game flow
  - Testing game logic
  - Demonstrating the game to others

  The demo plays through:
  1. Dealer selection
  2. Initial deal
  3. Bidding round
  4. Trump declaration
  5. First few tricks

  ## Returns

  The final game state after the demo

  ## Examples

      iex> final_state = Pidro.IEx.demo_game()
      # Outputs each step of the game with pretty printed states
  """
  @spec demo_game() :: Types.GameState.t()
  def demo_game do
    IO.puts("\n#{bright()}#{magenta()}═══════════════════════════════════════════════════════════#{reset()}")
    IO.puts("#{bright()}#{magenta()}         PIDRO DEMONSTRATION GAME#{reset()}")
    IO.puts("#{bright()}#{magenta()}═══════════════════════════════════════════════════════════#{reset()}\n")

    # Start new game
    state = new_game()

    IO.puts("#{bright()}Step 1: Game Created and Initial Deal Complete#{reset()}")
    pretty_print(state)
    pause()

    # Bidding phase - simulate bids
    state = demo_bidding(state)
    pause()

    # Trump declaration
    state = demo_trump_declaration(state)
    pause()

    # Play a few tricks if we get to playing phase
    state = demo_play_tricks(state)

    IO.puts("\n#{bright()}#{magenta()}═══════════════════════════════════════════════════════════#{reset()}")
    IO.puts("#{bright()}#{magenta()}         DEMO COMPLETE#{reset()}")
    IO.puts("#{bright()}#{magenta()}═══════════════════════════════════════════════════════════#{reset()}\n")

    state
  end

  # =============================================================================
  # Pretty Printing Helpers
  # =============================================================================

  defp print_game_info(%Types.GameState{} = state) do
    IO.puts("#{bright()}Phase:#{reset()}       #{format_phase(state.phase)}")
    IO.puts("#{bright()}Hand:#{reset()}        ##{state.hand_number}")

    if state.current_dealer do
      IO.puts("#{bright()}Dealer:#{reset()}      #{format_position(state.current_dealer)}")
    end

    if state.current_turn do
      IO.puts("#{bright()}Turn:#{reset()}        #{format_position(state.current_turn)}")
    end

    IO.puts("")
  end

  defp print_scores(%Types.GameState{} = state) do
    IO.puts("#{bright()}#{cyan()}Scores:#{reset()}")

    ns_hand = state.hand_points.north_south
    ew_hand = state.hand_points.east_west
    ns_total = state.cumulative_scores.north_south
    ew_total = state.cumulative_scores.east_west

    IO.puts("  #{format_team(:north_south)}: #{ns_hand} this hand, #{bright()}#{ns_total} total#{reset()}")
    IO.puts("  #{format_team(:east_west)}: #{ew_hand} this hand, #{bright()}#{ew_total} total#{reset()}")
    IO.puts("")
  end

  defp print_bidding_info(%Types.GameState{bids: bids, highest_bid: highest_bid}) when length(bids) > 0 do
    IO.puts("#{bright()}#{cyan()}Bidding:#{reset()}")

    if highest_bid do
      {pos, amount} = highest_bid
      IO.puts("  #{green()}Highest Bid:#{reset()} #{amount} by #{format_position(pos)}")
    end

    if length(bids) > 0 do
      IO.puts("  #{bright()}History:#{reset()}")
      Enum.each(bids, fn bid ->
        amount_str = if bid.amount == :pass, do: "#{red()}PASS#{reset()}", else: "#{bid.amount}"
        IO.puts("    #{format_position(bid.position)}: #{amount_str}")
      end)
    end

    IO.puts("")
  end

  defp print_bidding_info(_state), do: :ok

  defp print_trump_info(%Types.GameState{trump_suit: trump_suit}) when trump_suit != nil do
    IO.puts("#{bright()}#{cyan()}Trump:#{reset()}       #{format_suit(trump_suit)}")
    IO.puts("")
  end

  defp print_trump_info(_state), do: :ok

  defp print_players(%Types.GameState{players: players, trump_suit: trump_suit}) do
    IO.puts("#{bright()}#{cyan()}Players:#{reset()}")

    # Print in order: North, East, South, West
    [:north, :east, :south, :west]
    |> Enum.each(fn pos ->
      player = Map.get(players, pos)
      print_player(player, trump_suit)
    end)

    IO.puts("")
  end

  defp print_player(%Types.Player{} = player, trump_suit) do
    status = if player.eliminated?, do: " #{red()}[COLD]#{reset()}", else: ""
    IO.puts("\n  #{bright()}#{format_position(player.position)}#{reset()} (#{format_team(player.team)})#{status}")

    if player.eliminated? and length(player.revealed_cards) > 0 do
      IO.puts("    Revealed: #{format_cards(player.revealed_cards, trump_suit)}")
    end

    if length(player.hand) > 0 do
      IO.puts("    Hand: #{format_cards(player.hand, trump_suit)}")
    else
      IO.puts("    Hand: #{red()}Empty#{reset()}")
    end

    if player.tricks_won > 0 do
      IO.puts("    Tricks Won: #{player.tricks_won}")
    end
  end

  defp print_current_trick(%Types.GameState{current_trick: nil}), do: :ok

  defp print_current_trick(%Types.GameState{current_trick: trick, trump_suit: trump_suit}) do
    IO.puts("#{bright()}#{cyan()}Current Trick ##{trick.number}:#{reset()}")
    IO.puts("  Leader: #{format_position(trick.leader)}")

    if length(trick.plays) > 0 do
      IO.puts("  Plays:")
      Enum.each(trick.plays, fn {pos, card} ->
        IO.puts("    #{format_position(pos)}: #{format_card(card, trump_suit)}")
      end)
    else
      IO.puts("  No plays yet")
    end

    IO.puts("")
  end

  defp print_game_status(%Types.GameState{phase: :complete, winner: winner}) do
    IO.puts("#{bright()}#{green()}╔═══════════════════════════════════════════════════════════╗#{reset()}")
    IO.puts("#{bright()}#{green()}║                    GAME OVER!                             ║#{reset()}")
    IO.puts("#{bright()}#{green()}║          Winner: #{String.pad_trailing(format_team(winner), 30)}           ║#{reset()}")
    IO.puts("#{bright()}#{green()}╚═══════════════════════════════════════════════════════════╝#{reset()}\n")
  end

  defp print_game_status(_state), do: :ok

  # =============================================================================
  # Card Formatting with ASCII Art
  # =============================================================================

  defp format_cards(cards, trump_suit) do
    cards
    |> Enum.map(&format_card(&1, trump_suit))
    |> Enum.join("  ")
  end

  defp format_card({rank, suit}, trump_suit) do
    is_trump = Card.is_trump?({rank, suit}, trump_suit || :hearts)
    points = if trump_suit, do: Card.point_value({rank, suit}, trump_suit), else: 0

    rank_str = format_rank(rank)
    suit_str = format_suit_symbol(suit)
    color = suit_color(suit)

    card_str = "#{rank_str}#{suit_str}"

    points_str = if points > 0, do: "#{yellow()}[#{points}]#{reset()}", else: ""
    trump_str = if is_trump, do: "#{magenta()}★#{reset()}", else: " "

    "#{color}#{card_str}#{reset()}#{points_str}#{trump_str}"
  end

  defp format_rank(14), do: "A"
  defp format_rank(13), do: "K"
  defp format_rank(12), do: "Q"
  defp format_rank(11), do: "J"
  defp format_rank(10), do: "10"
  defp format_rank(n) when n >= 2 and n <= 9, do: "#{n}"

  defp format_suit_symbol(:hearts), do: "♥"
  defp format_suit_symbol(:diamonds), do: "♦"
  defp format_suit_symbol(:clubs), do: "♣"
  defp format_suit_symbol(:spades), do: "♠"

  defp suit_color(:hearts), do: red()
  defp suit_color(:diamonds), do: red()
  defp suit_color(:clubs), do: white()
  defp suit_color(:spades), do: white()

  defp format_suit(:hearts), do: "#{red()}Hearts ♥#{reset()}"
  defp format_suit(:diamonds), do: "#{red()}Diamonds ♦#{reset()}"
  defp format_suit(:clubs), do: "#{white()}Clubs ♣#{reset()}"
  defp format_suit(:spades), do: "#{white()}Spades ♠#{reset()}"

  defp format_position(:north), do: "#{cyan()}North#{reset()}"
  defp format_position(:east), do: "#{cyan()}East#{reset()}"
  defp format_position(:south), do: "#{cyan()}South#{reset()}"
  defp format_position(:west), do: "#{cyan()}West#{reset()}"

  defp format_team(:north_south), do: "#{bright()}North/South#{reset()}"
  defp format_team(:east_west), do: "#{bright()}East/West#{reset()}"

  defp format_phase(:dealer_selection), do: "#{yellow()}Dealer Selection#{reset()}"
  defp format_phase(:dealing), do: "#{yellow()}Dealing#{reset()}"
  defp format_phase(:bidding), do: "#{yellow()}Bidding#{reset()}"
  defp format_phase(:declaring), do: "#{yellow()}Trump Declaration#{reset()}"
  defp format_phase(:discarding), do: "#{yellow()}Discarding#{reset()}"
  defp format_phase(:second_deal), do: "#{yellow()}Second Deal#{reset()}"
  defp format_phase(:playing), do: "#{green()}Playing#{reset()}"
  defp format_phase(:scoring), do: "#{yellow()}Scoring#{reset()}"
  defp format_phase(:hand_complete), do: "#{yellow()}Hand Complete#{reset()}"
  defp format_phase(:complete), do: "#{red()}Complete#{reset()}"
  defp format_phase(phase), do: "#{inspect(phase)}"

  defp format_action({:bid, amount}, _state), do: "#{green()}Bid #{amount}#{reset()}"
  defp format_action(:pass, _state), do: "#{red()}Pass#{reset()}"
  defp format_action({:declare_trump, suit}, _state), do: "#{yellow()}Declare #{format_suit(suit)}#{reset()}"
  defp format_action({:play_card, card}, state), do: "#{cyan()}Play #{format_card(card, state.trump_suit)}#{reset()}"
  defp format_action({:discard, cards}, state), do: "Discard #{length(cards)} cards: #{format_cards(cards, state.trump_suit)}"
  defp format_action({:select_hand, cards}, state) when is_list(cards), do: "Select hand: #{format_cards(cards, state.trump_suit)}"
  defp format_action({:select_hand, _}, _state), do: "Select 6 cards for final hand"
  defp format_action(action, _state), do: "#{inspect(action)}"

  defp format_error({:not_your_turn, turn}), do: "Not your turn (current turn: #{format_position(turn)})"
  defp format_error({:player_eliminated, pos}), do: "Player #{format_position(pos)} is eliminated"
  defp format_error({:invalid_action, action, phase}), do: "Invalid action #{inspect(action)} for phase #{format_phase(phase)}"
  defp format_error(:game_already_complete), do: "Game is already complete"
  defp format_error(reason), do: "#{inspect(reason)}"

  # =============================================================================
  # Demo Game Helpers
  # =============================================================================

  defp demo_bidding(%Types.GameState{phase: :bidding} = state) do
    IO.puts("\n#{bright()}Step 2: Bidding Round#{reset()}")

    # Get turn order starting from left of dealer
    positions = get_bidding_order(state.current_dealer)

    # Simulate bids
    state = Enum.reduce(positions, state, fn pos, acc_state ->
      # Get legal actions
      actions = Engine.legal_actions(acc_state, pos)

      # Make a random bid (favor bidding over passing early)
      action = if length(actions) > 2 and :rand.uniform(10) > 3 do
        # Pick a random bid (not pass)
        bid_actions = Enum.filter(actions, fn
          {:bid, _} -> true
          _ -> false
        end)
        Enum.random(bid_actions || [hd(actions)])
      else
        # Pass or pick first action
        hd(actions)
      end

      IO.puts("  #{format_position(pos)}: #{format_action(action, acc_state)}")

      case Engine.apply_action(acc_state, pos, action) do
        {:ok, new_state} -> new_state
        {:error, _} -> acc_state
      end
    end)

    pretty_print(state)
    state
  end

  defp demo_bidding(state), do: state

  defp demo_trump_declaration(%Types.GameState{phase: :declaring, highest_bid: {pos, _}} = state) do
    IO.puts("\n#{bright()}Step 3: Trump Declaration#{reset()}")

    # Winner declares trump - pick a random suit
    suit = Enum.random([:hearts, :diamonds, :clubs, :spades])
    action = {:declare_trump, suit}

    IO.puts("  #{format_position(pos)}: #{format_action(action, state)}")

    case Engine.apply_action(state, pos, action) do
      {:ok, new_state} ->
        pretty_print(new_state)
        new_state

      {:error, _} ->
        state
    end
  end

  defp demo_trump_declaration(state), do: state

  defp demo_play_tricks(%Types.GameState{phase: :playing} = state) do
    IO.puts("\n#{bright()}Step 4: Playing Tricks#{reset()}")

    # Play a few tricks (max 3 for demo)
    play_n_tricks(state, 3)
  end

  defp demo_play_tricks(state), do: state

  defp play_n_tricks(state, 0), do: state

  defp play_n_tricks(%Types.GameState{phase: :playing} = state, n) do
    # Play one complete trick
    state = play_one_trick(state)

    if state.phase == :playing do
      play_n_tricks(state, n - 1)
    else
      state
    end
  end

  defp play_n_tricks(state, _n), do: state

  defp play_one_trick(%Types.GameState{phase: :playing, current_turn: turn} = state) when turn != nil do
    # Get legal actions for current player
    actions = Engine.legal_actions(state, turn)

    if Enum.empty?(actions) do
      state
    else
      # Pick a random valid card to play
      action = Enum.random(actions)

      IO.puts("  #{format_position(turn)}: #{format_action(action, state)}")

      case Engine.apply_action(state, turn, action) do
        {:ok, new_state} ->
          # If trick is complete, show it
          if new_state.current_trick == nil and state.current_trick != nil do
            IO.puts("    #{green()}Trick won!#{reset()}")
          end

          # Continue playing this trick if still in playing phase
          if new_state.phase == :playing and new_state.current_trick != nil do
            play_one_trick(new_state)
          else
            new_state
          end

        {:error, _reason} ->
          state
      end
    end
  end

  defp play_one_trick(state), do: state

  defp get_bidding_order(dealer) do
    first = Types.next_position(dealer)
    [
      first,
      Types.next_position(first),
      Types.next_position(Types.next_position(first)),
      Types.next_position(Types.next_position(Types.next_position(first)))
    ]
  end

  defp pause do
    IO.puts("\n#{faint()}[Press Enter to continue]#{reset()}")
    IO.gets("")
  end
end
