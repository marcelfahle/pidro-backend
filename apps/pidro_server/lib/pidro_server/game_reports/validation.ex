defmodule PidroServer.GameReports.Validation do
  @moduledoc "Exact wire allowlist. There are deliberately no free-text messages or card fields."
  @fields ~w(room_code game_instance_id app_version build platform events)
  @types ~w(tap blocked push timeout state connection lifecycle)
  @codes ~w(ok unavailable illegal_action not_your_turn disconnected reconnecting connected foreground background resumed paused expired stale pending received failed invalid_action invalid_phase card_not_in_hand must_follow_suit stale_readiness game_unavailable invalid_card action_failed)
  @actions ~w(bid pass play_card select_card confirm ready join leave reconnect none declare_trump select_hand select_dealer rematch set_pace continue_hand)

  def validate(params) when is_map(params) do
    with true <- Enum.sort(Map.keys(params)) == Enum.sort(@fields),
         true <- text?(params["game_instance_id"], ~r/\A[A-Za-z0-9_-]{1,64}\z/),
         true <- text?(params["room_code"], ~r/\A[A-Z0-9]{4,12}\z/),
         true <- text?(params["app_version"], ~r/\A[0-9][0-9.\-]{0,31}\z/),
         true <- text?(params["build"], ~r/\A[0-9]{1,20}\z/),
         true <- params["platform"] in ~w(ios android web),
         events when is_list(events) <- params["events"],
         true <- length(events) in 1..100,
         true <- Enum.all?(events, &event?/1) do
      {:ok, Map.new(@fields, &{String.to_existing_atom(&1), params[&1]})}
    else
      _ -> {:error, :invalid_report}
    end
  end

  def validate(_), do: {:error, :invalid_report}

  defp text?(value, regex),
    do: is_binary(value) and byte_size(value) <= 64 and Regex.match?(regex, value)

  defp event?(event) when is_map(event) do
    Enum.all?(Map.keys(event), &(&1 in ~w(action code offset_ms type action_id state_revision))) and
      event["type"] in @types and event["code"] in @codes and
      event["action"] in @actions and is_integer(event["offset_ms"]) and
      event["offset_ms"] in 0..86_400_000 and optional_id?(event) and optional_revision?(event)
  end

  defp event?(_), do: false

  defp optional_id?(%{"action_id" => id}), do: text?(id, ~r/\A[A-Za-z0-9_-]{1,64}\z/)
  defp optional_id?(_), do: true

  defp optional_revision?(%{"state_revision" => revision}),
    do: is_integer(revision) and revision in 0..9_007_199_254_740_991

  defp optional_revision?(_), do: true
end
