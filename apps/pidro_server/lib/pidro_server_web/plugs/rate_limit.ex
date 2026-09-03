defmodule PidroServerWeb.Plugs.RateLimit do
  @moduledoc """
  Throttles routes tagged with `private: %{rate_limit: [policy, ...]}`.

  Mounted in the `:api` and `:api_authenticated` router pipelines (after
  `Authenticate` in the latter, so `:user` policies see `current_user`). Routes
  without the key pass through at the cost of one map lookup. Policies are read
  from `config :pidro_server, PidroServerWeb.Plugs.RateLimit` at call time, so
  `config/runtime.exs` overrides and per-test changes apply:

      config :pidro_server, PidroServerWeb.Plugs.RateLimit,
        login: %{limit: 10, scale_ms: 60_000, key: :ip}

  Limits are numeric only; there is no off switch. Policies listed on a route
  are applied in order and each one counts in its own bucket.

  ## Keys

    * `:ip` - `"<policy>:ip:<address>"`. An IPv4-mapped IPv6 peer collapses to
      its IPv4 form and a native IPv6 peer keys on its /64 prefix, so one
      household shares a bucket whichever listener it arrived on.
    * `:user` - `"<policy>:user:<id>"` from `conn.assigns.current_user`; with no
      current user the plug logs a warning and falls back to the IP key.
    * `:identifier` - `"<policy>:ident:<hash>"`, the first 16 bytes of the
      SHA-256 of the trimmed, lower-cased `identifier` (or `email`) param,
      hex-encoded, so neither the key nor the log ever holds the address. A
      missing, empty or non-binary param skips this policy only; the other
      policies on the route still apply.
    * `{:param, name}` - `"<policy>:param:<hash>"`, the same truncated SHA-256
      of a trimmed, lower-cased route or body parameter. A missing, empty or
      non-binary parameter skips this policy. This is useful when an upstream
      edge proxy prevents reliable per-client address limiting. The
      `:invite_page` policy also canonicalizes accepted invite-code aliases so
      dashed and undashed forms share one bucket.
    * `:install_id` - `"<policy>:install:<hash>"`, the same truncated SHA-256
      of the trimmed `install_id` param (case preserved: it is an opaque device
      id, not an address). A missing, blank, non-binary or over-64-character
      param skips this policy only, so a request without an install id is never
      limited by it; an over-long id is skipped, not truncated.

  ## Responses

  The first denied policy answers 429 with the `FallbackController` body shape
  (`%{errors: [%{code: "RATE_LIMITED", title, detail}]}`) and a `retry-after`
  header in whole seconds, rounded up, minimum 1, then halts. The plug renders
  the response itself because `FallbackController`'s atom catch-all would answer
  422. `CORSPlug` runs earlier in the endpoint, so the halted 429 keeps its CORS
  headers. Every 429 is logged at `:info` with the bucket key.

  ## Failure mode

  Only the `hit/3` call is rescued: an exception from the limiter logs at
  `:error` and lets the request through; key construction runs outside the
  rescue. The limiter defaults to `PidroServer.RateLimit` and can be swapped
  with the `:limiter` config key, which tests use to simulate a failing
  backend.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias PidroServer.Invites.Codes

  @default_limiter PidroServer.RateLimit
  @install_id_max_length 64

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{private: %{rate_limit: policies}} = conn, _opts) when is_list(policies) do
    config = Application.get_env(:pidro_server, __MODULE__, [])
    limiter = Keyword.get(config, :limiter, @default_limiter)

    Enum.reduce_while(policies, conn, fn policy, conn ->
      apply_policy(conn, config, limiter, policy)
    end)
  end

  def call(conn, _opts), do: conn

  @doc """
  Collapses an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) to its IPv4 tuple.

  Any other address is returned unchanged. Production binds on `::`, so an
  IPv4 peer arrives as `{0, 0, 0, 0, 0, 65535, ab, cd}`.
  """
  @spec normalize_ip(:inet.ip_address()) :: :inet.ip_address()
  def normalize_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}
  end

  def normalize_ip(ip), do: ip

  @doc """
  Formats an address for a bucket key: dotted IPv4, or the /64 prefix of a
  native IPv6 address, both via `:inet.ntoa/1`.
  """
  @spec ip_key(:inet.ip_address()) :: String.t()
  def ip_key(ip) do
    case normalize_ip(ip) do
      {_, _, _, _} = v4 -> v4 |> :inet.ntoa() |> List.to_string()
      {a, b, c, d, _, _, _, _} -> {a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> List.to_string()
    end
  end

  defp apply_policy(conn, config, limiter, policy) do
    %{limit: limit, scale_ms: scale_ms, key: kind} = Keyword.fetch!(config, policy)

    with key when is_binary(key) <- bucket_key(conn, policy, kind),
         {:deny, ms} <- hit(limiter, key, scale_ms, limit) do
      {:halt, deny(conn, key, ms)}
    else
      _allowed_or_skipped -> {:cont, conn}
    end
  end

  defp bucket_key(conn, policy, :ip), do: "#{policy}:ip:#{ip_key(conn.remote_ip)}"

  defp bucket_key(conn, policy, :user) do
    case conn.assigns[:current_user] do
      %{id: id} ->
        "#{policy}:user:#{id}"

      _no_user ->
        Logger.warning(
          "rate limit policy #{policy} is keyed by :user but there is no current_user; " <>
            "falling back to the IP key"
        )

        bucket_key(conn, policy, :ip)
    end
  end

  defp bucket_key(conn, policy, :identifier) do
    case identifier_param(conn.params) do
      nil -> :skip
      identifier -> "#{policy}:ident:#{hash_param(identifier)}"
    end
  end

  defp bucket_key(conn, policy, :install_id) do
    case install_id_param(conn.params) do
      nil -> :skip
      install_id -> "#{policy}:install:#{hash_param(install_id)}"
    end
  end

  defp bucket_key(conn, policy, {:param, name}) when is_binary(name) do
    case generic_param(conn.params, policy, name) do
      nil -> :skip
      value -> "#{policy}:param:#{hash_param(value)}"
    end
  end

  defp identifier_param(%{"identifier" => value}), do: normalize_identifier(value)
  defp identifier_param(%{"email" => value}), do: normalize_identifier(value)
  defp identifier_param(_params), do: nil

  defp normalize_identifier(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identifier(_value), do: nil

  defp generic_param(params, policy, name) do
    case Map.get(params, name) do
      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "" -> nil
          normalized -> canonical_param(policy, name, normalized)
        end

      _other ->
        nil
    end
  end

  defp canonical_param(policy, "code", value)
       when policy in [:invite_page, :invite_capture_code] do
    case Codes.normalize(value) do
      {:ok, code} -> String.downcase(code)
      :error -> value
    end
  end

  defp canonical_param(_policy, _name, value), do: value

  # Matches the 64-character cap on the guest-creation param; a longer value is
  # skipped rather than truncated so it cannot collide with a legitimate id.
  defp install_id_param(%{"install_id" => value}) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if String.length(trimmed) > @install_id_max_length, do: nil, else: trimmed
    end
  end

  defp install_id_param(_params), do: nil

  defp hash_param(value) do
    :sha256
    |> :crypto.hash(value)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  # The only rescue: a broken limiter must never take the API down.
  defp hit(limiter, key, scale_ms, limit) do
    limiter.hit(key, scale_ms, limit)
  rescue
    exception ->
      Logger.error(
        "rate limit backend failed for #{key}, allowing the request: " <>
          Exception.message(exception)
      )

      {:allow, 0}
  end

  defp deny(conn, key, ms_until_reset) do
    retry_after = max(1, div(ms_until_reset + 999, 1000))

    Logger.info("rate limit exceeded key=#{key} retry_after=#{retry_after}s")

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{
      errors: [
        %{
          code: "RATE_LIMITED",
          title: "Too Many Requests",
          detail: "Rate limit exceeded, retry after #{retry_after} seconds"
        }
      ]
    })
    |> halt()
  end
end
