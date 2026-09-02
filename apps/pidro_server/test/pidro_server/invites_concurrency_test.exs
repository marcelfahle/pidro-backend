defmodule PidroServer.InvitesConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Invites
  alias PidroServer.Invites.Invite
  alias PidroServer.Repo

  test "concurrent first mints create only one active invite" do
    room_id = Ecto.UUID.generate()

    attrs = %{
      room_id: room_id,
      room_code: "RACE",
      host_user_id: Ecto.UUID.generate(),
      label: "Race"
    }

    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              receive do
                :go -> Invites.mint_for_room(attrs)
              end
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.sort(Enum.map(results, fn {:ok, _invite, status} -> status end)) ==
               [:created, :ok]

      assert Repo.aggregate(from(i in Invite, where: i.room_id == ^room_id), :count) == 1
      assert %Invite{} = Invites.active_for_room(room_id)
    after
      Repo.delete_all(from(i in Invite, where: i.room_id == ^room_id))
      Sandbox.checkin(Repo)
    end
  end
end
