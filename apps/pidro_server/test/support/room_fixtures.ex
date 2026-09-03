defmodule PidroServer.RoomFixtures do
  @moduledoc """
  Test helpers that build rooms through the public `PidroServer.Games.RoomManager`
  API only, so fixtures exercise the same code paths as clients.

  The RoomManager must already be running (the RoomManager test setup starts it
  and resets it between tests); nothing here is cleaned up.
  """

  alias PidroServer.Games.RoomManager

  @doc """
  Creates a `:waiting` room with `seated` connected humans (1 to 3; four would
  auto-start the game).

  ## Options

    * `:seated` - total seated users including the host (default `1`)
    * `:host_id` - user id of the host (default `"host"`)
    * `:prefix` - id prefix for the joined users, numbered from 2 (default `"user"`)
    * `:metadata` - room metadata passed to `RoomManager.create_room/2` (default `%{}`)

  Returns `{room, user_ids}`: the latest room struct and the ids in seating
  order (host first, then the joined users). Everybody is auto-seated, so the
  host sits north and the others fill east, south and west in join order.
  """
  @spec waiting_room_fixture(keyword()) :: {RoomManager.Room.t(), [String.t()]}
  def waiting_room_fixture(opts \\ []) do
    seated = Keyword.get(opts, :seated, 1)

    unless seated in 1..3 do
      raise ArgumentError, "a waiting room seats 1 to 3 users, got #{inspect(seated)}"
    end

    host_id = Keyword.get(opts, :host_id, "host")
    prefix = Keyword.get(opts, :prefix, "user")
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok, room} = RoomManager.create_room(host_id, metadata)
    joiners = for n <- 2..seated//1, do: "#{prefix}#{n}"

    room =
      Enum.reduce(joiners, room, fn user_id, %RoomManager.Room{code: code} ->
        {:ok, joined_room, _position} = RoomManager.join_room(code, user_id)
        joined_room
      end)

    {room, [host_id | joiners]}
  end
end
