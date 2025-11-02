defmodule PidroServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PidroServerWeb.Telemetry,
      PidroServer.Repo,
      {DNSCluster, query: Application.get_env(:pidro_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PidroServer.PubSub},
      # Presence tracking for connected users
      PidroServerWeb.Presence,
      # Games domain supervisor - manages rooms and game processes
      PidroServer.Games.Supervisor,
      # Start to serve requests, typically the last entry
      PidroServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PidroServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PidroServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
