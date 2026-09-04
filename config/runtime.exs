import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/pidro_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :pidro_server, PidroServerWeb.Endpoint, server: true
end

config :pidro_server, :admin_seed_email, System.get_env("ADMIN_EMAIL")

# Lifecycle timeout overrides via environment variables.
# These apply in all environments but are primarily useful in production
# to tune disconnect cascade and room lifecycle timers without redeploying.
lifecycle_overrides =
  [
    {:hiccup_timeout_ms, "LIFECYCLE_HICCUP_TIMEOUT_MS"},
    {:grace_timeout_ms, "LIFECYCLE_GRACE_TIMEOUT_MS"},
    {:empty_room_ttl_ms, "LIFECYCLE_EMPTY_ROOM_TTL_MS"},
    {:finished_room_ttl_ms, "LIFECYCLE_FINISHED_ROOM_TTL_MS"},
    {:idle_waiting_ttl_ms, "LIFECYCLE_IDLE_WAITING_TTL_MS"},
    {:invited_waiting_ttl_ms, "LIFECYCLE_INVITED_WAITING_TTL_MS"},
    {:reconnect_turn_extension_ms, "LIFECYCLE_RECONNECT_TURN_EXTENSION_MS"},
    {:health_check_interval_ms, "LIFECYCLE_HEALTH_CHECK_INTERVAL_MS"},
    {:presence_debounce_ms, "LIFECYCLE_PRESENCE_DEBOUNCE_MS"},
    {:turn_timer_bid_ms, "LIFECYCLE_TURN_TIMER_BID_MS"},
    {:turn_timer_play_ms, "LIFECYCLE_TURN_TIMER_PLAY_MS"},
    {:consecutive_timeout_threshold, "LIFECYCLE_CONSECUTIVE_TIMEOUT_THRESHOLD"},
    {:bot_delay_ms, "LIFECYCLE_BOT_DELAY_MS"},
    {:bot_delay_variance_ms, "LIFECYCLE_BOT_DELAY_VARIANCE_MS"},
    {:bot_min_delay_ms, "LIFECYCLE_BOT_MIN_DELAY_MS"},
    {:trick_transition_delay_ms, "LIFECYCLE_TRICK_TRANSITION_DELAY_MS"},
    {:hand_transition_delay_ms, "LIFECYCLE_HAND_TRANSITION_DELAY_MS"}
  ]
  |> Enum.reduce([], fn {key, env_var}, acc ->
    case System.get_env(env_var) do
      nil -> acc
      val -> [{key, String.to_integer(val)} | acc]
    end
  end)

if lifecycle_overrides != [] do
  existing = Application.get_env(:pidro_server, PidroServer.Games.Lifecycle, [])
  config :pidro_server, PidroServer.Games.Lifecycle, Keyword.merge(existing, lifecycle_overrides)
end

