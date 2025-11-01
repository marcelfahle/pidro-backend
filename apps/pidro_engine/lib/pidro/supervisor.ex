defmodule Pidro.Supervisor do
  @moduledoc """
  Main supervisor for the Pidro game engine application.

  Note: Unused variable warnings (like `pid` in start_game/1) are intentional
  to maintain clear pattern matching in result tuples.

  This supervisor manages the core OTP infrastructure for running Pidro games:
  - MoveCache ETS table for caching legal moves
  - Optional Registry for game process lookup
  - Dynamic supervisor for game server processes

  ## Supervision Tree

      Pidro.Supervisor
      ├── Pidro.MoveCache (ETS table)
      ├── Registry (optional, for game lookup by ID)
      └── DynamicSupervisor (for game server processes)

  ## Usage

      # Start the supervisor (usually done by application)
      {:ok, pid} = Pidro.Supervisor.start_link()

      # Start a game server under supervision
      {:ok, game_pid} = Pidro.Supervisor.start_game(game_id: "game_123")

      # Start a game with registry
      {:ok, game_pid} = Pidro.Supervisor.start_game(
        game_id: "game_123",
        register: true
      )

      # Look up a game by ID
      case Pidro.Supervisor.lookup_game("game_123") do
        {:ok, pid} -> # Game found
        {:error, :not_found} -> # Game not found
      end

      # Stop a game
      :ok = Pidro.Supervisor.stop_game(game_pid)

  ## Configuration

  The supervisor can be configured via application config:

      config :pidro_engine,
        enable_registry: true,
        enable_cache: true

  ## Telemetry

  The supervisor emits telemetry events for monitoring:
  - `[:pidro, :supervisor, :game, :start]` - When a game starts
  - `[:pidro, :supervisor, :game, :stop]` - When a game stops
  """

  use Supervisor

  @doc """
  Starts the Pidro supervisor.

  ## Options

  - `:name` - The name to register the supervisor under (default: `Pidro.Supervisor`)
  - `:enable_registry` - Whether to start the registry (default: `true`)
  - `:enable_cache` - Whether to start the move cache (default: `true`)

  ## Examples

      {:ok, pid} = Pidro.Supervisor.start_link()
      {:ok, pid} = Pidro.Supervisor.start_link(name: MyApp.PidroSupervisor)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new game server under the dynamic supervisor.

  ## Options

  - `:game_id` - Optional identifier for the game
  - `:register` - Whether to register the game in the registry (default: `false`)
  - `:telemetry` - Whether to enable telemetry (default: `true`)
  - `:initial_state` - Optional initial game state

  ## Returns

  - `{:ok, pid}` if the game was started successfully
  - `{:error, reason}` if the game could not be started

  ## Examples

      # Start a simple game
      {:ok, pid} = Pidro.Supervisor.start_game()

      # Start with game ID and registry
      {:ok, pid} = Pidro.Supervisor.start_game(
        game_id: "game_123",
        register: true
      )
  """
  @spec start_game(keyword()) :: DynamicSupervisor.on_start_child()
  def start_game(opts \\ []) do
    game_id = Keyword.get(opts, :game_id)
    register? = Keyword.get(opts, :register, false)

    child_opts =
      if register? and game_id do
        via_tuple = {:via, Registry, {Pidro.Registry, game_id}}
        Keyword.put(opts, :name, via_tuple)
      else
        opts
      end

    case DynamicSupervisor.start_child(Pidro.GameSupervisor, {Pidro.Server, child_opts}) do
      {:ok, _pid} = result ->
        if Code.ensure_loaded?(:telemetry) do
          :telemetry.execute([:pidro, :supervisor, :game, :start], %{}, %{game_id: game_id})
        end

        result

      error ->
        error
    end
  end

  @doc """
  Stops a game server.

  ## Parameters

  - `pid` - The PID of the game server to stop

  ## Returns

  `:ok` or `{:error, :not_found}` if the process doesn't exist

  ## Examples

      :ok = Pidro.Supervisor.stop_game(game_pid)
  """
  @spec stop_game(pid()) :: :ok | {:error, :not_found}
  def stop_game(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(Pidro.GameSupervisor, pid) do
      :ok ->
        if Code.ensure_loaded?(:telemetry) do
          :telemetry.execute([:pidro, :supervisor, :game, :stop], %{}, %{})
        end

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up a game by its ID in the registry.

  ## Parameters

  - `game_id` - The game ID to look up

  ## Returns

  - `{:ok, pid}` if the game was found
  - `{:error, :not_found}` if the game doesn't exist
  - `{:error, :registry_not_enabled}` if registry is not enabled

  ## Examples

      case Pidro.Supervisor.lookup_game("game_123") do
        {:ok, pid} -> Pidro.Server.get_state(pid)
        {:error, :not_found} -> IO.puts("Game not found")
      end
  """
  @spec lookup_game(String.t()) :: {:ok, pid()} | {:error, :not_found | :registry_not_enabled}
  def lookup_game(game_id) do
    case Registry.lookup(Pidro.Registry, game_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :registry_not_enabled}
  end

  @doc """
  Lists all currently running games.

  ## Returns

  List of `{game_id, pid}` tuples for all registered games.

  ## Examples

      games = Pidro.Supervisor.list_games()
      Enum.each(games, fn {game_id, pid} ->
        IO.puts("Game \#{game_id}: \#{inspect(pid)}")
      end)
  """
  @spec list_games() :: [{String.t(), pid()}]
  def list_games do
    Registry.select(Pidro.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Gets the count of currently running games.

  ## Returns

  The number of games being managed by the dynamic supervisor.

  ## Examples

      count = Pidro.Supervisor.game_count()
      IO.puts("Currently running \#{count} games")
  """
  @spec game_count() :: non_neg_integer()
  def game_count do
    DynamicSupervisor.count_children(Pidro.GameSupervisor).active
  end

  # Supervisor Callbacks

  @impl true
  def init(opts) do
    enable_registry? = Keyword.get(opts, :enable_registry, true)
    enable_cache? = Keyword.get(opts, :enable_cache, true)

    children =
      [
        # MoveCache for caching legal moves
        if(enable_cache?, do: Pidro.MoveCache, else: nil),
        # Registry for game lookup by ID
        if(enable_registry?, do: {Registry, keys: :unique, name: Pidro.Registry}, else: nil),
        # DynamicSupervisor for game server processes
        {DynamicSupervisor, name: Pidro.GameSupervisor, strategy: :one_for_one}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
