defmodule PidroServerWeb.DeferredInviteCaptureController do
  @moduledoc """
  Receives the best-effort browser hint immediately before store navigation.

  Exact Origin checks stop unrelated browser sites from submitting hints. They
  are a browser-site guard, not authentication: a non-browser client can forge
  both Origin and Fetch Metadata, so validation and rate limits remain the
  actual abuse boundaries.
  """

  use PidroServerWeb, :controller

  require Logger

  alias PidroServer.Invites
  alias PidroServer.Invites.DeferredMatcher
  alias PidroServer.Invites.DeferredSignature
  alias PidroServer.Invites.Invite

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"code" => code} = params) do
    case allowed_origin(conn) do
      {:ok, origin} ->
        conn
        |> put_capture_cors(origin)
        |> capture(code, params)

      :error ->
        conn
        |> delete_resp_header("access-control-allow-origin")
        |> send_resp(:forbidden, "")
    end
  end

  @doc "Absolute Phoenix URL used by the public landing page's store beacon."
  @spec capture_url(String.t()) :: String.t()
  def capture_url(code) do
    endpoint_origin = config() |> Keyword.fetch!(:endpoint_origin) |> String.trim_trailing("/")
    "#{endpoint_origin}/j/#{URI.encode(code)}/deferred"
  end

  @doc "The exact Phoenix origin allowed by the invite page CSP."
  @spec endpoint_origin() :: String.t()
  def endpoint_origin,
    do: config() |> Keyword.fetch!(:endpoint_origin) |> String.trim_trailing("/")

  defp capture(conn, code, params) do
    with {:ok, preview} <- PidroServerWeb.InvitePreview.get(code),
         %Invite{} = invite <- target_invite(preview),
         {:ok, signature} <- DeferredSignature.build(conn.remote_ip, params),
         :created <- DeferredMatcher.capture(invite.code, signature) do
      log_event(invite, signature.platform)
    end

    send_resp(conn, :no_content, "")
  end

  defp target_invite(%{state: :moved, invite: %Invite{successor: %Invite{} = successor}}),
    do: successor

  defp target_invite(%{invite: %Invite{} = invite}), do: invite

  defp log_event(invite, platform) do
    case Invites.record_event(invite, %{
           kind: "store_clicked",
           platform: platform,
           ua_class: "mobile"
         }) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.error("Deferred invite store-click event failed: #{inspect(reason)}")
    end
  end

  defp allowed_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin in allowed_origins(), do: {:ok, origin}, else: :error

      [] ->
        if get_req_header(conn, "sec-fetch-site") == ["same-origin"], do: {:ok, nil}, else: :error

      _multiple ->
        :error
    end
  end

  defp allowed_origins, do: Keyword.fetch!(config(), :allowed_origins)

  defp put_capture_cors(conn, nil),
    do: delete_resp_header(conn, "access-control-allow-origin")

  defp put_capture_cors(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("vary", "Origin")
  end

  defp config, do: Application.fetch_env!(:pidro_server, __MODULE__)
end
