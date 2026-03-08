defmodule PidroServer.Games.LifecycleTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Lifecycle

  @all_keys [
    :hiccup_timeout_ms,
    :grace_timeout_ms,
    :empty_room_ttl_ms,
    :finished_room_ttl_ms,
    :idle_waiting_ttl_ms,
    :reconnect_turn_extension_ms,
    :health_check_interval_ms,
    :presence_debounce_ms
  ]

  @expected_defaults %{
    hiccup_timeout_ms: 20_000,
    grace_timeout_ms: 120_000,
    empty_room_ttl_ms: 30_000,
    finished_room_ttl_ms: 300_000,
    idle_waiting_ttl_ms: 600_000,
    reconnect_turn_extension_ms: 10_000,
    health_check_interval_ms: 60_000,
    presence_debounce_ms: 3_000
  }

  describe "config/1" do
    test "returns default values when no config override is set" do
      for key <- @all_keys do
        assert Lifecycle.config(key) == @expected_defaults[key],
               "expected default for #{key} to be #{@expected_defaults[key]}, got #{Lifecycle.config(key)}"
      end
    end

    test "returns overridden value when Application config is set" do
      Application.put_env(:pidro_server, Lifecycle, hiccup_timeout_ms: 5_000)

      on_exit(fn ->
        Application.delete_env(:pidro_server, Lifecycle)
      end)

      assert Lifecycle.config(:hiccup_timeout_ms) == 5_000
    end

    test "non-overridden keys still return defaults when some keys are overridden" do
      Application.put_env(:pidro_server, Lifecycle, grace_timeout_ms: 60_000)

      on_exit(fn ->
        Application.delete_env(:pidro_server, Lifecycle)
      end)

      assert Lifecycle.config(:grace_timeout_ms) == 60_000
      assert Lifecycle.config(:hiccup_timeout_ms) == 20_000
      assert Lifecycle.config(:empty_room_ttl_ms) == 30_000
    end

    test "raises FunctionClauseError for unknown keys" do
      assert_raise FunctionClauseError, fn ->
        Lifecycle.config(:nonexistent_key)
      end
    end
  end

  describe "defaults/0" do
    test "returns all 8 timeout keys" do
      defaults = Lifecycle.defaults()
      assert map_size(defaults) == 8

      for key <- @all_keys do
        assert Map.has_key?(defaults, key), "missing key: #{key}"
      end
    end

    test "returns expected default values" do
      assert Lifecycle.defaults() == @expected_defaults
    end

    test "all values are positive integers" do
      for {key, value} <- Lifecycle.defaults() do
        assert is_integer(value) and value > 0,
               "expected #{key} to be a positive integer, got #{inspect(value)}"
      end
    end
  end
end
