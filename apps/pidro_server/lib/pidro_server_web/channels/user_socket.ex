defmodule PidroServerWeb.UserSocket do
  @moduledoc """
  UserSocket handles WebSocket connections for the Pidro game server.

  It provides authentication via JWT tokens and manages channel subscriptions
  for lobby and game channels.

  ## Channels

  * `"lobby"` - Global lobby channel for room list updates
  * `"game:*"` - Game-specific channels for real-time gameplay

  ## Authentication

  Clients must provide a valid JWT token when connecting:

      socket.connect("ws://localhost:4000/socket", {token: "eyJhbG..."})

  The token is verified using PidroServer.Accounts.Token and must be valid
  and not expired (30 day expiry).
  """

  use Phoenix.Socket

  # Define channels
  channel "lobby", PidroServerWeb.LobbyChannel
  channel "game:*", PidroServerWeb.GameChannel

  @doc """
  Authenticates the socket connection using a JWT token.

  ## Parameters

  * `params` - Connection parameters containing "token"
  * `socket` - The socket struct
  * `_connect_info` - Additional connection information (unused)

  ## Returns

  * `{:ok, socket}` - If authentication succeeds
  * `:error` - If authentication fails
  """
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case PidroServer.Accounts.Token.verify(token) do
      {:ok, user_id} ->
        socket = assign(socket, :user_id, user_id)
        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  # Reject connections without a token
  def connect(_params, _socket, _connect_info), do: :error

  @doc """
  Returns a unique identifier for the socket connection.

  This is used by Phoenix.Presence to track user presence and
  by the PubSub system for targeting specific connections.

  ## Parameters

  * `socket` - The socket struct with user_id assigned

  ## Returns

  * A unique socket identifier string in the format "user_socket:USER_ID"
  """
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
