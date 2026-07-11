[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # These legacy inline ~H templates still use raw HTML comments. The LiveView
  # formatter turns their blank lines into trailing whitespace; keep them out
  # until those comments are converted to HEEx comments.
  excludes: [
    "lib/pidro_server_web/live/dev/analytics_live.ex",
    "lib/pidro_server_web/live/dev/game_list_live.ex"
  ],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
