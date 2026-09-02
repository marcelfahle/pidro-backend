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

      new Socket("ws://localhost:4000/socket", {authToken: "eyJhbG..."})

  The token is verified using PidroServer.Accounts.Token and must be valid
  and not expired (30 day expiry). Its version claim is then checked against
  the user's `token_version` through
  `PidroServer.Accounts.Auth.fetch_user_for_token/1`; a revoked token or a
  deleted user is refused with `:error`.

  ## Disconnects

  `PidroServer.Accounts.Auth.bump_token_version/1` broadcasts `"disconnect"`
  on `"user_socket:<user_id>"`, the topic `id/1` returns, which closes every
  live connection for that user. A client holding the old token then fails
  each reconnect until it logs in again.
  """

  use Phoenix.Socket
  require Logger

  alias PidroServer.Accounts.{Auth, Token}

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

  * `{:ok, socket}` - If authentication succeeds with user_id, session_id, and connected_at assigned
  * `:error` - If authentication fails
  """
  @impl true
  def connect(_params, socket, %{auth_token: token}) when is_binary(token) and token != "" do
    authenticate(token, socket)
  end

  # Keep query-param authentication during the rolling migration so already
  # released clients continue to connect while new clients move the JWT out of
  # the WebSocket URL and into Sec-WebSocket-Protocol.
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) and token != "" do
    authenticate(token, socket)
  end

  # Reject connections without a token
  def connect(_params, _socket, _connect_info), do: :error

  defp authenticate(token, socket) do
    with {:ok, %{id: user_id} = claims} <- Token.verify(token),
         {:ok, _user} <- Auth.fetch_user_for_token(claims) do
      # Generate or retrieve session_id based on user_id
      # This allows the same session to be maintained across reconnects
      session_id = generate_session_id(user_id)

      # user_id stays a bare id string: id/1, Presence and the channels read it.
      {:ok,
       socket
       |> assign(:user_id, user_id)
       |> assign(:session_id, session_id)
       |> assign(:connected_at, DateTime.utc_now())}
    else
      {:error, reason} ->
        Logger.warning("Socket connection failed: #{inspect(reason)}")
        :error
    end
  end

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
  def id(socket), do: topic(socket.assigns.user_id)

  @doc """
  The per-user socket topic, `"user_socket:<user_id>"`.

  Single source of truth for the id `id/1` returns and the topic
  `PidroServer.Accounts.Auth` broadcasts `"disconnect"` on.
  """
  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "user_socket:#{user_id}"

  # Generates a unique session ID for a user connection.
  # Uses a combination of user_id and timestamp to create a stable session identifier.
  defp generate_session_id(user_id) do
    # Use a combination of user_id and timestamp to create stable session
    # For the same user_id, we want to identify this as the same "session"
    # but we also want each websocket connection to have unique tracking
    :crypto.hash(:sha256, "#{user_id}:#{System.system_time()}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
