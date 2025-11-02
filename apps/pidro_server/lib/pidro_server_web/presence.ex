defmodule PidroServerWeb.Presence do
  @moduledoc """
  Presence tracking for Pidro game server.

  This module provides real-time tracking of connected users across
  lobby and game channels. It uses Phoenix.Presence to maintain
  distributed, conflict-free presence information.

  ## Usage

  Track a user when they join a channel:

      {:ok, _} = Presence.track(socket, socket.assigns.user_id, %{
        online_at: DateTime.utc_now(),
        position: :north
      })

  List all present users in a channel:

      users = Presence.list(socket)

  ## Features

  * Automatic cleanup when users disconnect
  * CRDT-based for distributed systems
  * Minimal overhead with smart delta updates
  * Works across distributed Elixir nodes
  """

  use Phoenix.Presence,
    otp_app: :pidro_server,
    pubsub_server: PidroServer.PubSub
end
