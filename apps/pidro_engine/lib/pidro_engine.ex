defmodule PidroEngine do
  @moduledoc """
  Pidro Engine - A pure functional Finnish Pidro card game engine.

  This is the main entry point for the Pidro game engine. The engine provides a complete
  implementation of the Finnish variant of Pidro with event sourcing, comprehensive
  property-based testing, and both functional and OTP APIs.

  ## Features

  - **Pure Functional Core** - Immutable game state, deterministic logic
  - **Event Sourcing** - Complete game replay, undo/redo support
  - **Finnish Variant** - Full implementation including redeal mechanics and kill rules
  - **Property-Based Testing** - 157 properties ensuring correctness
  - **Interactive Development** - Rich IEx helpers for playing games
  - **OTP Integration** - GenServer wrapper ready for Phoenix
  - **Performance Optimized** - Move caching, binary encoding, fast hashing

  ## Quick Start

  ### Interactive Play (IEx)

      # Start IEx
      iex -S mix

      # Import helpers
      import Pidro.IEx

      # Create and play a game
      state = new_game()
      pretty_print(state)
      show_legal_actions(state, :west)
      {:ok, state} = step(state, :west, {:bid, 10})

      # Run automated demo
      demo_game()

  ### Functional API

      alias Pidro.Game.Engine

      # Create a new game
      {:ok, state} = Engine.new_game()

      # Get legal actions
      actions = Engine.legal_actions(state, :north)

      # Apply an action
      {:ok, new_state} = Engine.apply_action(state, :north, {:bid, 8})

  ### OTP Server API

      # Start a game server
      {:ok, pid} = Pidro.Supervisor.start_game("game-123")

      # Apply actions
      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 8})

      # Get state
      state = Pidro.Server.get_state(pid)

  ## Architecture

  The engine is organized in layers:

  - `Pidro.Core.*` - Core types and data structures
  - `Pidro.Game.*` - Game engine and state machine
  - `Pidro.Finnish.*` - Finnish variant-specific rules
  - `Pidro.Server` - GenServer wrapper (OTP layer)
  - `Pidro.Supervisor` - Supervision tree
  - Utilities - `Pidro.IEx`, `Pidro.Notation`, `Pidro.Perf`

  ## Game Flow

  A Finnish Pidro game follows this sequence:

  1. **Dealer Selection** - Cut cards to select dealer
  2. **Initial Deal** - 9 cards to each player
  3. **Bidding** - Players bid 6-14 or pass
  4. **Trump Declaration** - Bid winner declares trump
  5. **Discard** - Non-trump cards automatically discarded
  6. **Second Deal** - Players dealt to 6 cards
  7. **Dealer Rob** - Dealer takes remaining deck, selects best 6
  8. **Kill Rule** - Players with >6 trump must discard non-point cards
  9. **Playing** - Tricks played (trump cards only)
  10. **Scoring** - Points tallied, bid checked
  11. **Next Hand** - Dealer rotates, repeat until 62 points

  ## Key Concepts

  ### Cards

  Cards are `{rank, suit}` tuples:
  - Rank: 2-14 (2-10, Jack=11, Queen=12, King=13, Ace=14)
  - Suit: `:hearts`, `:diamonds`, `:clubs`, `:spades`

  ### Trump Ranking

  A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right-5 > Wrong-5 > 4 > 3 > 2

  ### Wrong 5 Rule

  The 5 of the same-color suit is trump:
  - Hearts trump → 5 of diamonds is trump
  - Clubs trump → 5 of spades is trump

  ### Point Cards (14 points total)

  - Ace: 1 point
  - Jack: 1 point
  - 10: 1 point
  - Right 5: 5 points
  - Wrong 5: 5 points
  - 2: 1 point

  ## Documentation

  - [Getting Started Guide](guides/getting_started.html)
  - [Game Rules](guides/game_rules.html)
  - [Architecture](guides/architecture.html)
  - [Property Testing](guides/property_testing.html)
  - [Event Sourcing](guides/event_sourcing.html)

  ## Examples

      # Create a game
      {:ok, state} = Pidro.Game.Engine.new_game()

      # Check phase
      state.phase  # => :bidding

      # See whose turn it is
      state.current_turn  # => :west (left of dealer)

      # Get legal actions
      Pidro.Game.Engine.legal_actions(state, :west)
      # => [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]

      # Make a bid
      {:ok, state} = Pidro.Game.Engine.apply_action(state, :west, {:bid, 10})

      # Continue playing...
      {:ok, state} = Pidro.Game.Engine.apply_action(state, :north, :pass)

  ## Testing

  The engine has comprehensive test coverage:

  - **516 tests** (375 unit + 141 property)
  - **157 properties** testing game invariants
  - **76 doctests** ensuring examples work
  - **Zero failures** (production ready)

  Run tests:

      mix test              # All tests
      mix dialyzer          # Type checking
      mix credo --strict    # Code quality

  ## Performance

  - Card operations: < 1μs
  - State hashing: < 10μs
  - Move generation: 2x+ speedup with cache
  - Full hand: ~50ms
  - Event replay: ~100ms for complete game

  Benchmark:

      mix run bench/pidro_benchmark.exs

  ## See Also

  - `Pidro.Game.Engine` - Main game engine API
  - `Pidro.Core.Types` - Type definitions
  - `Pidro.Server` - OTP GenServer wrapper
  - `Pidro.IEx` - Interactive helpers
  """

  @doc """
  Returns the current version of the Pidro engine.

  ## Examples

      iex> PidroEngine.version()
      "0.1.0"

  """
  def version do
    Application.spec(:pidro_engine, :vsn) |> to_string()
  end

  @doc """
  Returns a summary of the engine's capabilities.

  ## Examples

      iex> info = PidroEngine.info()
      iex> info.variant
      :finnish
      iex> info.version
      "0.1.0"

  """
  def info do
    %{
      name: "Pidro Engine",
      variant: :finnish,
      version: version(),
      features: [
        :event_sourcing,
        :property_based_testing,
        :interactive_development,
        :otp_integration,
        :performance_optimized
      ],
      phases: [
        :dealer_selection,
        :dealing,
        :bidding,
        :declaring,
        :discarding,
        :second_deal,
        :playing,
        :scoring,
        :complete
      ]
    }
  end
end
