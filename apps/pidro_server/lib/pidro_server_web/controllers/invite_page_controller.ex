defmodule PidroServerWeb.InvitePageController do
  @moduledoc "Server-rendered, side-effect-free handoff for public invite links."

  use PidroServerWeb, :controller

  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent
  alias PidroServerWeb.InvitePreview

  @doc "Renders a known invite in any state, or a generic branded 404."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"code" => code}) do
    device = conn |> get_req_header("user-agent") |> List.first() |> UserAgent.classify()
    crawler? = device == :crawler

    conn = prepare_response(conn)

    case InvitePreview.get(code) do
      {:ok, preview} ->
        page = InvitePage.present(preview, human_device(device))
        render(conn, :show, page: page, crawler?: crawler?)

      {:error, :not_found} ->
        page = InvitePage.not_found(human_device(device))

        conn
        |> put_status(:not_found)
        |> render(:not_found, page: page, crawler?: crawler?)
    end
  end

  defp human_device(:crawler), do: :desktop
  defp human_device(device), do: device

  defp prepare_response(conn) do
    static_origin = PidroServerWeb.Endpoint.static_url()

    csp =
      Enum.join(
        [
          "default-src 'self'",
          "img-src 'self' data: #{static_origin}",
          "style-src 'self' #{static_origin}",
          "script-src 'self' #{static_origin}",
          "connect-src 'none'",
          "object-src 'none'",
          "base-uri 'none'",
          "form-action 'none'",
          "frame-ancestors 'none'"
        ],
        "; "
      )

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("vary", "User-Agent")
    |> put_resp_header("content-security-policy", csp)
  end
end
