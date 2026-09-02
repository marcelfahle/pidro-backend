defmodule PidroServerWeb.Plugs.TrustedProxy do
  @moduledoc """
  Restores the client address and scheme from kamal-proxy's `X-Forwarded-*`
  headers.

  Mounted first among the user plugs in `PidroServerWeb.Endpoint`, so every
  later plug of the HTTP pipeline, the router and `PidroServerWeb.Plugs.RateLimit`
  see the real client in `conn.remote_ip`. WebSocket upgrades are the exception:
  `use Phoenix.Endpoint` injects `plug :socket_dispatch` ahead of every user plug
  and halts on a socket path, so a socket connect never reaches this plug and any
  socket-level use of the peer address needs its own check.
  Without it every production request would carry the proxy's bridge address
  and the per-IP limits would throttle everyone at once.

  The plug acts only when both hold:

    * `config :pidro_server, :trust_proxy_headers` is true. It is read at call
      time; `config/runtime.exs` sets it from `TRUST_PROXY_HEADERS`, default
      true only in prod.
    * The TCP peer, after collapsing an IPv4-mapped IPv6 address, is proxy-side:
      loopback, RFC 1918, CGNAT `100.64.0.0/10`, IPv6 loopback, ULA `fc00::/7`
      or link-local `fe80::/10`. Production binds on `::`, so the proxy's IPv4
      peer arrives as `{0, 0, 0, 0, 0, 65535, a, b}`.

  It then takes the rightmost `X-Forwarded-For` value across all header lines
  (the one the trusted proxy appended), parses it with
  `:inet.parse_strict_address/1` and sets `conn.remote_ip`; a bracketed,
  ported, empty or otherwise unparsable value leaves the address unchanged.
  `X-Forwarded-Proto` is delegated to `Plug.RewriteOn`.

  ## Proxy contract

  kamal-proxy with `forward_headers` off (its default with TLS, which
  `config/deploy.yml` relies on) discards client-supplied `X-Forwarded-*`
  headers and writes exactly one value: the true peer. If `forward_headers`
  were ever enabled, client values would be kept and the peer appended; the
  rightmost rule still picks the peer, which is why the address parse is our
  own and not `Plug.RewriteOn`'s first-value read. The full contract and the
  one-time production check live in `docs/deployment/kamal_hetzner.md`.
  """

  @behaviour Plug

  import Plug.Conn, only: [get_req_header: 2]

  alias PidroServerWeb.Plugs.RateLimit

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if Application.get_env(:pidro_server, :trust_proxy_headers, false) and
         proxy_peer?(RateLimit.normalize_ip(conn.remote_ip)) do
      conn
      |> put_forwarded_ip(get_req_header(conn, "x-forwarded-for"))
      |> Plug.RewriteOn.call([:x_forwarded_proto])
    else
      conn
    end
  end

  @doc """
  True for an address only a proxy on the same host or private network can
  have. Expects an already normalized address (see `RateLimit.normalize_ip/1`).
  """
  @spec proxy_peer?(:inet.ip_address()) :: boolean()
  def proxy_peer?({127, _, _, _}), do: true
  def proxy_peer?({10, _, _, _}), do: true
  def proxy_peer?({172, b, _, _}) when b in 16..31, do: true
  def proxy_peer?({192, 168, _, _}), do: true
  def proxy_peer?({100, b, _, _}) when b in 64..127, do: true
  def proxy_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # fc00::/7 and fe80::/10, checked on the first hextet
  def proxy_peer?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  def proxy_peer?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  def proxy_peer?(_address), do: false

  defp put_forwarded_ip(conn, []), do: conn

  defp put_forwarded_ip(conn, header_lines) do
    rightmost =
      header_lines
      |> Enum.join(",")
      |> String.split(",")
      |> List.last()
      |> String.trim()

    # bin_to_list never raises on non-UTF-8 bytes; the strict parse rejects them.
    case :inet.parse_strict_address(:binary.bin_to_list(rightmost)) do
      {:ok, address} -> %{conn | remote_ip: address}
      {:error, _reason} -> conn
    end
  end
end
