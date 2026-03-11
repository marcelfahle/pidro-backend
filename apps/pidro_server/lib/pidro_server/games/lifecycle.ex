defmodule PidroServer.Games.Lifecycle do
  @moduledoc """
  Centralized configuration for all timeout values in the disconnect cascade
  and room lifecycle.

  All values are in milliseconds and can be overridden via application config:

      config :pidro_server, PidroServer.Games.Lifecycle,
        hiccup_timeout_ms: 20_000

  Or via environment variables in runtime.exs for production tuning.
  """

  @type timeout_key ::
          :hiccup_timeout_ms
          | :grace_timeout_ms
          | :empty_room_ttl_ms
          | :finished_room_ttl_ms
          | :idle_waiting_ttl_ms
          | :reconnect_turn_extension_ms
          | :health_check_interval_ms
          | :presence_debounce_ms
          | :turn_timer_bid_ms
          | :turn_timer_play_ms
          | :consecutive_timeout_threshold
          | :bot_delay_ms
          | :bot_delay_variance_ms
          | :bot_min_delay_ms
          | :trick_transition_delay_ms
          | :hand_transition_delay_ms

  @defaults %{
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
  }

  @doc """
  Returns the configured value for the given timeout key, falling back to the
  built-in default if no override is set.

  ## Examples

      iex> PidroServer.Games.Lifecycle.config(:hiccup_timeout_ms)
      20_000

      iex> PidroServer.Games.Lifecycle.config(:grace_timeout_ms)
      120_000
  """
  @spec config(timeout_key()) :: non_neg_integer()
  def config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end

  @doc """
  Returns the full map of default timeout values.
  """
  @spec defaults() :: %{timeout_key() => non_neg_integer()}
  def defaults, do: @defaults
end
