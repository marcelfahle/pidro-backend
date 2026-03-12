defmodule PidroServerWeb.DevAccessTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.ConnTest

  setup do
    original_dev_routes = Application.get_env(:pidro_server, :dev_routes)
    original_dev_access = Application.get_env(:pidro_server, :dev_access)

    on_exit(fn ->
      if is_nil(original_dev_routes) do
        Application.delete_env(:pidro_server, :dev_routes)
      else
        Application.put_env(:pidro_server, :dev_routes, original_dev_routes)
      end

      if is_nil(original_dev_access) do
        Application.delete_env(:pidro_server, :dev_access)
      else
        Application.put_env(:pidro_server, :dev_access, original_dev_access)
      end
    end)

    :ok
  end

  test "returns 404 when dev access is disabled", %{conn: conn} do
    Application.put_env(:pidro_server, :dev_routes, false)
    Application.put_env(:pidro_server, :dev_access, enabled: false)

    conn = get(conn, ~p"/dev/games")

    assert response(conn, 404) =~ "Not Found"
  end

  test "returns 401 when dev access is enabled without credentials", %{conn: conn} do
    Application.put_env(:pidro_server, :dev_routes, false)

    Application.put_env(:pidro_server, :dev_access,
      enabled: true,
      username: "admin",
      password: "secret-password"
    )

    conn = get(conn, ~p"/dev/games")

    assert response(conn, 401)
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Application\""]
  end

  test "allows access with valid basic auth credentials", %{conn: conn} do
    Application.put_env(:pidro_server, :dev_routes, false)

    Application.put_env(:pidro_server, :dev_access,
      enabled: true,
      username: "admin",
      password: "secret-password"
    )

    credentials = Base.encode64("admin:secret-password")

    conn =
      conn
      |> put_req_header("authorization", "Basic " <> credentials)
      |> get(~p"/dev/games")

    assert html_response(conn, 200) =~ "Development Games"
  end
end
