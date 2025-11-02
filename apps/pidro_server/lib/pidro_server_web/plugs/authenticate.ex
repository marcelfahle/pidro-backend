defmodule PidroServerWeb.Plugs.Authenticate do
  @moduledoc """
  Plug for authenticating users via Bearer token.

  This plug extracts the Bearer token from the Authorization header, verifies it
  using the token verification system, and loads the associated user. If authentication
  succeeds, the user is assigned to the connection. If it fails, returns a 401 Unauthorized
  response and halts the connection.

  ## Usage

  Add to your router or a specific pipeline:

      defmodule PidroServerWeb.Router do
        use PidroServerWeb, :router

        pipeline :api_authenticated do
          plug PidroServerWeb.Plugs.Authenticate
        end

        scope "/api", PidroServerWeb do
          pipe_through :api_authenticated
          # your routes here
        end
      end

  ## Behavior

  - Extracts the Authorization header (expects "Bearer <token>" format)
  - Verifies the token using `PidroServer.Accounts.Token.verify/1`
  - Loads the user using `PidroServer.Accounts.Auth.get_user/1`
  - On success: assigns the user to `:current_user` and returns the connection
  - On failure: returns 401 Unauthorized JSON response and halts the connection
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 3]
  alias PidroServer.Accounts.Token
  alias PidroServer.Accounts.Auth

  @doc """
  Initializes the plug options.

  Returns the options as-is since this plug doesn't require configuration.
  """
  @spec init(opts :: Keyword.t()) :: Keyword.t()
  def init(opts) do
    opts
  end

  @doc """
  Authenticates the user based on the Authorization header.

  Extracts the Bearer token from the Authorization header, verifies it,
  and loads the associated user. Assigns the user to the connection or
  halts with a 401 Unauthorized response.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `_opts` - Plug options (unused)

  ## Returns

    * Updated connection with user assigned to `:current_user` on success
    * Halted connection with 401 response on failure
  """
  @spec call(conn :: Plug.Conn.t(), opts :: Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        authenticate_token(conn, token)

      :error ->
        unauthorized_response(conn)
    end
  end

  @doc false
  defp extract_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [auth_header] ->
        case String.split(auth_header, " ") do
          ["Bearer", token] -> {:ok, token}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc false
  defp authenticate_token(conn, token) do
    case Token.verify(token) do
      {:ok, user_id} ->
        case Auth.get_user(user_id) do
          nil ->
            unauthorized_response(conn)

          user ->
            assign(conn, :current_user, user)
        end

      {:error, _reason} ->
        unauthorized_response(conn)
    end
  end

  @doc false
  defp unauthorized_response(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_view(PidroServerWeb.ErrorJSON)
    |> render("401.json", %{})
    |> halt()
  end
end