# Rate-limit overrides via environment variables: RATE_LIMIT_<POLICY>_LIMIT and
# RATE_LIMIT_<POLICY>_SCALE_MS (for example RATE_LIMIT_LOGIN_LIMIT=20). Limits
# are numeric only; raise a limit instead of looking for an off switch.
rate_limit_overrides =
  [
    {:login, :limit, "RATE_LIMIT_LOGIN_LIMIT"},
    {:login, :scale_ms, "RATE_LIMIT_LOGIN_SCALE_MS"},
    {:register, :limit, "RATE_LIMIT_REGISTER_LIMIT"},
    {:register, :scale_ms, "RATE_LIMIT_REGISTER_SCALE_MS"},
    {:password_reset, :limit, "RATE_LIMIT_PASSWORD_RESET_LIMIT"},
    {:password_reset, :scale_ms, "RATE_LIMIT_PASSWORD_RESET_SCALE_MS"},
    {:password_reset_identifier, :limit, "RATE_LIMIT_PASSWORD_RESET_IDENTIFIER_LIMIT"},
    {:password_reset_identifier, :scale_ms, "RATE_LIMIT_PASSWORD_RESET_IDENTIFIER_SCALE_MS"},
    {:password_reset_confirm, :limit, "RATE_LIMIT_PASSWORD_RESET_CONFIRM_LIMIT"},
    {:password_reset_confirm, :scale_ms, "RATE_LIMIT_PASSWORD_RESET_CONFIRM_SCALE_MS"},
    {:room_create, :limit, "RATE_LIMIT_ROOM_CREATE_LIMIT"},
    {:room_create, :scale_ms, "RATE_LIMIT_ROOM_CREATE_SCALE_MS"},
    {:room_lookup, :limit, "RATE_LIMIT_ROOM_LOOKUP_LIMIT"},
    {:room_lookup, :scale_ms, "RATE_LIMIT_ROOM_LOOKUP_SCALE_MS"},
    {:invite_mint, :limit, "RATE_LIMIT_INVITE_MINT_LIMIT"},
    {:invite_mint, :scale_ms, "RATE_LIMIT_INVITE_MINT_SCALE_MS"},
    {:invite_preview, :limit, "RATE_LIMIT_INVITE_PREVIEW_LIMIT"},
    {:invite_preview, :scale_ms, "RATE_LIMIT_INVITE_PREVIEW_SCALE_MS"},
    {:invite_page, :limit, "RATE_LIMIT_INVITE_PAGE_LIMIT"},
    {:invite_page, :scale_ms, "RATE_LIMIT_INVITE_PAGE_SCALE_MS"},
    {:invite_capture, :limit, "RATE_LIMIT_INVITE_CAPTURE_LIMIT"},
    {:invite_capture, :scale_ms, "RATE_LIMIT_INVITE_CAPTURE_SCALE_MS"},
    {:invite_capture_code, :limit, "RATE_LIMIT_INVITE_CAPTURE_CODE_LIMIT"},
    {:invite_capture_code, :scale_ms, "RATE_LIMIT_INVITE_CAPTURE_CODE_SCALE_MS"},
    {:invite_deferred, :limit, "RATE_LIMIT_INVITE_DEFERRED_LIMIT"},
    {:invite_deferred, :scale_ms, "RATE_LIMIT_INVITE_DEFERRED_SCALE_MS"},
    {:invite_deferred_install, :limit, "RATE_LIMIT_INVITE_DEFERRED_INSTALL_LIMIT"},
    {:invite_deferred_install, :scale_ms, "RATE_LIMIT_INVITE_DEFERRED_INSTALL_SCALE_MS"},
    {:invite_redeem, :limit, "RATE_LIMIT_INVITE_REDEEM_LIMIT"},
    {:invite_redeem, :scale_ms, "RATE_LIMIT_INVITE_REDEEM_SCALE_MS"},
    {:guest_create, :limit, "RATE_LIMIT_GUEST_CREATE_LIMIT"},
    {:guest_create, :scale_ms, "RATE_LIMIT_GUEST_CREATE_SCALE_MS"},
    {:guest_create_daily, :limit, "RATE_LIMIT_GUEST_CREATE_DAILY_LIMIT"},
    {:guest_create_daily, :scale_ms, "RATE_LIMIT_GUEST_CREATE_DAILY_SCALE_MS"},
    {:guest_create_install, :limit, "RATE_LIMIT_GUEST_CREATE_INSTALL_LIMIT"},
    {:guest_create_install, :scale_ms, "RATE_LIMIT_GUEST_CREATE_INSTALL_SCALE_MS"},
    {:room_join, :limit, "RATE_LIMIT_ROOM_JOIN_LIMIT"},
    {:room_join, :scale_ms, "RATE_LIMIT_ROOM_JOIN_SCALE_MS"},
    {:auth_upgrade, :limit, "RATE_LIMIT_AUTH_UPGRADE_LIMIT"},
    {:auth_upgrade, :scale_ms, "RATE_LIMIT_AUTH_UPGRADE_SCALE_MS"}
  ]
  |> Enum.reduce([], fn {policy, field, env_var}, acc ->
    case System.get_env(env_var) do
      nil -> acc
      val -> [{policy, field, String.to_integer(val)} | acc]
    end
  end)

if rate_limit_overrides != [] do
  existing = Application.get_env(:pidro_server, PidroServerWeb.Plugs.RateLimit, [])

  merged =
    Enum.reduce(rate_limit_overrides, existing, fn {policy, field, value}, acc ->
      Keyword.update!(acc, policy, &Map.put(&1, field, value))
    end)

  config :pidro_server, PidroServerWeb.Plugs.RateLimit, merged
end

# Proxy header trust for PidroServerWeb.Plugs.TrustedProxy. Production runs
# behind kamal-proxy, so the default is true there and false everywhere else.
# TRUST_PROXY_HEADERS=false makes the rate limiter key on the TCP peer instead.
trust_proxy_default = if config_env() == :prod, do: "true", else: "false"

config :pidro_server,
  trust_proxy_headers:
    System.get_env("TRUST_PROXY_HEADERS", trust_proxy_default) in ~w(true TRUE 1 yes YES)

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      case {
        System.get_env("DB_HOST"),
        System.get_env("DB_NAME"),
        System.get_env("DB_USER"),
        System.get_env("DB_PASSWORD") || System.get_env("POSTGRES_PASSWORD")
      } do
        {host, database, user, password}
        when is_binary(host) and is_binary(database) and is_binary(user) and is_binary(password) ->
          port = System.get_env("DB_PORT") || "5432"

          "ecto://#{URI.encode_www_form(user)}:#{URI.encode_www_form(password)}@#{host}:#{port}/#{database}"

        _ ->
          raise """
          environment variable DATABASE_URL is missing.
          Set DATABASE_URL directly, or provide DB_HOST, DB_PORT, DB_NAME, DB_USER, and DB_PASSWORD.
          """
      end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :pidro_server, PidroServer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  cors_origins =
    case System.get_env("CORS_ORIGINS") do
      nil ->
        raise "environment variable CORS_ORIGINS is missing"

      "*" ->
        :all

      origins ->
        origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  check_origin =
    case cors_origins do
      :all ->
        false

      origins when is_list(origins) ->
        ["https://#{host}", "http://#{host}" | origins]
        |> Enum.uniq()
    end

  config :pidro_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :pidro_server, :cors_origins, cors_origins

  config :pidro_server, PidroServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :pidro_server, PidroServerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :pidro_server, PidroServerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :pidro_server, PidroServer.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

