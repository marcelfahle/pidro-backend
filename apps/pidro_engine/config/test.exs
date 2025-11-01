import Config

# Test-specific configuration for the Pidro game engine
config :pidro_engine,
  # Disable move caching in tests for deterministic behavior
  cache_moves: false,
  # Keep history enabled for testing history-related functionality
  enable_history: true
