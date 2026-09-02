defmodule PidroServer.Accounts.GuestReaperTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, GuestReaper, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile

  @day_in_seconds 24 * 60 * 60

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * @day_in_seconds, :second)

  setup do
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  describe "run_once/1" do
    test "deletes idle guests with the deletion recipe and keeps everyone else" do
      stale_seen = AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(31)})

      stale_never_seen =
        AccountsFixtures.guest_fixture(%{last_seen_at: nil, inserted_at: days_ago(31)})

      fresh_seen =
        AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(29), inserted_at: days_ago(60)})

      fresh_never_seen = AccountsFixtures.guest_fixture(%{last_seen_at: nil})

      registered_idle =
        AccountsFixtures.user_fixture()
        |> Ecto.Changeset.change(last_seen_at: days_ago(365), inserted_at: days_ago(400))
        |> Repo.update!()

      {:ok, _profile} = Profiles.get_or_create_profile(stale_seen.id)
      {:ok, _profile} = Profiles.get_or_create_profile(registered_idle.id)

      assert {:ok, 2} = GuestReaper.run_once()

      assert is_nil(Repo.get(User, stale_seen.id))
      assert is_nil(Repo.get(User, stale_never_seen.id))
      assert is_nil(Repo.get_by(PlayerProfile, user_id: stale_seen.id))

      assert %User{} = Repo.get(User, fresh_seen.id)
      assert %User{} = Repo.get(User, fresh_never_seen.id)
      assert %User{} = Repo.get(User, registered_idle.id)
      assert %PlayerProfile{} = Repo.get_by(PlayerProfile, user_id: registered_idle.id)

      assert {:ok, 0} = GuestReaper.run_once()
    end

    test "works through more than one batch" do
      for _ <- 1..101, do: AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(40)})
      keeper = AccountsFixtures.guest_fixture()

      assert {:ok, 101} = GuestReaper.run_once()

      assert Repo.aggregate(from(u in User, where: u.guest == true), :count) == 1
      assert %User{} = Repo.get(User, keeper.id)
    end

    test "a failed guest does not prevent later batches from draining" do
      failed = AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(50)})
      for _ <- 1..100, do: AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(40)})

      delete_guest = fn id ->
        if id == failed.id do
          false
        else
          case Auth.get_user(id) do
            %User{guest: true} = guest -> match?({:ok, _deleted}, Auth.delete_user(guest))
            _upgraded_or_gone -> false
          end
        end
      end

      assert {:ok, 100} = GuestReaper.run_once(delete_guest: delete_guest)
      assert %User{} = Repo.get(User, failed.id)
      assert Repo.aggregate(from(u in User, where: u.guest == true), :count) == 1
    end

    test "honors a max_idle_days override" do
      stale_for_override = AccountsFixtures.guest_fixture(%{last_seen_at: days_ago(2)})
      keeper = AccountsFixtures.guest_fixture()

      assert {:ok, 1} = GuestReaper.run_once(max_idle_days: 1)
      assert is_nil(Repo.get(User, stale_for_override.id))
      assert %User{} = Repo.get(User, keeper.id)
    end

    test "rejects non-positive timing configuration" do
      assert_raise ArgumentError, ~r/max_idle_days must be a positive integer/, fn ->
        GuestReaper.run_once(max_idle_days: 0)
      end

      assert_raise ArgumentError, ~r/interval_ms must be a positive integer/, fn ->
        GuestReaper.run_once(interval_ms: -1)
      end
    end
  end

  describe "scheduling" do
    test "does not schedule when disabled" do
      pid = start_supervised!({GuestReaper, enabled: false, interval_ms: 1, name: nil})

      assert %{timer: nil} = :sys.get_state(pid)
      refute_receive :reap, 50
    end

    test "schedules the first run on the configured interval when enabled" do
      pid =
        start_supervised!(
          {GuestReaper, enabled: true, interval_ms: 60_000, max_idle_days: 7, name: nil}
        )

      assert %{timer: timer, max_idle_days: 7} = :sys.get_state(pid)
      assert is_reference(timer)
      remaining = Process.read_timer(timer)
      assert is_integer(remaining) and remaining <= 60_000
    end
  end
end
