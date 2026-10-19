defmodule PidroServer.BlocksTest do
  use PidroServer.DataCase, async: false

  import PidroServer.AccountsFixtures
  alias PidroServer.{Blocks, Friends}
  alias PidroServer.Blocks.Block
  alias PidroServer.Friends.Friendship

  test "block is idempotent, removes both edges, and refreshes both lists without revealing why" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(b.id, a.id)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    assert {:ok, %{blocked: [entry]}} = Blocks.block(a.id, b.id)
    assert entry == %{user_id: b.id, display_name: b.username, avatar_url: b.avatar_url}
    assert_receive {:friends_changed, id} when id == a.id
    assert_receive {:friends_changed, id} when id == b.id
    assert Blocks.blocked?(a.id, b.id)
    assert Blocks.blocked?(b.id, a.id)
    assert {:ok, %{blocked: [^entry]}} = Blocks.block(a.id, b.id)
    assert Repo.aggregate(Block, :count) == 1
    assert Repo.aggregate(Friendship, :count) == 0

    assert Friends.list(a.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert Friends.list(b.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert Blocks.list(b.id) == %{blocked: []}

    for {caller, target} <- [{a, b}, {b, a}] do
      assert {:error, :user_not_found} = Friends.add(caller.id, target.id)
    end

    assert {:ok, %{blocked: []}} = Blocks.unblock(a.id, b.id)
    assert {:ok, %{blocked: []}} = Blocks.unblock(a.id, b.id)
    refute Blocks.blocked?(a.id, b.id)

    assert Friends.list(a.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert Friends.list(b.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert {:ok, _} = Friends.add(a.id, b.id)
  end

  test "unblock removes only the caller's edge" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Blocks.block(a.id, b.id)
    {:ok, _} = Blocks.block(b.id, a.id)
    {:ok, _} = Blocks.unblock(a.id, b.id)
    assert Blocks.blocked?(a.id, b.id)
    assert Blocks.list(a.id) == %{blocked: []}
    assert [%{user_id: id}] = Blocks.list(b.id).blocked
    assert id == a.id
  end

  test "self, guests and unavailable targets cannot create blocks" do
    user = user_fixture()
    guest = guest_fixture()

    for operation <- [&Blocks.block/2, &Blocks.unblock/2] do
      assert {:error, :cannot_block_self} = operation.(user.id, user.id)
      assert {:error, :account_required} = operation.(guest.id, user.id)

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert {:error, :user_not_found} = operation.(user.id, id)
      end
    end

    assert Repo.aggregate(Block, :count) == 0
  end

  test "account deletion removes blocks in both directions and preserves unrelated blocks" do
    a = user_fixture()
    b = user_fixture()
    c = user_fixture()
    {:ok, _} = Blocks.block(a.id, b.id)
    {:ok, _} = Blocks.block(b.id, a.id)
    {:ok, _} = Blocks.block(b.id, c.id)
    assert {:ok, _} = PidroServer.Accounts.Auth.delete_user(a)
    refute Blocks.blocked?(a.id, b.id)
    assert Blocks.blocked?(b.id, c.id)
    assert Repo.aggregate(Block, :count) == 1
  end
end
