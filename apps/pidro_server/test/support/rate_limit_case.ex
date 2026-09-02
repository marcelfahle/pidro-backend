defmodule PidroServerWeb.RateLimitCase do
  @moduledoc """
  Helpers for rate-limit tests.

      use PidroServerWeb.ConnCase, async: false
      use PidroServerWeb.RateLimitCase

      test "login at limit 1", %{conn: conn} do
        with_limit(:login, 1, 60_000)
        ...
      end

  `use` imports the helpers and adds a `setup` that clears the Hammer table
  before each test and restores the policy config in `on_exit`, so
  `with_limit/3`, `with_all_limits/1` and `with_failing_limiter/0` need no
  cleanup of their own.

  The `setup`/`on_exit` registration is expanded into the test module on
  purpose: this file is dialyzed with the application, the umbrella PLT has no
  `:ex_unit`, and `dialyzer.ignore-warnings` pins the existing support files by
  line, so this module must not call ExUnit itself. It also lives outside
  `ConnCase` and `ChannelCase` for the same reason.

  Tests that `use` this module must be `async: false`: the Hammer ETS table and
  the policy config are shared by the whole node.
  """

  @config_key PidroServerWeb.Plugs.RateLimit
  @table PidroServer.RateLimit

  defmacro __using__(_opts) do
    quote do
      import PidroServerWeb.RateLimitCase

      setup do
        PidroServerWeb.RateLimitCase.reset()
        original = PidroServerWeb.RateLimitCase.policies()
        on_exit(fn -> PidroServerWeb.RateLimitCase.put_policies(original) end)
        :ok
      end
    end
  end

  @doc """
  The current policy config, as `PidroServerWeb.Plugs.RateLimit` reads it.
  """
  @spec policies() :: keyword()
  def policies, do: Application.fetch_env!(:pidro_server, @config_key)

  @doc """
  Replaces the policy config. The `use` setup calls this on exit to restore
  the config captured before the test.
  """
  @spec put_policies(keyword()) :: :ok
  def put_policies(config), do: Application.put_env(:pidro_server, @config_key, config)

  @doc """
  Sets `limit` and `scale_ms` for one policy for the rest of the test.
  """
  @spec with_limit(atom(), non_neg_integer(), pos_integer()) :: :ok
  def with_limit(policy, limit, scale_ms) do
    update_policies(fn config ->
      Keyword.update!(config, policy, &%{&1 | limit: limit, scale_ms: scale_ms})
    end)
  end

  @doc """
  Sets every policy's `limit` for the rest of the test. `with_all_limits(0)`
  proves a route is not limited at all.
  """
  @spec with_all_limits(non_neg_integer()) :: :ok
  def with_all_limits(limit) do
    update_policies(fn config ->
      Enum.map(config, fn
        {policy, %{limit: _} = spec} -> {policy, %{spec | limit: limit}}
        other -> other
      end)
    end)
  end

  @doc """
  Swaps the limiter for this module, whose `hit/3` raises, to simulate a
  failing backend without touching the Hammer ETS table (deleting the table
  would crash Hammer's cleanup process).
  """
  @spec with_failing_limiter() :: :ok
  def with_failing_limiter do
    update_policies(&Keyword.put(&1, :limiter, __MODULE__))
  end

  @doc false
  @spec hit(term(), pos_integer(), non_neg_integer()) :: no_return()
  def hit(_key, _scale_ms, _limit) do
    raise ArgumentError, "simulated rate limit backend failure"
  end

  @doc """
  Clears every counter without deleting the Hammer table itself.
  """
  @spec reset() :: :ok
  def reset do
    true = :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Sets the peer address the limiter keys on.
  """
  @spec from_ip(Plug.Conn.t(), :inet.ip_address()) :: Plug.Conn.t()
  def from_ip(%Plug.Conn{} = conn, ip) when is_tuple(ip), do: %{conn | remote_ip: ip}

  defp update_policies(fun), do: put_policies(fun.(policies()))
end
