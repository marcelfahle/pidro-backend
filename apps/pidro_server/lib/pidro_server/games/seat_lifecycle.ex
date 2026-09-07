defmodule PidroServer.Games.SeatLifecycle do
  @moduledoc "Resolves snapshot account names in the caller, outside the shared room manager."
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
              player_name: username(users, seat.decision.player_id)
            }
          end

        resolved_seat =
          if seat.player_id do
            seat
            |> Map.put(:username, username(users, seat.player_id))
            |> Map.put(:display_name, display_name(users, seat.player_id))
            |> Map.put(:avatar_url, avatar_url(users, seat.player_id))
          else
            # Preserve the lifecycle's own bot name rather than attempting an
            # account lookup for vacant and permanent-bot seats.
            seat
            |> Map.put(:display_name, seat.username)
            |> Map.put(:avatar_url, nil)
          end

        {position, %{resolved_seat | decision: decision}}
      end)

    %{snapshot | seats: seats}
  end

  defp username(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.username
    end
  end

  defp display_name(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.display_name
    end
  end

  defp avatar_url(users, user_id) do
    case Map.get(users, user_id) do
      nil -> nil
      user -> user.avatar_url
    end
  end
end
