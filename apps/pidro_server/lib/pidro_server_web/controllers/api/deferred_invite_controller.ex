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
  alias PidroServerWeb.InvitePreview
  alias PidroServerWeb.Schemas.{ErrorSchemas, InviteSchemas}

  @install_id_regex ~r/^[A-Za-z0-9._-]{1,64}$/
  @max_referrer_length 1_024

  tags(["Invites"])

  operation(:create,
    summary: "Resolve a first-install invite or friend",
    description: """
    Public one-shot native handoff. Android may provide a Google Play install
    referrer containing exactly one `invite` or `friend` query key (not both).
    Fresh Android and iOS
    installs may instead provide the complete coarse signature captured from
    the store click; hints expire after 30 minutes and are consumed atomically.

    A valid Android referrer wins, but any supplied fallback buckets are still
    consumed. Missing, expired, malformed, unknown and ambiguous inputs all
    answer 200 with null `data.invite` and `data.friend`. A match returns either
    the unchanged invite `{code}` or a public friend `{slug, display_name, avatar_url}`.
    Duplicate or mixed referrer keys are rejected, retaining unique coarse
    fallback behavior. Multiple distinct coarse targets, including mixed kinds,
    are ambiguous and consumed without selection.
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
    target =
      if DeferredMatcher.enabled?() and valid_request_base?(params) do
        fallback = consume_fallback(conn, params)
        referrer_invite(params) || fallback_invite(fallback)
      end

    {invite, friend} =
      case target do
        %Invite{} = invite -> {invite, nil}
        {:friend, friend} -> {nil, friend}
        nil -> {nil, nil}
      end

    if invite do
      log_match(invite, params["platform"])
    end

    json(conn, %{data: %{invite: invite_json(invite), friend: friend}})
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
    with {:ok, hint} <- referrer_code(referrer) do
      fallback_invite({:ok, hint})
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
        {key, value}, acc when key in ["invite", "friend"] -> [{key, value} | acc]
        _other, acc -> acc
      end)

    case values do
      [{"invite", value}] -> Codes.normalize(value)
      [{"friend", slug}] -> {:ok, {:friend, slug}}
      _missing_or_duplicate -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fallback_invite({:ok, {:friend, slug}}) do
    case PidroServer.Accounts.Auth.public_profile_by_slug(slug) do
      {:ok, profile} ->
        {:friend, Map.put(Map.take(profile, [:display_name, :avatar_url]), :slug, slug)}

      _not_found ->
        nil
    end
  end

  defp fallback_invite({:ok, code}) do
    eligible_invite(code)
  end

  defp fallback_invite(_none_or_ambiguous), do: nil

  defp eligible_invite(code) do
    with {:ok, preview} <- InvitePreview.get(code) do
      InvitePreview.handoff_target(preview)
    else
      _not_found -> nil
    end
  end

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
