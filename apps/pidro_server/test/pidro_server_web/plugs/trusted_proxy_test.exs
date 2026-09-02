defmodule PidroServerWeb.Plugs.TrustedProxyTest do
  # async: false on purpose: the tests toggle the :trust_proxy_headers
  # application env, which the plug reads at call time for every request.
  use PidroServerWeb.ConnCase, async: false

  alias PidroServerWeb.Plugs.TrustedProxy

  @client {203, 0, 113, 9}
  @docker_peer {172, 18, 0, 2}
  # ::ffff:172.18.0.2, the shape a dual-stack listener on :: produces
  @mapped_docker_peer {0, 0, 0, 0, 0, 65_535, 44_050, 2}
  @public_peer {198, 51, 100, 7}

  setup do
    original = Application.get_env(:pidro_server, :trust_proxy_headers)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:pidro_server, :trust_proxy_headers)
      else
        Application.put_env(:pidro_server, :trust_proxy_headers, original)
      end
    end)

    :ok
  end

  defp trust(flag), do: Application.put_env(:pidro_server, :trust_proxy_headers, flag)

  # Sets the peer and appends one or more x-forwarded-for header lines in order.
  defp forwarded(conn, peer, lines) do
    headers = Enum.map(List.wrap(lines), &{"x-forwarded-for", &1})
    %{conn | remote_ip: peer, req_headers: conn.req_headers ++ headers}
  end

  defp run(conn), do: TrustedProxy.call(conn, TrustedProxy.init([]))

  describe "flag false (AE2)" do
    test "leaves remote_ip and scheme untouched", %{conn: conn} do
      trust(false)

      result =
        conn
        |> forwarded({127, 0, 0, 1}, "203.0.113.9")
        |> put_req_header("x-forwarded-proto", "https")
        |> run()

      assert result.remote_ip == {127, 0, 0, 1}
      assert result.scheme == :http
    end
  end

  describe "flag true" do
    setup do
      trust(true)
      :ok
    end

    test "AE3: private peer -> remote_ip from the header and https from X-Forwarded-Proto", %{
      conn: conn
    } do
      result =
        conn
        |> forwarded(@docker_peer, "203.0.113.9")
        |> put_req_header("x-forwarded-proto", "https")
        |> run()

      assert result.remote_ip == @client
      assert result.scheme == :https
    end

    test "AE15: an IPv4-mapped IPv6 peer counts as the private IPv4 address", %{conn: conn} do
      assert conn
             |> forwarded(@mapped_docker_peer, "203.0.113.9")
             |> run()
             |> Map.fetch!(:remote_ip) ==
               @client
    end

    test "AE9: a public peer is not trusted, header and proto are ignored", %{conn: conn} do
      result =
        conn
        |> forwarded(@public_peer, "203.0.113.9")
        |> put_req_header("x-forwarded-proto", "https")
        |> run()

      assert result.remote_ip == @public_peer
      assert result.scheme == :http
    end

    test "loopback, RFC 1918, CGNAT, IPv6 loopback, ULA and link-local peers are proxy-side", %{
      conn: conn
    } do
      for peer <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 0, 1},
            {100, 64, 1, 1},
            {100, 127, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFC00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert conn |> forwarded(peer, "203.0.113.9") |> run() |> Map.fetch!(:remote_ip) ==
                 @client,
               "expected #{inspect(peer)} to be treated as proxy-side"
      end
    end

    test "neighbouring public ranges are not proxy-side", %{conn: conn} do
      for peer <- [
            {172, 15, 0, 1},
            {172, 32, 0, 1},
            {100, 63, 255, 255},
            {100, 128, 0, 0},
            {0xFE00, 0, 0, 0, 0, 0, 0, 1},
            {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
            {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
          ] do
        assert conn |> forwarded(peer, "203.0.113.9") |> run() |> Map.fetch!(:remote_ip) == peer,
               "expected #{inspect(peer)} to be left alone"
      end
    end

    test "AE13: the rightmost value wins, the forged first value never does", %{conn: conn} do
      assert conn
             |> forwarded(@docker_peer, "1.2.3.4, 203.0.113.9")
             |> run()
             |> Map.fetch!(:remote_ip) == @client
    end

    test "with two header lines the last value of the last line wins", %{conn: conn} do
      assert conn
             |> forwarded(@docker_peer, ["1.2.3.4", "5.6.7.8 , 203.0.113.9"])
             |> run()
             |> Map.fetch!(:remote_ip) == @client
    end

    test "an IPv6 value becomes the IPv6 tuple", %{conn: conn} do
      assert conn |> forwarded(@docker_peer, "2001:db8::9") |> run() |> Map.fetch!(:remote_ip) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}
    end

    test "bracketed, ported, empty or garbage values leave remote_ip unchanged", %{conn: conn} do
      for value <- ["[2001:db8::9]:443", "203.0.113.9:1234", "garbage", "", "1.2.3.4,", <<0xFF>>] do
        assert conn |> forwarded(@docker_peer, value) |> run() |> Map.fetch!(:remote_ip) ==
                 @docker_peer,
               "expected #{inspect(value)} to be rejected"
      end
    end

    test "no header at all leaves remote_ip unchanged", %{conn: conn} do
      assert %{conn | remote_ip: @docker_peer} |> run() |> Map.fetch!(:remote_ip) == @docker_peer
    end
  end

  describe "endpoint order" do
    test "the rewrite is visible to Plug.Telemetry, which runs after Plug.RequestId", %{
      conn: conn
    } do
      trust(true)
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:phoenix, :endpoint, :start],
          fn _event, _measurements, %{conn: conn}, _config ->
            send(test_pid, {:endpoint_start, conn.remote_ip, conn.scheme})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn
      |> forwarded(@docker_peer, "203.0.113.9")
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/up")

      assert_receive {:endpoint_start, @client, :https}
    end
  end
end
