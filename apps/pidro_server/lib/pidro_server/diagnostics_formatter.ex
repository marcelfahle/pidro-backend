defmodule PidroServer.DiagnosticsFormatter do
  @moduledoc "One JSON object per line; diagnostic records never render arbitrary messages or metadata."
  alias PidroServer.Diagnostics

  def format(%{level: level, meta: meta} = event, _config) do
    base = %{
      level: level,
      timestamp: Map.get(meta, :time, System.system_time(:microsecond))
    }

    record =
      case Map.get(meta, :diagnostic) do
        %{event: name} = data ->
          data |> Diagnostics.fields() |> Map.put(:event, Diagnostics.token(name))

        _ ->
          %{message: event |> Logger.Formatter.format_event(4096) |> IO.iodata_to_binary()}
      end

    [Jason.encode!(Map.merge(base, record)), "\n"]
  rescue
    _ -> "{\"level\":\"error\",\"event\":\"log_format_failed\"}\n"
  end
end
