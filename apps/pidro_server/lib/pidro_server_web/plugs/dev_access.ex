defmodule PidroServerWeb.Plugs.DevAccess do
  @moduledoc """
  Guards `/dev` routes outside local development and test.

  In environments where `:dev_routes` is enabled, the plug is a no-op.
  Otherwise, access is controlled via runtime configuration so production
  releases can temporarily expose the game admin tools behind Basic Auth.
  """

  import Plug.Conn

  alias Plug.BasicAuth

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if Application.get_env(:pidro_server, :dev_routes, false) do
      conn
    else
      case Application.get_env(:pidro_server, :dev_access, []) do
        access when is_list(access) ->
          maybe_require_basic_auth(conn, access)

        _other ->
          not_found(conn)
      end
    end
  end

  defp maybe_require_basic_auth(conn, access) do
    enabled? = Keyword.get(access, :enabled, false)
    username = Keyword.get(access, :username)
    password = Keyword.get(access, :password)

    cond do
      not enabled? ->
        not_found(conn)

      is_binary(username) and byte_size(username) > 0 and is_binary(password) and byte_size(password) > 0 ->
        BasicAuth.basic_auth(conn, username: username, password: password)

      true ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
