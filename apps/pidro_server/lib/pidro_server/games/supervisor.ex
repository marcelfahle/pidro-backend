defmodule PidroServer.Games.Supervisor do
  @moduledoc """
  Top-level supervisor for the games domain.

  Supervises all game-related processes in the correct start order:
  1. GameRegistry - Must start first as other processes depend on it
  2. GameSupervisor - Manages individual game processes
  3. RoomManager - Tracks rooms and coordinates game starts

  Uses a `:one_for_one` supervision strategy, meaning if any child crashes,
  only that process is restarted.

  ## Supervision Tree

      PidroServer.Games.Supervisor
      ├── PidroServer.Games.GameRegistry (Registry)
      ├── PidroServer.Games.GameSupervisor (DynamicSupervisor)
      └── PidroServer.Games.RoomManager (GenServer)

  ## Usage

  This supervisor is started automatically as part of the application
  supervision tree defined in PidroServer.Application.
  """

  use Supervisor

  @doc """
  Starts the Games.Supervisor.

  ## Parameters

    - `init_arg` - Initialization argument (typically ignored)

  ## Returns

    - `{:ok, pid}` on success
    - `{:error, reason}` on failure
  """
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Registry must start first - other processes depend on it
      PidroServer.Games.GameRegistry,
      # GameSupervisor manages individual game processes
      PidroServer.Games.GameSupervisor,
      # RoomManager coordinates room lifecycle and uses GameSupervisor
      PidroServer.Games.RoomManager
    ]

    # one_for_one: If a child crashes, only restart that process
    Supervisor.init(children, strategy: :one_for_one)
  end
end
