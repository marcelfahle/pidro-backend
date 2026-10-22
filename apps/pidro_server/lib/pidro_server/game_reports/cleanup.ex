defmodule PidroServer.GameReports.Cleanup do
  @moduledoc "One bounded retention batch per minute. No tasks, catch-up loop or queued jobs."
  use GenServer

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:pidro_server, __MODULE__, []), opts)
    interval = Keyword.get(config, :interval_ms, 60_000)
    true = is_integer(interval) and interval > 0
    enabled = Keyword.get(config, :enabled, true)
    if enabled, do: Process.send_after(self(), :cleanup, interval)
    {:ok, %{enabled: enabled, interval: interval}}
  end

  @impl true
  def handle_info(:cleanup, %{enabled: true} = state) do
    cleanup()
    Process.send_after(self(), :cleanup, state.interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp cleanup do
    PidroServer.GameReports.cleanup()
  rescue
    _ -> PidroServer.Diagnostics.emit(:report_cleanup_failed, %{}, :warning)
  catch
    :exit, _ -> PidroServer.Diagnostics.emit(:report_cleanup_failed, %{}, :warning)
  end
end
