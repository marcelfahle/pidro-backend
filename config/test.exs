import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :pidro_server, PidroServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pidro_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pidro_server, PidroServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UBA5CSxpt0JC931WeLp1CYEn/RUuDODXDj7CI3bEzJrWFp5/IDWVttDAy99R9Jxd",
  server: false

# In test we don't send emails
config :pidro_server, PidroServer.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :pidro_server, PidroServer.Games.RoomManager, grace_period_ms: 200

# Use short lifecycle timeouts in tests to avoid slow test runs
config :pidro_server, PidroServer.Games.Lifecycle,
  hiccup_timeout_ms: 100,
  grace_timeout_ms: 200,
  empty_room_ttl_ms: 100,
  finished_room_ttl_ms: 500,
  idle_waiting_ttl_ms: 500,
  reconnect_turn_extension_ms: 50,
  health_check_interval_ms: 500,
  presence_debounce_ms: 50,
  turn_timer_bid_ms: 120,
  turn_timer_play_ms: 90,
  consecutive_timeout_threshold: 3,
  bot_delay_ms: 20,
  bot_delay_variance_ms: 10,
  bot_min_delay_ms: 5,
  trick_transition_delay_ms: 30,
  hand_transition_delay_ms: 40

# Compile dev-only LiveView routes in test to satisfy verified route checks
config :pidro_server, dev_routes: true
