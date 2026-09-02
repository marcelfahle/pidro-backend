defmodule PidroServer.InvitesConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Invites
  alias PidroServer.Invites.{Event, Invite, Redemption}
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

  test "concurrent repeats record one seat claim" do
    room_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      {:ok, invite} =
        Invites.create_invite(%{
          room_id: room_id,
          room_code: "RDM1",
          host_user_id: Ecto.UUID.generate()
        })

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              receive do
                :go ->
                  Invites.record_claim(invite, %{
                    user_id: user_id,
                    position: "south",
                    platform: "ios",
                    source: "wa"
                  })
              end
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.sort(Enum.map(results, fn {:ok, _redemption, status} -> status end)) ==
               [:created, :existing]

      assert Repo.aggregate(
               from(r in Redemption, where: r.invite_id == ^invite.id and r.user_id == ^user_id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in Event,
                 where:
                   e.invite_id == ^invite.id and e.user_id == ^user_id and
                     e.kind == "seat_claimed"
               ),
               :count
             ) == 1

      assert Repo.get!(Invite, invite.id).redeem_count == 1
    after
      Repo.delete_all(from(i in Invite, where: i.room_id == ^room_id))
      Sandbox.checkin(Repo)
    end
  end
end
