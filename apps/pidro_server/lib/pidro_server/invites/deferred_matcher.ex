defmodule PidroServer.Invites.DeferredMatcher do
  @moduledoc """
  Short-lived, node-local storage for deferred invite hints.

  The process stores only a keyed digest of the normalized browser/native
  signature. Candidates disappear when consumed, when the process restarts,
  or when their capture-time retention timer fires.
  """

  use GenServer

  @default_retention_ms :timer.minutes(30)
  @default_max_candidates 10_000
  @key_context "pidro/deferred-invite-matcher/v1"

  @type signature :: %{
          required(:ip) => String.t(),
          required(:platform) => String.t(),
          required(:os_major) => String.t(),
          required(:screen_class) => String.t(),
          required(:locale) => String.t(),
          required(:timezone) => String.t()
        }

  @type capture_result :: :created | :existing | :capacity | :disabled
  @type consume_result :: {:ok, String.t()} | :ambiguous | :none

  def start_link(opts \\ []) do
    config = Application.get_env(:pidro_server, __MODULE__, [])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.merge(config, opts), name: name)
  end

  @spec capture(String.t(), signature(), GenServer.server()) :: capture_result()
  def capture(invite_code, signature, server \\ __MODULE__) do
    GenServer.call(server, {:capture, signature, invite_code})
  end

  @spec consume([signature()], GenServer.server()) :: consume_result()
  def consume(signatures, server \\ __MODULE__) do
    GenServer.call(server, {:consume, signatures})
  end

  @impl true
  def init(opts) do
    secret_key_base =
      Keyword.get_lazy(opts, :secret_key_base, fn ->
        :pidro_server
        |> Application.fetch_env!(PidroServerWeb.Endpoint)
        |> Keyword.fetch!(:secret_key_base)
      end)

    state = %{
      enabled: Keyword.get(opts, :enabled, false),
      retention_ms: Keyword.get(opts, :retention_ms, @default_retention_ms),
      max_candidates: Keyword.get(opts, :max_candidates, @default_max_candidates),
      hmac_key: :crypto.mac(:hmac, :sha256, secret_key_base, @key_context),
      buckets: %{},
      candidate_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:capture, _signature, _invite_code}, _from, %{enabled: false} = state) do
    {:reply, :disabled, state}
  end

  def handle_call({:capture, signature, invite_code}, _from, state) do
    digest = digest(signature, state.hmac_key)
    now = now_ms()
    state = prune_expired(state, now)
    bucket = Map.get(state.buckets, digest, %{})

    cond do
      Map.has_key?(bucket, invite_code) ->
        {:reply, :existing, state}

      state.candidate_count >= state.max_candidates ->
        {:reply, :capacity, state}

      true ->
        token = make_ref()

        timer =
          Process.send_after(self(), {:expire, digest, invite_code, token}, state.retention_ms)

        candidate = %{expires_at: now + state.retention_ms, token: token, timer: timer}
        bucket = Map.put(bucket, invite_code, candidate)

        {:reply, :created,
         %{
           state
           | buckets: Map.put(state.buckets, digest, bucket),
             candidate_count: state.candidate_count + 1
         }}
    end
  end

  def handle_call({:consume, _signatures}, _from, %{enabled: false} = state) do
    {:reply, :none, state}
  end

  def handle_call({:consume, signatures}, _from, state) do
    digests = signatures |> Enum.map(&digest(&1, state.hmac_key)) |> Enum.uniq()
    now = now_ms()
    state = prune_expired(state, now)

    candidates =
      digests
      |> Enum.flat_map(fn digest ->
        state.buckets
        |> Map.get(digest, %{})
        |> Map.keys()
      end)
      |> Enum.uniq()

    state = delete_buckets(state, digests)

    result =
      case candidates do
        [invite_code] -> {:ok, invite_code}
        [] -> :none
        _multiple -> :ambiguous
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:expire, digest, invite_code, token}, state) do
    case get_in(state.buckets, [digest, invite_code]) do
      %{token: ^token} -> {:noreply, delete_candidate(state, digest, invite_code, false)}
      _stale_or_missing -> {:noreply, state}
    end
  end

  defp digest(signature, key) do
    canonical =
      [
        "v1",
        signature.ip,
        signature.platform,
        signature.os_major,
        signature.screen_class,
        signature.locale,
        signature.timezone
      ]
      |> Enum.join(<<0>>)

    :crypto.mac(:hmac, :sha256, key, canonical)
  end

  defp prune_expired(state, now) do
    Enum.reduce(state.buckets, state, fn {digest, bucket}, acc ->
      Enum.reduce(bucket, acc, fn {invite_code, candidate}, inner ->
        if candidate.expires_at <= now do
          delete_candidate(inner, digest, invite_code, true)
        else
          inner
        end
      end)
    end)
  end

  defp delete_buckets(state, digests) do
    Enum.reduce(digests, state, fn digest, acc ->
      acc.buckets
      |> Map.get(digest, %{})
      |> Enum.reduce(acc, fn {invite_code, _candidate}, inner ->
        delete_candidate(inner, digest, invite_code, true)
      end)
    end)
  end

  defp delete_candidate(state, digest, invite_code, cancel_timer?) do
    case get_in(state.buckets, [digest, invite_code]) do
      nil ->
        state

      candidate ->
        if cancel_timer?, do: Process.cancel_timer(candidate.timer, async: true, info: false)

        bucket = state.buckets |> Map.fetch!(digest) |> Map.delete(invite_code)

        buckets =
          if map_size(bucket) == 0,
            do: Map.delete(state.buckets, digest),
            else: Map.put(state.buckets, digest, bucket)

        %{state | buckets: buckets, candidate_count: state.candidate_count - 1}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
