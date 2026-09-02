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
  false the process starts but never schedules a run; `run_once/1` still
  works for a caller that wants a synchronous sweep. Both timing values must
  be positive integers; invalid runtime configuration fails application boot.

  `config/test.exs` disables the reaper: the test suite runs every query in
  an `Ecto.Adapters.SQL.Sandbox` transaction owned by the test process, and a
  timer-driven sweep from this process would have no sandbox owner, so it
  would raise on its first query and could otherwise delete a guest some
  other test is using. Tests call `run_once/1` from their own process.
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
  of guests deleted. `opts[:max_idle_days]` overrides the configured cutoff;
  `opts[:delete_guest]` is a deletion callback used by focused tests.
  """
  @spec run_once(keyword()) :: {:ok, non_neg_integer()}
  def run_once(opts \\ []) when is_list(opts) do
    {delete_guest, opts} = Keyword.pop(opts, :delete_guest, &delete_guest/1)
    config = config() |> Keyword.merge(opts) |> validate_config!()
    cutoff = idle_cutoff(config[:max_idle_days])
    reap_batches(cutoff, 0, MapSet.new(), delete_guest)
  end

  @impl true
  def init(opts) do
    config = config() |> Keyword.merge(opts) |> validate_config!()
    enabled? = config[:enabled] == true
    interval_ms = config[:interval_ms]
    max_idle_days = config[:max_idle_days]

    timer = if enabled?, do: schedule(interval_ms), else: nil

    {:ok,
     %{
       enabled?: enabled?,
       interval_ms: interval_ms,
       max_idle_days: max_idle_days,
       timer: timer
     }}
  end

  @impl true
  def handle_info(:reap, %{enabled?: true} = state) do
    sweep(state.max_idle_days)
    {:noreply, %{state | timer: schedule(state.interval_ms)}}
  end

  def handle_info(:reap, state), do: {:noreply, state}

  defp sweep(max_idle_days) do
    case run_once(max_idle_days: max_idle_days) do
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

  defp validate_config!(config) do
    validate_positive_integer!(config, :interval_ms)
    validate_positive_integer!(config, :max_idle_days)
    config
  end

  defp validate_positive_integer!(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, value} ->
        raise ArgumentError,
              "GuestReaper #{key} must be a positive integer, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "GuestReaper #{key} is required"
    end
  end

  defp idle_cutoff(max_idle_days) do
    DateTime.add(DateTime.utc_now(), -max_idle_days * @day_in_seconds, :second)
  end

  # Failed rows are excluded for the rest of this sweep so one bad account
  # cannot prevent later batches from being processed.
  defp reap_batches(cutoff, deleted_so_far, failed_ids, delete_guest) do
    ids = stale_guest_ids(cutoff, failed_ids)

    {deleted, failed_ids} =
      Enum.reduce(ids, {0, failed_ids}, fn id, {deleted, failed_ids} ->
        if delete_guest.(id) do
          {deleted + 1, failed_ids}
        else
          {deleted, MapSet.put(failed_ids, id)}
        end
      end)

    total = deleted_so_far + deleted

    if length(ids) == @batch_size do
      reap_batches(cutoff, total, failed_ids, delete_guest)
    else
      {:ok, total}
    end
  end

  defp stale_guest_ids(cutoff, failed_ids) do
    query =
      from(u in User,
        where: u.guest == true and coalesce(u.last_seen_at, u.inserted_at) < ^cutoff,
        order_by: [asc: fragment("COALESCE(?, ?)", u.last_seen_at, u.inserted_at), asc: u.id],
        limit: @batch_size,
        select: u.id
      )

    query =
      if MapSet.size(failed_ids) == 0 do
        query
      else
        where(query, [u], u.id not in ^MapSet.to_list(failed_ids))
      end

    Repo.all(query)
  end

  defp delete_guest(id) do
    case Auth.get_user(id) do
      %User{guest: true} = guest ->
        case Auth.delete_user(guest) do
          {:ok, _deleted} ->
            true

          {:error, reason} ->
            Logger.error("GuestReaper could not delete guest #{id}: #{inspect(reason)}")
            false
        end

      _upgraded_or_gone ->
        false
    end
  rescue
    exception ->
      Logger.error("GuestReaper could not delete guest #{id}: #{Exception.message(exception)}")
      false
  catch
    kind, reason ->
      Logger.error("GuestReaper could not delete guest #{id}: #{inspect({kind, reason})}")
      false
  end
end
