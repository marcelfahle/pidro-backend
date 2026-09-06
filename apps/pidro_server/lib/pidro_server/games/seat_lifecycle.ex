defmodule PidroServer.Games.SeatLifecycle do
  @moduledoc "Resolves snapshot display names in the caller, outside the shared room manager."
  alias PidroServer.Accounts.Auth

  def with_names(snapshot) do
    user_ids =
      snapshot.seats
      |> Map.values()
      |> Enum.flat_map(fn seat -> [seat.player_id, seat.decision && seat.decision.player_id] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    users = Auth.get_users_map(user_ids)

    seats =
      Map.new(snapshot.seats, fn {position, seat} ->
        decision =
          if seat.decision do
            %{
              id: seat.decision.id,
              player_name: player_name(users, seat.decision.player_id)
            }
          end

        username = if seat.player_id, do: player_name(users, seat.player_id), else: seat.username
        {position, %{seat | username: username, decision: decision}}
      end)

    %{snapshot | seats: seats}
  end

  defp player_name(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.display_name || user.username
    end
  end
end
