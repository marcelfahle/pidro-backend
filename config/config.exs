# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pidro_server, ecto_repos: [PidroServer.Repo]

config :pidro_server, PidroServer.Games.RoomManager, grace_period_ms: 120_000

# Lifecycle timeouts for the disconnect cascade and room lifecycle.
# All values are in milliseconds. Override per-environment or via env vars in runtime.exs.
config :pidro_server, PidroServer.Games.Lifecycle,
  hiccup_timeout_ms: 20_000,
  grace_timeout_ms: 120_000,
  empty_room_ttl_ms: 30_000,
  finished_room_ttl_ms: 300_000,
  idle_waiting_ttl_ms: 600_000,
  reconnect_turn_extension_ms: 10_000,
  health_check_interval_ms: 60_000,
  presence_debounce_ms: 3_000,
  turn_timer_bid_ms: 45_000,
  turn_timer_play_ms: 30_000,
  consecutive_timeout_threshold: 3,
  bot_delay_ms: 1_500,
  bot_delay_variance_ms: 800,
  bot_min_delay_ms: 300,
  trick_transition_delay_ms: 1_500,
  hand_transition_delay_ms: 3_000

# Rate-limit policies for PidroServerWeb.Plugs.RateLimit: `limit` requests per
# `scale_ms` window, keyed by the client address (:ip), the authenticated user
# (:user) or the hashed identifier/email param (:identifier). Numeric only, no
# boolean off switch. config/dev.exs restates every policy at 10x for the
# frontend end-to-end harness, config/test.exs sets 1_000_000, and
# config/runtime.exs merges RATE_LIMIT_<POLICY>_LIMIT / _SCALE_MS overrides.
config :pidro_server, PidroServerWeb.Plugs.RateLimit,
  login: %{limit: 10, scale_ms: 60_000, key: :ip},
  register: %{limit: 10, scale_ms: 600_000, key: :ip},
  password_reset: %{limit: 3, scale_ms: 900_000, key: :ip},
  password_reset_identifier: %{limit: 3, scale_ms: 3_600_000, key: :identifier},
  password_reset_confirm: %{limit: 5, scale_ms: 900_000, key: :ip},
  room_create: %{limit: 10, scale_ms: 60_000, key: :user},
  room_lookup: %{limit: 120, scale_ms: 60_000, key: :ip}

# PidroServerWeb.Plugs.TrustedProxy honours X-Forwarded-For / X-Forwarded-Proto
# only when this is true and the TCP peer is proxy-side. config/runtime.exs sets
# it from TRUST_PROXY_HEADERS (default true in prod, false everywhere else).
config :pidro_server, trust_proxy_headers: false

# Skill-tier thresholds (PID-48). Bands are read off Rating.ordinal/1 (mu - 3*sigma).
# Launch defaults, tunable — NOT finely calibrated; recalibrate against the real
# ordinal distribution.
#
# Provisional clears once EITHER gate opens: games_count >= provisional_min_games
# OR sigma < provisional_max_sigma. Games-count is the reliable driver — OpenSkill
# sigma floors ~6.06 with the default model, so a sub-6.06 sigma gate would never
# clear; provisional_max_sigma sits just above the floor as a fast-converger early
# out, while min_games guarantees everyone reaches a real band after 10 rated games.
# provisional_max_sigma stays below the 8.333 schema default so never-rated users
# remain provisional.
config :pidro_server, PidroServer.Rating.Tier,
  provisional_min_games: 10,
  provisional_max_sigma: 6.5,
  bronze_min: 0.0,
  silver_min: 10.0,
  gold_min: 18.0,
  platinum_min: 26.0,
  master_min: 34.0

# Veteran progression (PID-49). XP curve + bonuses + milestone titles. win_bonus
# 50 is the proven legacy Pidro 1 value (so PID-53 imports earn the same totals);
# extra_bonus is the events lever (flat, no streaks yet). titles are launch
# PLACEHOLDERS, not final copy — tunable. The curve is a re-paced power law
# (threshold(level) = round(curve_coefficient * level ** curve_exponent)),
# data-calibrated against Pidro 1: L100 caps at 800k XP, then Prestige adds one
# star per prestige_step (500k) XP past the cap (top player 5.0M → ★8). Set
# `thresholds:` to override the level boundaries verbatim.
config :pidro_server, PidroServer.Progression,
  win_bonus: 50,
  extra_bonus: 0,
  max_level: 100,
  curve_coefficient: 80,
  curve_exponent: 2.0,
  prestige_step: 500_000,
  # thresholds: nil,  # optional explicit ascending list; nil = generate from params
  titles: %{
    1 => "Rookie",
    5 => "Apprentice",
    10 => "Journeyman",
    20 => "Veteran",
    35 => "Expert",
    50 => "Master",
    75 => "Grandmaster",
    100 => "Legend"
  }

# Configures the endpoint
config :pidro_server, PidroServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PidroServerWeb.ErrorHTML, json: PidroServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PidroServer.PubSub,
  live_view: [signing_salt: "9OPTkHQU"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pidro_server, PidroServer.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.1",
  pidro_server: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/pidro_server/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.2",
  pidro_server: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/pidro_server", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
