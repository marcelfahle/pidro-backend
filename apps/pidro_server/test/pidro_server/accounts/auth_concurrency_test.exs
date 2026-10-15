defmodule PidroServer.Accounts.AuthConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  test "account deletion and social writes leave no edges to a deleted account in either order" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    parent = self()

    try do
      for write <- [&PidroServer.Blocks.block/2, &PidroServer.Friends.add/2],
          first <- [:delete, :write] do
        a = AccountsFixtures.user_fixture()
        b = AccountsFixtures.user_fixture()

        try do
          leading =
            async_unboxed(fn ->
              Repo.transaction(fn ->
                result = if first == :delete, do: Auth.delete_user(b), else: write.(a.id, b.id)
                send(parent, :written)
                receive do: (:commit -> result)
              end)
            end)

          assert_receive :written, 5_000

          trailing =
            async_unboxed(fn ->
              if first == :delete, do: write.(a.id, b.id), else: Auth.delete_user(b)
            end)

          assert Task.yield(trailing, 100) == nil
          send(leading.pid, :commit)
          assert {:ok, {:ok, _}} = Task.await(leading, 5_000)

          case {first, Task.await(trailing, 5_000)} do
            {:delete, {:error, :user_not_found}} -> :ok
            {:write, {:ok, %User{}}} -> :ok
            result -> flunk("unexpected racing operation result: #{inspect(result)}")
          end

          refute Repo.get(User, b.id)

          refute Repo.exists?(
                   from e in PidroServer.Blocks.Block,
                     where: e.user_id == ^b.id or e.blocked_id == ^b.id
                 )

          refute Repo.exists?(
                   from e in PidroServer.Friends.Friendship,
                     where: e.user_id == ^b.id or e.friend_id == ^b.id
                 )
        after
          ids = [a.id, b.id]

          Repo.delete_all(
            from e in PidroServer.Blocks.Block, where: e.user_id in ^ids or e.blocked_id in ^ids
          )

          Repo.delete_all(
            from e in PidroServer.Friends.Friendship,
              where: e.user_id in ^ids or e.friend_id in ^ids
          )

          Repo.delete_all(from u in User, where: u.id in ^ids)
        end
      end
    after
      Sandbox.checkin(Repo)
    end
  end

  test "guest deletion preserves an account whose upgrade commits while deletion waits" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    guest = AccountsFixtures.guest_fixture()
    parent = self()

    try do
      upgrader =
        async_unboxed(fn ->
          Repo.transaction(fn ->
            locked =
              Repo.one!(from u in User, where: u.id == ^guest.id, lock: "FOR UPDATE")

            {:ok, upgraded} =
              Auth.upgrade_guest(locked, %{
                email: "upgrade-delete-race@example.com",
                password: "password123"
              })

            send(parent, :upgrade_written)

            receive do
              :commit_upgrade -> upgraded
            end
          end)
        end)

      assert_receive :upgrade_written, 5_000
      deleter = async_unboxed(fn -> Auth.delete_guest(guest.id) end)
      assert Task.yield(deleter, 100) == nil

      send(upgrader.pid, :commit_upgrade)
      assert {:ok, %User{guest: false}} = Task.await(upgrader, 5_000)
      assert {:error, :not_a_guest} = Task.await(deleter, 5_000)
      assert %User{guest: false} = Repo.get!(User, guest.id)
    after
      Repo.delete_all(from(u in User, where: u.id == ^guest.id))
      Sandbox.checkin(Repo)
    end
  end

  test "case-variant concurrent upgrades create one login identity" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    first = AccountsFixtures.guest_fixture()
    second = AccountsFixtures.guest_fixture()

    try do
      tasks = [
        async_unboxed(fn ->
          receive do
            :go ->
              Auth.upgrade_guest(first, %{
                email: "CaseRace@example.com",
                password: "password123"
              })
          end
        end),
        async_unboxed(fn ->
          receive do
            :go ->
              Auth.upgrade_guest(second, %{
                email: "caserace@EXAMPLE.com",
                password: "password123"
              })
          end
        end)
      ]

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :email_taken})) == 1

      assert Repo.aggregate(
               from(u in User, where: fragment("lower(?)", u.email) == "caserace@example.com"),
               :count
             ) == 1
    after
      ids = [first.id, second.id]
      Repo.delete_all(from(u in User, where: u.id in ^ids))
      Sandbox.checkin(Repo)
    end
  end

  defp async_unboxed(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end
end
