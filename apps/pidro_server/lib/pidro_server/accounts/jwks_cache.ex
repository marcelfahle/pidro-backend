defmodule PidroServer.Accounts.JwksCache do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def fetch(url, req_options, ttl_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, url) do
      [{^url, expires_at, keys}] when expires_at > now ->
        {:ok, keys}

      _missing_or_expired ->
        fetch_and_cache(url, req_options, ttl_ms, now)
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  defp fetch_and_cache(url, req_options, ttl_ms, now) do
    case Req.get(url, Keyword.merge([receive_timeout: 5_000], req_options)) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        if ttl_ms > 0, do: :ets.insert(@table, {url, now + ttl_ms, keys})
        {:ok, keys}

      _response ->
        {:error, :provider_unavailable}
    end
  end
end
