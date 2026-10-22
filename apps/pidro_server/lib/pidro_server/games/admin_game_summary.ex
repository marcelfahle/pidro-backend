defmodule PidroServer.Games.AdminGameSummary do
  @moduledoc """
  Node-local, latest-only operational summaries in the existing game Registry.
  No cards or action arguments are retained. Only the registered game process
  can update its metadata; stopping it automatically removes its summary.
  Connected admin views sample the Registry's ETS; lobby lifecycle uses PubSub.
  """
  alias PidroServer.Games.GameRegistry

  @doc "Projects an engine snapshot in the publisher process, without a message queue."
  @spec record(String.t(), map()) :: :ok
  def record(code, state) do
    summary = %{
      phase: state.phase,
      current_turn: state.current_turn,
      trick_number: state.trick_number,
      cumulative_scores: state.cumulative_scores,
      hand_number: state.hand_number,
      pace: Map.get(state.config, :pace, :quick),
      last_event: event_name(List.last(state.events))
    }

    # Presentation-only broadcasts must not pretend that somebody just moved.
    Registry.update_value(GameRegistry, code, fn previous ->
      if is_map(previous) and Map.delete(previous, :updated_at) == summary,
        do: previous,
        else: Map.put(summary, :updated_at, DateTime.utc_now())
    end)

    :ok
  rescue
    # Observability must not make a game fail during supervisor restart.
    ArgumentError -> :ok
  end

  @doc "Returns only the current game's summary, never an earlier rematch's cache."
  @spec get(String.t()) :: map() | nil
  def get(code) do
    case Registry.lookup(GameRegistry, code) do
      [{_pid, summary}] when is_map(summary) -> summary
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp event_name(nil), do: "Game started"
  defp event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp event_name(%{type: type}), do: to_string(type)
  defp event_name(_), do: "State changed"
end
