# Pidro Engine Performance Benchmarks
#
# Run with: mix run bench/pidro_benchmark.exs
#
# This benchmark suite measures the performance of critical game engine operations.
# Target: All operations should complete in < 1ms for real-time gameplay.

Mix.install([{:benchee, "~> 1.0"}])

# Add the lib directory to the code path
Code.prepend_path("_build/dev/lib/pidro_engine/ebin")

alias Pidro.Core.{Binary, GameState, Types}
alias Pidro.Game.{Engine, Dealing, Bidding}
alias Pidro.Finnish.Scorer
alias Pidro.{Perf, MoveCache}

# =============================================================================
# Setup Helpers
# =============================================================================

defmodule BenchmarkHelpers do
  def create_initial_state do
    state = GameState.new()
    {:ok, state} = Dealing.select_dealer(state)
    state
  end

  def create_bidding_state do
    state = create_initial_state()
    state = Map.put(state, :phase, :bidding)
    state = Map.put(state, :current_turn, :north)
    state
  end

  def create_playing_state do
    state = create_bidding_state()

    # Apply some bids
    {:ok, state} = Bidding.apply_bid(state, :north, 10)
    {:ok, state} = Bidding.apply_pass(state, :east)
    {:ok, state} = Bidding.apply_pass(state, :south)
    {:ok, state} = Bidding.apply_pass(state, :west)

    # Move to playing phase
    state = Map.put(state, :phase, :playing)
    state = Map.put(state, :trump_suit, :hearts)

    # Give north player some cards
    north_player = state.players[:north]
    cards = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
    north_player = Map.put(north_player, :hand, cards)
    players = Map.put(state.players, :north, north_player)
    state = Map.put(state, :players, players)

    state
  end
end

# =============================================================================
# Benchmarks
# =============================================================================

IO.puts("\n=== Pidro Engine Performance Benchmarks ===\n")

# Start the MoveCache if needed for caching benchmarks
{:ok, _pid} = MoveCache.start_link()

Benchee.run(
  %{
    # Core Operations
    "GameState.new/0" => fn -> GameState.new() end,
    "Dealing.select_dealer/1" => fn ->
      state = GameState.new()
      Dealing.select_dealer(state)
    end,

    # Binary Encoding
    "Binary.encode_card/1" => fn -> Binary.encode_card({14, :hearts}) end,
    "Binary.decode_card/1" => fn ->
      binary = Binary.encode_card({14, :hearts})
      Binary.decode_card(binary)
    end,
    "Binary.encode_hand/1 (6 cards)" => fn ->
      hand = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
      Binary.encode_hand(hand)
    end,
    "Binary.decode_hand/1 (6 cards)" => fn ->
      hand = [{14, :hearts}, {13, :hearts}, {12, :hearts}, {11, :hearts}, {10, :hearts}, {9, :hearts}]
      binary = Binary.encode_hand(hand)
      Binary.decode_hand(binary)
    end,
    "Binary.to_binary/1 (full state)" => fn ->
      state = BenchmarkHelpers.create_initial_state()
      Binary.to_binary(state)
    end,
    "Binary.from_binary/1 (full state)" => fn ->
      state = BenchmarkHelpers.create_initial_state()
      binary = Binary.to_binary(state)
      Binary.from_binary(binary)
    end,

    # Performance Utilities
    "Perf.hash_state/1" => fn ->
      state = BenchmarkHelpers.create_initial_state()
      Perf.hash_state(state)
    end,
    "Perf.states_equal?/2 (equal)" => fn ->
      state = BenchmarkHelpers.create_initial_state()
      Perf.states_equal?(state, state)
    end,
    "Perf.cache_key_for_moves/2" => fn ->
      state = BenchmarkHelpers.create_playing_state()
      Perf.cache_key_for_moves(state, :north)
    end,

    # Game Engine Operations
    "Engine.legal_actions/2 (bidding)" => fn ->
      state = BenchmarkHelpers.create_bidding_state()
      Engine.legal_actions(state, :north)
    end,
    "Engine.apply_action/3 (bid)" => fn ->
      state = BenchmarkHelpers.create_bidding_state()
      Engine.apply_action(state, :north, {:bid, 10})
    end,
    "Engine.apply_action/3 (pass)" => fn ->
      state = BenchmarkHelpers.create_bidding_state()
      Engine.apply_action(state, :north, :pass)
    end,

    # Move Cache Operations
    "MoveCache.get_or_compute/3 (cache miss)" => fn ->
      MoveCache.clear()
      state = BenchmarkHelpers.create_playing_state()
      MoveCache.get_or_compute(state, :north, fn ->
        Engine.legal_actions(state, :north)
      end)
    end,
    "MoveCache.get_or_compute/3 (cache hit)" => fn ->
      state = BenchmarkHelpers.create_playing_state()
      # Prime the cache
      MoveCache.get_or_compute(state, :north, fn ->
        Engine.legal_actions(state, :north)
      end)
      # Now benchmark the hit
      MoveCache.get_or_compute(state, :north, fn ->
        Engine.legal_actions(state, :north)
      end)
    end
  },
  time: 5,
  memory_time: 2,
  warmup: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

# =============================================================================
# Full Game Simulation Benchmark
# =============================================================================

IO.puts("\n=== Full Hand Simulation ===\n")

Benchee.run(
  %{
    "Complete hand (dealer selection through bidding)" => fn ->
      state = GameState.new()
      {:ok, state} = Dealing.select_dealer(state)
      state = Map.put(state, :phase, :bidding)
      state = Map.put(state, :current_turn, :north)
      {:ok, state} = Bidding.apply_bid(state, :north, 10)
      {:ok, state} = Bidding.apply_pass(state, :east)
      {:ok, state} = Bidding.apply_pass(state, :south)
      {:ok, state} = Bidding.apply_pass(state, :west)
      state
    end
  },
  time: 5,
  memory_time: 2,
  warmup: 2
)

IO.puts("\n=== Benchmark Complete ===\n")
IO.puts("Target: Operations should be < 1ms (1,000 microseconds)")
IO.puts("Full game simulation should be < 100ms\n")

# Display cache statistics
stats = MoveCache.stats()
IO.puts("Cache Statistics:")
IO.puts("  Hits: #{stats.hits}")
IO.puts("  Misses: #{stats.misses}")
IO.puts("  Hit Rate: #{Float.round(stats.hit_rate, 2)}%")
IO.puts("  Current Size: #{stats.size}")
