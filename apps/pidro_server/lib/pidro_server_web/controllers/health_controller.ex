defmodule PidroServerWeb.HealthController do
  use PidroServerWeb, :controller

  alias PidroServer.Repo

  def up(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} ->
        text(conn, "ok")

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> text("db_unavailable")
    end
  end
end