# ---------------------------------------------------------------------------
# Well-known association files (AASA / assetlinks.json) env overrides.
#
# Applies in every environment. Defaults live in config/config.exs; each
# variable below replaces its list only when set, and a set value is validated
# at boot by PidroServerWeb.WellKnownController.env_overrides/1 (fingerprints
# are upper-cased and must be 32 colon-separated hex pairs; malformed values
# raise). An unset variable is never an error.
#
#   AASA_APP_IDS  comma list, e.g. "LSFK7YF82G.com.oneapps.pidro,LSFK7YF82G.com.example.dev"
#   AASA_PATHS    comma list, e.g. "/j/*,/app/*"
#   ASSETLINKS    "package:fp1|fp2,package2:fp3" with SHA-256 cert fingerprints
#
# Gated on the variables being present and the module being loadable: this
# runtime.exs is shared by every umbrella app, and PidroServerWeb only exists
# on pidro_server's code path (mix tasks run inside apps/pidro_engine skip it).
# ---------------------------------------------------------------------------
well_known_env = Map.take(System.get_env(), ["AASA_APP_IDS", "AASA_PATHS", "ASSETLINKS"])

if well_known_env != %{} and Code.ensure_loaded?(PidroServerWeb.WellKnownController) do
  well_known_existing =
    Application.get_env(:pidro_server, PidroServerWeb.WellKnownController, [])

  well_known_overrides = PidroServerWeb.WellKnownController.env_overrides(well_known_env)

  config :pidro_server,
         PidroServerWeb.WellKnownController,
         Keyword.merge(well_known_existing, well_known_overrides)
end

# ---------------------------------------------------------------------------
# Invite link base (PidroServer.Invites.url/1) env override.
#
# Applies in every environment. Defaults live in config/config.exs and the
# per-environment files; INVITE_LINK_BASE_URL replaces `link_base_url` only
# when set, e.g. "https://www.pidro.online/j". Gated like the well-known block
# above: runtime.exs is shared by every umbrella app, and PidroServer.Invites
# only exists on pidro_server's code path.
# ---------------------------------------------------------------------------
invite_link_base_url = System.get_env("INVITE_LINK_BASE_URL")

if invite_link_base_url not in [nil, ""] and Code.ensure_loaded?(PidroServer.Invites) do
  invites_existing = Application.get_env(:pidro_server, PidroServer.Invites, [])

  config :pidro_server,
         PidroServer.Invites,
         Keyword.put(invites_existing, :link_base_url, invite_link_base_url)
end

# ---------------------------------------------------------------------------
# Idle-guest reaper (PidroServer.Accounts.GuestReaper) env overrides.
#
# Applies in every environment. Defaults live in config/config.exs and
# config/test.exs; each variable replaces its key only when set:
#
#   GUEST_REAPER_ENABLED        true/false (the boolean idiom used above)
#   GUEST_REAPER_INTERVAL_MS    milliseconds between sweeps
#   GUEST_REAPER_MAX_IDLE_DAYS  days since last_seen_at (or inserted_at)
#
# Gated like the blocks above: runtime.exs is shared by every umbrella app,
# and the reaper only exists on pidro_server's code path.
# ---------------------------------------------------------------------------
guest_reaper_overrides =
  [
    {:enabled, "GUEST_REAPER_ENABLED", &(&1 in ~w(true TRUE 1 yes YES))},
    {:interval_ms, "GUEST_REAPER_INTERVAL_MS", &String.to_integer/1},
    {:max_idle_days, "GUEST_REAPER_MAX_IDLE_DAYS", &String.to_integer/1}
  ]
  |> Enum.reduce([], fn {key, env_var, parse}, acc ->
    case System.get_env(env_var) do
      nil -> acc
      val -> [{key, parse.(val)} | acc]
    end
  end)

if guest_reaper_overrides != [] and Code.ensure_loaded?(PidroServer.Accounts.GuestReaper) do
  guest_reaper_existing =
    Application.get_env(:pidro_server, PidroServer.Accounts.GuestReaper, [])

  config :pidro_server,
         PidroServer.Accounts.GuestReaper,
         Keyword.merge(guest_reaper_existing, guest_reaper_overrides)
end

# Deferred invite matching stays disabled until the public privacy disclosure
# is deployed and verified. Matching data is always node-local and the fixed
# application retention remains 30 minutes; only the feature gate is runtime
# configurable.
deferred_invites_enabled = System.get_env("DEFERRED_INVITES_ENABLED")

if deferred_invites_enabled != nil and
     Code.ensure_loaded?(PidroServer.Invites.DeferredMatcher) do
  deferred_matcher_existing =
    Application.get_env(:pidro_server, PidroServer.Invites.DeferredMatcher, [])

  config :pidro_server,
         PidroServer.Invites.DeferredMatcher,
         Keyword.put(
           deferred_matcher_existing,
           :enabled,
           deferred_invites_enabled in ~w(true TRUE 1 yes YES)
         )
end
