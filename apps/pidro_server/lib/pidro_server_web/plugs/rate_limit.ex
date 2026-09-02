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

  @default_limiter PidroServer.RateLimit

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
      identifier -> "#{policy}:ident:#{hash_identifier(identifier)}"
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

  defp hash_identifier(identifier) do
    :sha256
    |> :crypto.hash(identifier)
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
