defmodule PidroServer.Accounts.ClassicClaimsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Accounts.{ClassicClaimTicket, ClassicClaims, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  test "concurrent claims enforce one-to-one ownership in both directions" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    first = AccountsFixtures.user_fixture()
    second = AccountsFixtures.user_fixture()

    try do
      same_classic = [
        {first, issue_ticket!(first, 80_001)},
        {second, issue_ticket!(second, 80_001)}
      ]

      results = race_claims(same_classic)
      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:already_claimed, :password}}, &1)) == 1

      winner =
        Enum.find_value(results, fn
          {:ok, user} -> user
          _other -> nil
        end)

      fresh = AccountsFixtures.user_fixture()

      different_classics = [
        {fresh, issue_ticket!(fresh, 80_002)},
        {fresh, issue_ticket!(fresh, 80_003)}
      ]

      results = race_claims(different_classics)
      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :user_already_claimed})) == 1

      assert Repo.aggregate(from(u in User, where: u.classic_user_id == 80_001), :count) == 1
      assert Repo.get!(User, winner.id).classic_user_id == 80_001
      assert Repo.get!(User, fresh.id).classic_user_id in [80_002, 80_003]
    after
      Repo.delete_all(ClassicClaimTicket)
      Repo.delete_all(PlayerProfile)
      Repo.delete_all(from u in User, where: u.id in ^[first.id, second.id])
      Repo.delete_all(from u in User, where: u.classic_user_id in [80_002, 80_003])
      Sandbox.checkin(Repo)
    end
  end

  test "concurrent fresh-install redemption returns the same account to both requests" do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      ticket = issue_install_ticket!("concurrent-install", 80_004)

      params = %{
        install_id: "concurrent-install",
        account: %{
          username: "concurrent_veteran",
          email: "concurrent@example.com",
          password: "password123"
        }
      }

      tasks =
        for _ <- 1..2 do
          async_unboxed(fn ->
            receive do
              :go -> ClassicClaims.redeem(ticket, nil, params)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert [{:ok, %User{id: id}}, {:ok, %User{id: id}}] = results
      assert Repo.aggregate(from(u in User, where: u.classic_user_id == 80_004), :count) == 1
    after
      Repo.delete_all(ClassicClaimTicket)
      Repo.delete_all(PlayerProfile)
      Repo.delete_all(from u in User, where: u.classic_user_id == 80_004)
      Sandbox.checkin(Repo)
    end
  end

  defp race_claims(users_and_tickets) do
    tasks =
      Enum.map(users_and_tickets, fn {user, ticket} ->
        async_unboxed(fn ->
          receive do
            :go -> ClassicClaims.redeem(ticket, user, %{})
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp issue_ticket!(user, classic_user_id) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: :password,
        user_id: user.id,
        legacy_data: %{xp: 10}
      })

    ticket
  end

  defp issue_install_ticket!(install_id, classic_user_id) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: :password,
        install_id: install_id,
        legacy_data: %{xp: 10}
      })

    ticket
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
