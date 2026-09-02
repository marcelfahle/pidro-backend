defmodule PidroServer.Accounts.AuthConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

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
