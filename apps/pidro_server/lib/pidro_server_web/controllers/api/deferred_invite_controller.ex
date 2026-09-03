defmodule PidroServerWeb.API.DeferredInviteController do
  @moduledoc """
  One-shot native deferred-invite resolution.

  A valid Android Play referrer is authoritative. Otherwise the endpoint asks
  the node-local matcher for one exact coarse signature. Every no-match class
  deliberately returns the same empty envelope.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias PidroServer.Invites
  alias PidroServer.Invites.Codes
  alias PidroServer.Invites.DeferredMatcher
  alias PidroServer.Invites.DeferredSignature
  alias PidroServer.Invites.Invite
  alias PidroServerWeb.Schemas.{ErrorSchemas, InviteSchemas}

  @install_id_regex ~r/^[A-Za-z0-9._-]{1,64}$/
  @max_referrer_length 1_024

  tags(["Invites"])

  operation(:create,
    summary: "Resolve a first-install invite",
    description: """
    Public one-shot native handoff. Android may provide a Google Play install
    referrer containing exactly one `invite` query key. Fresh Android and iOS
    installs may instead provide the complete coarse signature captured from
    the store click; hints expire after 30 minutes and are consumed atomically.

    A valid Android referrer wins, but any supplied fallback buckets are still
    consumed. Missing, expired, malformed, unknown and ambiguous inputs all
    answer 200 with the same null `data.invite`; only a match contains `code`.
    The random `install_id` is an uninstall-scoped fairness key, not identity.
    Limited per client IP and hashed install id.
    """,
    request_body:
      {"First-install referrer or coarse signature", "application/json",
       InviteSchemas.DeferredInviteRequest},
    responses: [
      ok:
        {"Matched code or empty result", "application/json", InviteSchemas.DeferredInviteResponse},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    invite =
      if DeferredMatcher.enabled?() and valid_request_base?(params) do
        fallback = consume_fallback(conn, params)
        referrer_invite(params) || fallback_invite(fallback)
      end

    if invite do
      log_match(invite, params["platform"])
    end

    json(conn, %{data: %{invite: invite_json(invite)}})
  end

  defp valid_request_base?(%{"platform" => platform, "install_id" => install_id})
       when platform in ["ios", "android"] and is_binary(install_id) do
    Regex.match?(@install_id_regex, install_id)
  end

  defp valid_request_base?(_params), do: false

  defp consume_fallback(conn, params) do
    case DeferredSignature.build(conn.remote_ip, params) do
      {:ok, %{platform: "android", os_major: os_major} = signature} ->
        variants =
          if os_major == "10", do: [signature], else: [signature, %{signature | os_major: "10"}]

        DeferredMatcher.consume(variants)

      {:ok, signature} ->
        DeferredMatcher.consume([signature])

      :error ->
        :none
    end
  end

  defp referrer_invite(%{"platform" => "android", "referrer" => referrer})
       when is_binary(referrer) and byte_size(referrer) <= @max_referrer_length do
    with {:ok, code} <- referrer_code(referrer),
         {:ok, %Invite{} = invite} <- Invites.get_by_code(code) do
      invite
    else
      _invalid_or_unknown -> nil
    end
  end

  defp referrer_invite(_params), do: nil

  defp referrer_code(referrer) do
    values =
      referrer
      |> URI.query_decoder()
      |> Enum.reduce([], fn
        {"invite", value}, acc -> [value | acc]
        _other, acc -> acc
      end)

    case values do
      [value] -> Codes.normalize(value)
      _missing_or_duplicate -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fallback_invite({:ok, code}) do
    case Invites.get_by_code(code) do
      {:ok, %Invite{} = invite} -> invite
      _stale -> nil
    end
  end

  defp fallback_invite(_none_or_ambiguous), do: nil

  defp invite_json(%Invite{code: code}), do: %{code: code}
  defp invite_json(nil), do: nil

  defp log_match(invite, platform) do
    case Invites.record_event(invite, %{kind: "deferred_matched", platform: platform}) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.error("Deferred invite match event failed: #{inspect(reason)}")
    end
  end
end
