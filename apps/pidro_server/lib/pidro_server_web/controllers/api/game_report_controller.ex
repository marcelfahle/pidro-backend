defmodule PidroServerWeb.API.GameReportController do
  use PidroServerWeb, :controller

  def create(conn, _params) do
    # Query params are never report data, even if they would overwrite a body field.
    case PidroServer.GameReports.create(conn.assigns.current_user.id, conn.body_params) do
      {:ok, report} ->
        conn |> put_status(201) |> json(%{data: %{id: report.id}})

      {:error, :invalid_report} ->
        error(conn, 422, "invalid_report")

      {:error, :not_participant} ->
        error(conn, 403, "not_participant")

      {:error, :rate_limited} ->
        conn |> put_resp_header("retry-after", "3600") |> error(429, "rate_limited")

      {:error, _} ->
        error(conn, 503, "unavailable")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
