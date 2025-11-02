defmodule PidroServer.Games.GameRegistry do
  @moduledoc """
  Registry for game processes.

  Provides unique naming for game processes using room codes. Uses Elixir's
  built-in Registry module to maintain a mapping of room codes to game PIDs.

  ## Usage

      # Register a process
      {:ok, _pid} = GenServer.start_link(MyGameServer, [], name: GameRegistry.via("A3F9"))

      # Lookup a process
      {:ok, pid} = GameRegistry.lookup("A3F9")

      # List all games
      codes = GameRegistry.list_games()
  """

  @doc """
  Returns the child spec for starting the Registry.

  The Registry is configured with:
  - `:unique` keys (one process per room code)
  - Named `PidroServer.Games.GameRegistry`
  """
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__
    )
  end

  @doc """
  Returns a via tuple for registering a game process.

  ## Parameters

    - `room_code` - The unique room code (e.g., "A3F9")

  ## Returns

    A via tuple suitable for use with GenServer.start_link/3

  ## Examples

      iex> GameRegistry.via("A3F9")
      {:via, Registry, {PidroServer.Games.GameRegistry, "A3F9"}}
  """
  @spec via(room_code :: String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(room_code) do
    {:via, Registry, {__MODULE__, room_code}}
  end

  @doc """
  Looks up the PID for a game by room code.

  ## Parameters

    - `room_code` - The room code to lookup

  ## Returns

    - `{:ok, pid}` if the game exists
    - `{:error, :not_found}` if no game is registered for that code

  ## Examples

      iex> GameRegistry.lookup("A3F9")
      {:ok, #PID<0.123.0>}

      iex> GameRegistry.lookup("INVALID")
      {:error, :not_found}
  """
  @spec lookup(room_code :: String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(room_code) do
    case Registry.lookup(__MODULE__, room_code) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all registered game room codes.

  ## Returns

    A list of room codes (strings)

  ## Examples

      iex> GameRegistry.list_games()
      ["A3F9", "B2K7", "XYZ1"]
  """
  @spec list_games() :: [String.t()]
  def list_games do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
