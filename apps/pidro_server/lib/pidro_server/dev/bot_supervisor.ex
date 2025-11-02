if Mix.env() == :dev do
  defmodule PidroServer.Dev.BotSupervisor do
    @moduledoc """
    DynamicSupervisor for managing bot player processes in development.

    This supervisor handles the lifecycle of bot processes, allowing bots
    to be dynamically started and stopped during development and testing.
    """

    use DynamicSupervisor

    def start_link(init_arg) do
      DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
    end

    @impl true
    def init(_init_arg) do
      DynamicSupervisor.init(strategy: :one_for_one)
    end
  end
end
