defmodule PidroServerWeb.Plugs.GameReportBodyLimit do
  @moduledoc "Read at most 32 KiB before the general endpoint parsers, including chunked bodies."
  import Plug.Conn
  alias Plug.Conn.Utils
  def init(opts), do: opts

  def call(%{method: "POST"} = conn, _) do
    # Match Phoenix.Router's decoded segments, including /%67ame-reports.
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["api", "v1", "game-reports"] ->
        # Header-only auth and throttling precede body reads/decoding.
        conn = PidroServerWeb.Plugs.Authenticate.call(conn, [])
        if conn.halted, do: conn, else: throttle(conn)

      _ ->
        conn
    end
  end

  def call(conn, _), do: conn

  defp throttle(conn) do
    case PidroServer.RateLimit.hit(
           "game_reports:user:#{conn.assigns.current_user.id}",
           60_000,
           10
         ) do
      {:allow, _} -> parse(conn)
      {:deny, _} -> conn |> put_resp_header("retry-after", "60") |> reject(429, "rate_limited")
    end
  rescue
    _ -> reject(conn, 503, "unavailable")
  catch
    :exit, _ -> reject(conn, 503, "unavailable")
  end

  defp parse(conn) do
    if json_content_type?(get_req_header(conn, "content-type")) do
      read(conn, [], 0)
    else
      reject(conn, 415)
    end
  end

  defp json_content_type?([value]),
    do: match?({:ok, "application", "json", _}, Utils.content_type(value))

  defp json_content_type?(_), do: false

  defp read(conn, chunks, size) do
    case read_body(conn, length: 32_769 - size, read_length: 32_769 - size, read_timeout: 5_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        total = size + byte_size(chunk)

        cond do
          total > 32_768 -> reject(conn, 413)
          status == :more -> read(conn, [chunk | chunks], total)
          true -> decode(conn, Enum.reverse([chunk | chunks]))
        end

      _ ->
        reject(conn, 400)
    end
  end

  defp decode(conn, chunks) do
    case Jason.decode(IO.iodata_to_binary(chunks)) do
      {:ok, body} when is_map(body) -> %{conn | body_params: body}
      _ -> reject(conn, 400)
    end
  end

  defp reject(conn, status, error \\ "invalid_body") do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
