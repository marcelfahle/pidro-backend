defmodule PidroServerWeb.Plugs.RateLimitTest do
  # async: false on purpose: every test shares the single node-wide Hammer ETS
  # table (PidroServer.RateLimit) and the policy config in the application env.
  # Concurrent tests would count each other's hits and race on the config.
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import ExUnit.CaptureLog

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServerWeb.Plugs.RateLimit
  alias PidroServerWeb.Schemas.ErrorSchemas

  @login_params %{"username" => "nobody-here", "password" => "wrong password!"}
  @window_ms 60_000

  defp login(conn, ip) do
    conn
    |> from_ip(ip)
    |> post(~p"/api/v1/auth/login", @login_params)
  end

  # config/test.exs keeps the logger at :warning; the 429 line is :info.
  defp capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  # Calls the plug directly, the way the router does after merging route private.
  defp run_plug(conn, policies) do
    conn
    |> put_private(:rate_limit, policies)
    |> RateLimit.call([])
  end

  defp with_install_id(conn, ip, install_id) do
    %{conn | params: %{"install_id" => install_id}} |> from_ip(ip)
  end

  # The umbrella config directory: this file sits five levels below the repo root.
  @config_dir Path.expand("../../../../../config", __DIR__)

  # The policy table config.exs declares for `env`, after importing `<env>.exs`.
  defp policy_table(env) do
    @config_dir
    |> Path.join("config.exs")
    |> Config.Reader.read!(env: env)
    |> get_in([:pidro_server, RateLimit])
  end

  describe "429 contract (AE1)" do
    setup do
      with_limit(:login, 1, @window_ms)
    end

    test "second login from the same IP inside the window is 429 with RATE_LIMITED", %{
      conn: conn
    } do
      assert login(conn, {10, 0, 0, 1}).status == 401

      denied = login(build_conn(), {10, 0, 0, 1})

      assert %{"errors" => [%{"code" => "RATE_LIMITED", "title" => title, "detail" => detail}]} =
               json_response(denied, 429)

      assert title == "Too Many Requests"
      assert detail =~ "retry"
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert String.to_integer(retry_after) in 1..div(@window_ms, 1000)
      assert denied.halted
    end

    test "two different IPs each get one allowed request", %{conn: conn} do
      assert login(conn, {10, 0, 0, 2}).status == 401
      assert login(build_conn(), {10, 0, 0, 3}).status == 401
      assert login(build_conn(), {10, 0, 0, 2}).status == 429
      assert login(build_conn(), {10, 0, 0, 3}).status == 429
    end

    test "the 429 keeps the CORS headers set by CORSPlug", %{conn: conn} do
      assert login(conn, {10, 0, 0, 4}).status == 401

      denied =
        build_conn()
        |> put_req_header("origin", "http://localhost:5173")
        |> login({10, 0, 0, 4})

      assert denied.status == 429
      assert [_origin] = get_resp_header(denied, "access-control-allow-origin")
    end

    test "the 429 body matches the too_many_requests_error schema", %{conn: conn} do
      assert login(conn, {10, 0, 0, 5}).status == 401

      body = login(build_conn(), {10, 0, 0, 5}) |> json_response(429)

      assert {:ok, _cast} = OpenApiSpex.cast_value(body, ErrorSchemas.too_many_requests_error())
    end

    test "every 429 is logged at :info with the bucket key", %{conn: conn} do
      assert login(conn, {10, 0, 0, 6}).status == 401

      log =
        capture_info_log(fn ->
          assert login(build_conn(), {10, 0, 0, 6}).status == 429
        end)

      assert log =~ "[info]"
      assert log =~ "login:ip:10.0.0.6"
    end

    test "the six limited operations document 429 in the OpenAPI spec" do
      paths = PidroServerWeb.ApiSpec.spec().paths

      for {path, verb} <- [
            {"/api/v1/auth/register", :post},
            {"/api/v1/auth/login", :post},
            {"/api/v1/auth/password-reset", :post},
            {"/api/v1/auth/password-reset/confirm", :post},
            {"/api/v1/rooms", :post},
            {"/api/v1/rooms/{code}", :get}
          ] do
        operation = Map.fetch!(paths, path) |> Map.fetch!(verb)
        assert Map.has_key?(operation.responses, 429), "#{verb} #{path} lacks a 429 response"
      end
    end
  end

  describe "key kinds" do
    test "a :user policy without current_user falls back to the IP key and warns", %{conn: conn} do
      with_limit(:room_create, 1, @window_ms)

      log =
        capture_log(fn ->
          refute run_plug(from_ip(conn, {10, 0, 3, 1}), [:room_create]).halted
        end)

      assert log =~ "no current_user"

      denied = run_plug(from_ip(build_conn(), {10, 0, 3, 1}), [:room_create])
      assert denied.halted
      assert denied.status == 429
    end

    test "a :user policy keys on the current user, not the address", %{conn: conn} do
      with_limit(:room_create, 1, @window_ms)
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()

      as = fn conn, user, ip -> conn |> from_ip(ip) |> assign(:current_user, user) end

      refute run_plug(as.(conn, user, {10, 0, 3, 2}), [:room_create]).halted
      assert run_plug(as.(build_conn(), user, {10, 0, 3, 3}), [:room_create]).status == 429
      refute run_plug(as.(build_conn(), other, {10, 0, 3, 2}), [:room_create]).halted
    end

    test "an :identifier policy hashes the trimmed lower-cased param", %{conn: conn} do
      with_limit(:password_reset_identifier, 1, @window_ms)
      with_params = fn conn, params -> %{conn | params: params} end

      first =
        conn
        |> from_ip({10, 0, 4, 1})
        |> with_params.(%{"identifier" => "Anna@x.test"})
        |> run_plug([:password_reset_identifier])

      refute first.halted

      log =
        capture_info_log(fn ->
          denied =
            build_conn()
            |> from_ip({10, 0, 4, 2})
            |> with_params.(%{"identifier" => "  anna@x.test  "})
            |> run_plug([:password_reset_identifier])

          assert denied.status == 429
        end)

      expected_hash =
        :sha256
        |> :crypto.hash("anna@x.test")
        |> binary_part(0, 16)
        |> Base.encode16(case: :lower)

      assert log =~ "password_reset_identifier:ident:#{expected_hash}"
      refute log =~ "anna@x.test"
    end

    test "an :identifier policy is skipped when the param is missing, empty or not a binary", %{
      conn: conn
    } do
      with_limit(:password_reset_identifier, 1, @window_ms)
      with_params = fn conn, params -> %{conn | params: params} end
      policies = [:password_reset_identifier]

      log =
        capture_log(fn ->
          for params <- [
                %{},
                %{"identifier" => ""},
                %{"identifier" => "   "},
                %{"identifier" => ["a"]}
              ] do
            refute conn |> with_params.(params) |> run_plug(policies) |> Map.fetch!(:halted)
            refute conn |> with_params.(params) |> run_plug(policies) |> Map.fetch!(:halted)
          end
        end)

      refute log =~ "[error]"
    end

    test "a named-param policy hashes normalized values and isolates different values", %{
      conn: conn
    } do
      with_limit(:invite_page, 1, @window_ms)
      with_params = fn conn, value -> %{conn | params: %{"code" => value}} end

      refute conn |> with_params.("ABCDEF12") |> run_plug([:invite_page]) |> Map.fetch!(:halted)

      denied =
        build_conn()
        |> with_params.("  abcdef12  ")
        |> run_plug([:invite_page])

      assert denied.status == 429

      refute build_conn()
             |> with_params.("OTHER123")
             |> run_plug([:invite_page])
             |> Map.fetch!(:halted)
    end
  end

  describe ":install_id key kind" do
    @install_id "9f1c2a4e-7b3d-4c58-a0e1-2f6d8b9c0a11"
    @policies [:guest_create_install]

    test "one install_id from different addresses shares a bucket and is denied at the limit", %{
      conn: conn
    } do
      with_limit(:guest_create_install, 2, @window_ms)

      refute conn
             |> with_install_id({10, 0, 5, 1}, @install_id)
             |> run_plug(@policies)
             |> Map.fetch!(:halted)

      refute build_conn()
             |> with_install_id({10, 0, 5, 2}, @install_id)
             |> run_plug(@policies)
             |> Map.fetch!(:halted)

      log =
        capture_info_log(fn ->
          denied =
            build_conn() |> with_install_id({10, 0, 5, 3}, @install_id) |> run_plug(@policies)

          assert denied.status == 429
          assert denied.halted
        end)

      expected_hash =
        :sha256
        |> :crypto.hash(@install_id)
        |> binary_part(0, 16)
        |> Base.encode16(case: :lower)

      assert log =~ "guest_create_install:install:#{expected_hash}"
      refute log =~ @install_id

      # A different install from the already-denied address is its own bucket.
      refute build_conn()
             |> with_install_id({10, 0, 5, 3}, "other-install")
             |> run_plug(@policies)
             |> Map.fetch!(:halted)
    end

    test "the policy is skipped when install_id is missing, blank, not a binary or over 64 characters",
         %{conn: conn} do
      with_limit(:guest_create_install, 1, @window_ms)

      log =
        capture_log(fn ->
          for params <- [
                %{},
                %{"install_id" => ""},
                %{"install_id" => "   "},
                %{"install_id" => ["a"]},
                %{"install_id" => String.duplicate("a", 65)}
              ] do
            conn = from_ip(%{conn | params: params}, {10, 0, 5, 4})
            refute conn |> run_plug(@policies) |> Map.fetch!(:halted)
            refute conn |> run_plug(@policies) |> Map.fetch!(:halted)
          end
        end)

      refute log =~ "[error]"
    end

    test "a 64-character install_id is counted after trimming and a longer one is not truncated",
         %{
           conn: conn
         } do
      with_limit(:guest_create_install, 1, @window_ms)
      max_id = String.duplicate("a", 64)

      refute conn
             |> with_install_id({10, 0, 5, 5}, max_id)
             |> run_plug(@policies)
             |> Map.fetch!(:halted)

      padded =
        build_conn() |> with_install_id({10, 0, 5, 6}, "  #{max_id}  ") |> run_plug(@policies)

      assert padded.status == 429

      # Sharing the first 64 characters must not put the longer id in the same bucket.
      refute build_conn()
             |> with_install_id({10, 0, 5, 5}, max_id <> "a")
             |> run_plug(@policies)
             |> Map.fetch!(:halted)
    end
  end

  describe "policy tables" do
    test "config.exs, dev.exs and test.exs declare the same policies with the same key kinds" do
      prod = policy_table(:prod)
      dev = policy_table(:dev)
      test = policy_table(:test)

      assert Keyword.keys(dev) == Keyword.keys(prod)
      assert Keyword.keys(test) == Keyword.keys(prod)

      for {policy, %{limit: limit, scale_ms: scale_ms, key: kind}} <- prod do
        assert dev[policy] == %{limit: limit * 10, scale_ms: scale_ms, key: kind},
               "dev.exs #{policy}"

        assert test[policy] == %{limit: 1_000_000, scale_ms: scale_ms, key: kind},
               "test.exs #{policy}"
      end
    end

    test "every policy in config.exs has _LIMIT and _SCALE_MS overrides in the runtime.exs table" do
      overrides =
        for {{policy, _spec}, index} <- Enum.with_index(policy_table(:prod)),
            {field, offset} <- [limit: 1, scale_ms: 2] do
          env_var = "RATE_LIMIT_#{String.upcase("#{policy}")}_#{String.upcase("#{field}")}"
          {policy, field, env_var, 900_000 + index * 10 + offset}
        end

      for {_policy, _field, env_var, value} <- overrides,
          do: System.put_env(env_var, Integer.to_string(value))

      on_exit(fn ->
        for {_policy, _field, env_var, _value} <- overrides, do: System.delete_env(env_var)
      end)

      merged =
        @config_dir
        |> Path.join("runtime.exs")
        |> Config.Reader.read!(env: :test)
        |> get_in([:pidro_server, RateLimit])

      for {policy, field, env_var, value} <- overrides do
        assert get_in(merged, [policy, field]) == value,
               "#{env_var} did not override #{policy}.#{field}; add it to the runtime.exs table"
      end
    end

    test "install_id is filtered from request logs alongside password" do
      assert Phoenix.Logger.filter_values(%{
               "install_id" => "abc",
               "password" => "pw",
               "display_name" => "Anna"
             }) == %{
               "install_id" => "[FILTERED]",
               "password" => "[FILTERED]",
               "display_name" => "Anna"
             }
    end
  end

  describe "normalize_ip/1 and ip_key/1" do
    test "collapses IPv4-mapped IPv6 and leaves other addresses alone" do
      assert RateLimit.normalize_ip({0, 0, 0, 0, 0, 65_535, 44_050, 2}) == {172, 18, 0, 2}
      assert RateLimit.normalize_ip({172, 18, 0, 2}) == {172, 18, 0, 2}

      assert RateLimit.normalize_ip({0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}
    end

    test "formats IPv4 dotted and IPv6 as its /64 prefix" do
      assert RateLimit.ip_key({203, 0, 113, 9}) == "203.0.113.9"
      assert RateLimit.ip_key({0, 0, 0, 0, 0, 65_535, 0xCB00, 0x7109}) == "203.0.113.9"

      assert RateLimit.ip_key({0x2001, 0xDB8, 0xABCD, 0x1, 0xDEAD, 0xBEEF, 0, 0x9}) ==
               "2001:db8:abcd:1::"
    end
  end

  describe "IP key normalization" do
    setup do
      with_limit(:login, 1, @window_ms)
    end

    test "an IPv4-mapped IPv6 peer shares a bucket with the dotted IPv4 address", %{conn: conn} do
      # ::ffff:192.168.1.1, the shape a dual-stack listener produces
      assert login(conn, {0, 0, 0, 0, 0, 65_535, 0xC0A8, 0x0101}).status == 401
      assert login(build_conn(), {192, 168, 1, 1}).status == 429
    end

    test "two native IPv6 addresses in one /64 share a bucket", %{conn: conn} do
      assert login(conn, {0x2001, 0xDB8, 0xABCD, 0x1, 0, 0, 0, 0x1}).status == 401
      assert login(build_conn(), {0x2001, 0xDB8, 0xABCD, 0x1, 0xFFFF, 0, 0, 0x2}).status == 429
    end

    test "two native IPv6 addresses in different /64s do not share a bucket", %{conn: conn} do
      assert login(conn, {0x2001, 0xDB8, 0xABCD, 0x1, 0, 0, 0, 0x1}).status == 401
      assert login(build_conn(), {0x2001, 0xDB8, 0xABCD, 0x2, 0, 0, 0, 0x1}).status == 401
    end
  end

  describe "routes without a policy" do
    setup do
      with_all_limits(0)
    end

    test "GET /up, GET /api/v1/rooms and GET /api/v1/lobby are never limited", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      assert conn |> from_ip({10, 0, 1, 1}) |> get(~p"/up") |> response(200) == "ok"

      assert build_conn()
             |> from_ip({10, 0, 1, 1})
             |> get(~p"/api/v1/rooms")
             |> json_response(200)

      assert build_conn()
             |> from_ip({10, 0, 1, 1})
             |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
             |> get(~p"/api/v1/lobby")
             |> json_response(200)
    end

    test "a tagged route is denied at limit 0, proving the limit is live", %{conn: conn} do
      assert login(conn, {10, 0, 1, 2}).status == 429
    end
  end

  describe "failure mode" do
    setup do
      with_limit(:login, 1, @window_ms)
      with_failing_limiter()
    end

    test "a raising limiter lets the request through and logs at :error", %{conn: conn} do
      log =
        capture_log(fn ->
          assert login(conn, {10, 0, 2, 1}).status == 401
          assert login(build_conn(), {10, 0, 2, 1}).status == 401
        end)

      assert log =~ "[error]"
      assert log =~ "simulated rate limit backend failure"
    end
  end
end
