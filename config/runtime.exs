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

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

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

  config :pidro_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

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
    secret_key_base: secret_key_base

  # CORS configuration for mobile clients
  # Set CORS_ORIGINS environment variable to comma-separated list of allowed origins
  # Example: "https://app.example.com,https://mobile.example.com"
  # Or set to "*" to allow all origins (not recommended for production)
  cors_origins =
    case System.get_env("CORS_ORIGINS") do
      nil -> :all
      "*" -> :all
      origins -> String.split(origins, ",", trim: true)
    end

  config :pidro_server, :cors_origins, cors_origins

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
