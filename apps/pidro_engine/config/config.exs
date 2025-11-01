import Config

# Default configuration for the Pidro game engine
config :pidro_engine,
  # Game variant to use (:finnish, :swedish, :danish, :norwegian)
  variant: :finnish,
  # Enable caching of valid moves for performance optimization
  cache_moves: true,
  # Enable game history tracking for undo/replay functionality
  enable_history: true

# Import environment-specific configuration
if File.exists?("#{__DIR__}/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
