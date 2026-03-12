defmodule PidroServerWeb.HealthControllerTest do
  use PidroServerWeb.ConnCase, async: false

  test "GET /up", %{conn: conn} do
    conn = get(conn, ~p"/up")

    assert response(conn, 200) == "ok"
  end
end
