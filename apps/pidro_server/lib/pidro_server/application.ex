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
      # Idle-guest sweep; needs the Repo and the RoomManager (started below by
      # Games.Supervisor) only when a run fires, never at start
      PidroServer.Accounts.GuestReaper,
      {DNSCluster, query: Application.get_env(:pidro_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PidroServer.PubSub},
      # Presence tracking for connected users
      PidroServerWeb.Presence,
      # Aggregate online user count across all channels
      PidroServer.Games.PresenceAggregator,
      # Games domain supervisor - manages rooms and game processes
      PidroServer.Games.Supervisor,
      # Bot infrastructure - available in all environments
      PidroServer.Games.Bots.BotSupervisor,
      PidroServer.Games.Bots.BotManager,
      # Node-local rate-limit counters; must be up before the endpoint serves
      {PidroServer.RateLimit, clean_period: :timer.minutes(1)},
      # Privacy-bounded, node-local deferred invite hints. This must remain a
      # single owner unless the deployment adopts a first-party shared store.
      PidroServer.Invites.DeferredMatcher,
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
