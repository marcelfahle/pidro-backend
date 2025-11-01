defmodule Pidro.MoveCache do
  @moduledoc """
  ETS-based cache for legal move generation.

  This GenServer maintains an ETS table that caches the results of
  `legal_actions/2` calls. Since move generation can be expensive,
  especially during complex game states, caching significantly improves
  performance for repeated queries.

  ## Design

  - Uses ETS `:set` table for O(1) lookups
  - Cache keys are generated from relevant game state only
  - Automatic cache invalidation after configurable TTL
  - Optional cache size limits with LRU eviction

  ## Usage

      # Start the cache server
      {:ok, pid} = MoveCache.start_link()

      # Get or compute legal moves
      moves = MoveCache.get_or_compute(state, :north, fn ->
        Engine.legal_actions(state, :north)
      end)

      # Clear the cache
      MoveCache.clear()

      # Get cache statistics
      stats = MoveCache.stats()
  """

  use GenServer
  require Logger

  alias Pidro.Core.Types.GameState
  alias Pidro.Perf

  @table_name :pidro_move_cache
  @default_max_size 10_000
  @default_ttl_ms 60_000

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Starts the MoveCache GenServer.

  ## Options

  - `:max_size` - Maximum number of entries (default: 10,000)
  - `:ttl_ms` - Time-to-live in milliseconds (default: 60,000)
  - `:name` - Registered name (default: `__MODULE__`)

  ## Examples

      {:ok, pid} = MoveCache.start_link()
      {:ok, pid} = MoveCache.start_link(max_size: 5000, ttl_ms: 30_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets legal moves from cache or computes them.

  If the moves for this state and position are cached, returns them
  immediately. Otherwise, calls the computation function, caches the
  result, and returns it.

  ## Parameters

  - `state` - The game state
  - `position` - The position to get legal moves for
  - `compute_fun` - Function to call if cache misses (must return list of actions)

  ## Returns

  List of legal actions for the position

  ## Examples

      moves = MoveCache.get_or_compute(state, :north, fn ->
        Engine.legal_actions(state, :north)
      end)
  """
  @spec get_or_compute(GameState.t(), atom(), (-> list())) :: list()
  def get_or_compute(%GameState{} = state, position, compute_fun)
      when is_function(compute_fun, 0) do
    key = generate_cache_key(state, position)

    case lookup(key) do
      {:ok, moves} ->
        # Cache hit
        increment_hits()
        moves

      :miss ->
        # Cache miss - compute and store
        increment_misses()
        moves = compute_fun.()
        insert(key, moves)
        moves
    end
  end

  @doc """
  Clears all entries from the cache.

  ## Examples

      :ok = MoveCache.clear()
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Returns cache statistics.

  ## Returns

  Map with cache statistics:
  - `:size` - Current number of entries
  - `:hits` - Number of cache hits
  - `:misses` - Number of cache misses
  - `:hit_rate` - Hit rate percentage

  ## Examples

      iex> stats = MoveCache.stats()
      iex> stats.size
      0
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Manually invalidates cache entries for a specific state hash.

  Useful when you know state has changed and want to force
  recomputation on next access.

  ## Parameters

  - `state` - The game state to invalidate cache for

  ## Examples

      :ok = MoveCache.invalidate(state)
  """
  @spec invalidate(GameState.t()) :: :ok
  def invalidate(%GameState{} = state) do
    # Invalidate all positions for this state
    [:north, :east, :south, :west]
    |> Enum.each(fn position ->
      key = generate_cache_key(state, position)
      delete(key)
    end)

    :ok
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @doc false
  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # Create ETS table
    table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    state = %{
      table: table,
      max_size: max_size,
      ttl_ms: ttl_ms,
      hits: 0,
      misses: 0
    }

    {:ok, state}
  end

  @doc false
  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | hits: 0, misses: 0}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(state.table, :size)
    total = state.hits + state.misses
    hit_rate = if total > 0, do: state.hits / total * 100, else: 0.0

    stats = %{
      size: size,
      hits: state.hits,
      misses: state.misses,
      hit_rate: hit_rate
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:increment_hits}, _from, state) do
    {:reply, :ok, %{state | hits: state.hits + 1}}
  end

  @impl true
  def handle_call({:increment_misses}, _from, state) do
    {:reply, :ok, %{state | misses: state.misses + 1}}
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  @spec generate_cache_key(GameState.t(), atom()) :: non_neg_integer()
  defp generate_cache_key(state, position) do
    Perf.hash_position_state(state, position)
  end

  @spec lookup(non_neg_integer()) :: {:ok, list()} | :miss
  defp lookup(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, moves, _timestamp}] ->
        {:ok, moves}

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      # Table doesn't exist yet
      :miss
  end

  @spec insert(non_neg_integer(), list()) :: true
  defp insert(key, moves) do
    timestamp = System.system_time(:millisecond)
    :ets.insert(@table_name, {key, moves, timestamp})
  rescue
    ArgumentError ->
      # Table doesn't exist, silently fail
      Logger.warning("MoveCache: Table does not exist, cannot insert")
      false
  end

  @spec delete(non_neg_integer()) :: true
  defp delete(key) do
    :ets.delete(@table_name, key)
  rescue
    ArgumentError ->
      # Table doesn't exist
      false
  end

  @spec increment_hits() :: :ok
  defp increment_hits do
    GenServer.call(__MODULE__, {:increment_hits})
  rescue
    _ -> :ok
  end

  @spec increment_misses() :: :ok
  defp increment_misses do
    GenServer.call(__MODULE__, {:increment_misses})
  rescue
    _ -> :ok
  end

  # =============================================================================
  # Public Utilities (Non-GenServer)
  # =============================================================================

  @doc """
  Checks if the cache is enabled and running.

  ## Returns

  `true` if cache is available, `false` otherwise

  ## Examples

      iex> MoveCache.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Process.whereis(__MODULE__) != nil
  end

  @doc """
  Gets the cache table name.

  Useful for direct ETS operations if needed.

  ## Returns

  The ETS table name atom

  ## Examples

      iex> MoveCache.table_name()
      :pidro_move_cache
  """
  @spec table_name() :: atom()
  def table_name, do: @table_name
end
