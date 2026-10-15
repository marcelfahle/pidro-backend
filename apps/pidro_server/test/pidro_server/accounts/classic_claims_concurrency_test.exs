defmodule PidroServer.Accounts.ClassicClaimsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Accounts.{ClassicClaimTicket, ClassicClaims, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Blocks.Block
  alias PidroServer.ClassicSocial
  alias PidroServer.Friends
  alias PidroServer.Friends.Friendship
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo

  test "a link committed during discovery cannot expose a Classic-blocked pair as friends" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    a = AccountsFixtures.user_fixture()
    b = AccountsFixtures.user_fixture()
    ids = [a.id, b.id]
    handler = "classic-social-discovery"

    try do
      ticket = issue_ticket!(a, 80_020, %{friend_ids: [80_021], blocked_ids: [80_021]})
      assert {:ok, a} = ClassicClaims.redeem(ticket, a, %{})

      # Pause after discovery's first SELECT snapshot, then commit the other
      # link without running its resolver yet. No transient friendship is safe.
      :telemetry.attach(
        handler,
        [:pidro_server, :repo, :query],
        fn _, _, metadata, parent ->
          if String.starts_with?(metadata.query, "SELECT") and
               String.contains?(metadata.query, "classic_blocks") do
            send(parent, {:discovered, self()})

            receive do
              :resume -> :ok
            after
              5_000 -> raise "discovery barrier timed out"
            end
          end
        end,
        self()
      )

      task = async_unboxed(fn -> ClassicSocial.resolve_classic(a) end)
      assert_receive {:discovered, pid}, 2_000
      :telemetry.detach(handler)

      b =
        b
        |> User.classic_claim_changeset(%{
          classic_user_id: 80_021,
          classic_claimed_at: DateTime.utc_now()
        })
        |> Repo.update!()

      send(pid, :resume)
      assert Task.await(task) == :ok
      refute Repo.exists?(from f in Friendship, where: f.user_id in ^ids)

      assert ClassicSocial.resolve_classic(b) == :ok
      assert Repo.get_by(Block, user_id: a.id, blocked_id: b.id)
      refute Repo.exists?(from f in Friendship, where: f.user_id in ^ids)
    after
      :telemetry.detach(handler)
      Repo.delete_all(from t in ClassicClaimTicket, where: t.bound_user_id in ^ids)
      Repo.delete_all(from p in PlayerProfile, where: p.user_id in ^ids)
      Repo.delete_all(from f in Friendship, where: f.user_id in ^ids)
      Repo.delete_all(from b in Block, where: b.user_id in ^ids)
      Repo.delete_all(from f in "classic_friendships", where: f.classic_user_id == 80_020)
      Repo.delete_all(from b in "classic_blocks", where: b.classic_user_id == 80_020)
      Repo.delete_all(from u in User, where: u.id in ^ids)
      Sandbox.checkin(Repo)
    end
  end

  test "simultaneous claims resolve mutual facts and let a Classic block win" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    a = AccountsFixtures.user_fixture()
    b = AccountsFixtures.user_fixture()
    c = AccountsFixtures.user_fixture()
    d = AccountsFixtures.user_fixture()
    ids = [a.id, b.id, c.id, d.id]

    try do
      for {first, second, base, blocked} <- [{a, b, 80_010, []}, {c, d, 80_012, [80_013]}] do
        tickets = [
          {first,
           issue_ticket!(first, base, %{
             friend_ids: [base + 1],
             friended_by_ids: [base + 1],
             blocked_ids: blocked
           })},
          {second,
           issue_ticket!(second, base + 1, %{friend_ids: [base], friended_by_ids: [base]})}
        ]

        assert [{:ok, _}, {:ok, _}] = race_claims(tickets)
        assert Friends.list(first.id).classic.not_here == 0
        assert Friends.list(second.id).classic.not_here == 0
      end

      assert Enum.map(Friends.list(a.id).friends, & &1.user_id) == [b.id]
      assert Enum.map(Friends.list(b.id).friends, & &1.user_id) == [a.id]
      assert Repo.get_by(Block, user_id: c.id, blocked_id: d.id)
      refute Repo.exists?(from f in Friendship, where: f.user_id in ^[c.id, d.id])
    after
      Repo.delete_all(from t in ClassicClaimTicket, where: t.bound_user_id in ^ids)
      Repo.delete_all(from p in PlayerProfile, where: p.user_id in ^ids)
      Repo.delete_all(from f in Friendship, where: f.user_id in ^ids)
      Repo.delete_all(from b in Block, where: b.user_id in ^ids)

      Repo.delete_all(
        from f in "classic_friendships",
          where: f.classic_user_id in [80_010, 80_011, 80_012, 80_013]
      )

      Repo.delete_all(
        from b in "classic_blocks", where: b.classic_user_id in [80_010, 80_011, 80_012, 80_013]
      )

      Repo.delete_all(from u in User, where: u.id in ^ids)
      Sandbox.checkin(Repo)
    end
  end

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

  defp issue_ticket!(user, classic_user_id, legacy_data \\ %{xp: 10}) do
    {:ok, %{ticket: ticket}} =
      ClassicClaims.issue_ticket(%{
        classic_user_id: classic_user_id,
        method: :password,
        user_id: user.id,
        legacy_data: legacy_data
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
