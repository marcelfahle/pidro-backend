defmodule PidroServer.Accounts.GuestReaper do
  @moduledoc """
  Deletes idle guest accounts on a schedule (R17).

  A guest whose `last_seen_at` (or `inserted_at` when the guest was never
  seen) is older than `max_idle_days` is removed with
  `PidroServer.Accounts.Auth.delete_user/1`, the same recipe as
  `DELETE /api/v1/auth/me`, in batches of 100 ids per query.

  ## Configuration

      config :pidro_server, PidroServer.Accounts.GuestReaper,
        enabled: true,
        interval_ms: 3_600_000,
        max_idle_days: 30

  `start_link/1` options override the application config. When `enabled` is
  false the process starts but never schedules a run; `run_once/0` still
  works for a caller that wants a synchronous sweep.

  `config/test.exs` disables the reaper: the test suite runs every query in
  an `Ecto.Adapters.SQL.Sandbox` transaction owned by the test process, and a
  timer-driven sweep from this process would have no sandbox owner, so it
  would raise on its first query and could otherwise delete a guest some
  other test is using. Tests call `run_once/0` from their own process.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias PidroServer.Accounts.Auth
  alias PidroServer.Accounts.User
  alias PidroServer.Repo

  @batch_size 100
  @day_in_seconds 24 * 60 * 60
  @defaults [enabled: true, interval_ms: 3_600_000, max_idle_days: 30]

  @doc """
  Starts the reaper. `opts` override the application config; `name` defaults
  to the module and may be `nil` for an unregistered instance.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs one synchronous sweep in the calling process and answers the number
  of guests deleted.
  """
  @spec run_once() :: {:ok, non_neg_integer()}
  def run_once do
    cutoff = idle_cutoff(config()[:max_idle_days])
    reap_batches(cutoff, 0)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(config(), opts)
    enabled? = config[:enabled] == true
    interval_ms = config[:interval_ms]

    timer = if enabled?, do: schedule(interval_ms), else: nil

    {:ok, %{enabled?: enabled?, interval_ms: interval_ms, timer: timer}}
  end

  @impl true
  def handle_info(:reap, %{enabled?: true} = state) do
    sweep()
    {:noreply, %{state | timer: schedule(state.interval_ms)}}
  end

  def handle_info(:reap, state), do: {:noreply, state}

  defp sweep do
    case run_once() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("GuestReaper deleted #{count} idle guest account(s)")
    end
  rescue
    exception ->
      Logger.error("GuestReaper sweep failed: " <> Exception.message(exception))
      :error
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :reap, interval_ms)

  defp config, do: Keyword.merge(@defaults, Application.get_env(:pidro_server, __MODULE__, []))

  defp idle_cutoff(max_idle_days) do
    DateTime.add(DateTime.utc_now(), -max_idle_days * @day_in_seconds, :second)
  end

  # Deletes one batch and continues only while a full batch was fully
  # deleted, so a row that keeps failing cannot be re-selected forever.
  defp reap_batches(cutoff, deleted_so_far) do
    ids = stale_guest_ids(cutoff)
    deleted = Enum.count(ids, &delete_guest/1)
    total = deleted_so_far + deleted

    if length(ids) == @batch_size and deleted == @batch_size do
      reap_batches(cutoff, total)
    else
      {:ok, total}
    end
  end

  defp stale_guest_ids(cutoff) do
    Repo.all(
      from(u in User,
        where: u.guest == true and coalesce(u.last_seen_at, u.inserted_at) < ^cutoff,
        order_by: [asc: u.inserted_at, asc: u.id],
        limit: @batch_size,
        select: u.id
      )
    )
  end

  defp delete_guest(id) do
    case Auth.get_user(id) do
      %User{guest: true} = guest -> match?({:ok, _}, Auth.delete_user(guest))
      _upgraded_or_gone -> false
    end
  end
end
