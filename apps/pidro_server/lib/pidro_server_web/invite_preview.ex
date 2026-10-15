defmodule PidroServerWeb.InvitePreview do
  @moduledoc """
  Builds the public, read-only projection of an invite.

  Both the JSON API and the HTML landing page use this module so the state,
  host-name fallback and occupied-seat count cannot drift. The projection
  deliberately returns no room code or user id.
  """

  alias PidroServer.Accounts.Auth
  alias PidroServer.Games.Room.{Config, Positions}
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.Invite

  @type t :: %{
          optional(:game) => map(),
          invite: Invite.t(),
          state: Invites.state(),
          host: String.t() | nil,
          config: Config.t(),
          seats_taken: non_neg_integer(),
          seats: [map()]
        }

  @doc "Returns the public projection for a normalized or display-form invite code."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(code) when is_binary(code) do
    with {:ok, invite} <- Invites.get_by_code(code) do
      {:ok, from_invite(invite)}
    end
  end

  @doc "Builds the public projection for an already-loaded invite."
  @spec from_invite(Invite.t()) :: t()
  def from_invite(%Invite{} = invite) do
    {seats_taken, config, seats, game} =
      case live_room(invite.room_code, invite.room_id) do
        {:ok, room} ->
          {Positions.count(room), room.config, public_seats(room), Room.game_payload(room)}

        {:error, _reason} ->
          {0, %Config{}, [], %{}}
      end

    %{
      invite: invite,
      state: state(invite),
      host: host_name(invite),
      config: config,
      seats: seats,
      seats_taken: seats_taken
    }
    |> Map.merge(game)
  end

  defp public_seats(room) do
    users = PidroServerWeb.API.RoomJSON.users_for_rooms([room])

    [:north, :east, :south, :west]
    |> Enum.with_index()
    |> Enum.map(fn {position, index} ->
      seat = Config.serialize_seat(room.config, room.seats[position])

      %{
        position: position,
        seat_index: index,
        status: if(seat.occupant_type == :vacant, do: "free", else: "occupied"),
        min_games: seat.min_games
      }
      |> Map.merge(Map.take(seat, [:vacated_by, :held_for]))
      |> PidroServerWeb.API.RoomJSON.with_held_user(users)
    end)
  end

  @doc "Derives the invite state against the live RoomManager."
  @spec state(Invite.t()) :: Invites.state()
  def state(%Invite{} = invite), do: Invites.state(invite, &RoomManager.get_room/1)

  @doc "Returns the current invite eligible for an app handoff."
  @spec handoff_target(t()) :: Invite.t() | nil
  def handoff_target(%{state: :moved, invite: %Invite{successor: %Invite{} = successor}}),
    do: successor

  def handoff_target(%{state: :open, invite: %Invite{} = invite}), do: invite
  def handoff_target(_preview), do: nil

  defp host_name(%Invite{host_user_id: host_user_id}) do
    case Auth.get_user(host_user_id) do
      nil -> nil
      user -> user.username
    end
  end

  defp live_room(room_code, room_id) do
    case RoomManager.get_room(room_code) do
      {:ok, %Room{id: ^room_id} = room} -> {:ok, room}
      {:ok, %Room{}} -> {:error, :room_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
