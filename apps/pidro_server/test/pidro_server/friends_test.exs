defmodule PidroServer.FriendsTest do
  use PidroServer.DataCase, async: false

  import PidroServer.AccountsFixtures
  alias PidroServer.Friends
  alias PidroServer.Friends.Friendship
  alias PidroServer.Games.RoomManager
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.Presence

  test "one edge is incoming only; adding back is mutual; remove deletes both" do
    a = user_fixture()
    b = user_fixture()
    assert {:ok, %{friends: [], added_you: []}} = Friends.add(a.id, b.id)
    assert {:ok, _} = Friends.add(a.id, b.id)
    assert Repo.aggregate(Friendship, :count) == 1
    assert %{friends: [], added_you: [%{user_id: id}]} = Friends.list(b.id)
    assert id == a.id

    assert {:ok, %{friends: [%{user_id: ^id}], added_you: []}} = Friends.add(b.id, a.id)
    assert [%{user_id: other_id}] = Friends.list(a.id).friends
    assert other_id == b.id
    assert {:ok, %{friends: [], added_you: []}} = Friends.remove(a.id, b.id)
    assert Friends.list(b.id) == %{friends: [], added_you: []}
    assert Repo.aggregate(Friendship, :count) == 0
    assert {:ok, %{friends: [], added_you: []}} = Friends.remove(a.id, b.id)
  end

  test "self, guests, missing and malformed targets are rejected without edges" do
    a = user_fixture()
    guest = guest_fixture()

    for operation <- [&Friends.add/2, &Friends.remove/2] do
      assert {:error, :cannot_friend_self} = operation.(a.id, a.id)

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert {:error, :user_not_found} = operation.(a.id, id)
      end
    end

    assert Repo.aggregate(Friendship, :count) == 0
  end

  test "presence comes from lobby and game tracking; connected friends precede offline names" do
    caller = user_fixture()
    offline = user_fixture(%{display_name: "Aaron"})
    online = user_fixture(%{display_name: "Zora"})
    at_table = user_fixture(%{display_name: "Nora"})

    for user <- [offline, online, at_table] do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    {:ok, room} = RoomManager.create_room(at_table.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Presence.track(self(), "lobby", online.id, %{})
    {:ok, _} = Presence.track(self(), "lobby", at_table.id, %{})
    {:ok, _} = Presence.track(self(), "game:" <> room.code, at_table.id, %{role: :player})

    assert Enum.map(Friends.list(caller.id).friends, &{&1.display_name, &1.presence}) == [
             {"Nora", "at_table"},
             {"Zora", "online"},
             {"Aaron", "offline"}
           ]
  end

  test "a seated player is at_table with bots alone or with people; spectators stay online" do
    caller = user_fixture()

    [solo, pair_a, pair_b, mixed_a, mixed_b, spectator, lobby, offline] =
      users =
      for name <- ~w(Solo PairA PairB MixedA MixedB Spectator Lobby Offline),
          do: user_fixture(%{display_name: name})

    for user <- users do
      {:ok, _} = Friends.add(caller.id, user.id)
      {:ok, _} = Friends.add(user.id, caller.id)
    end

    solo_room = table([solo], [:east, :south, :west])
    pair_room = table([pair_a, pair_b], [])
    mixed_room = table([mixed_a, mixed_b], [:south, :west])

    for {room, user} <- [
          {solo_room, solo},
          {pair_room, pair_a},
          {pair_room, pair_b},
          {mixed_room, mixed_a},
          {mixed_room, mixed_b},
          {solo_room, spectator}
        ] do
      {:ok, _} = Presence.track(self(), "game:" <> room.code, user.id, %{})
    end

    {:ok, _} = Presence.track(self(), "lobby", lobby.id, %{})

    presence =
      Map.new(
        Friends.list(caller.id).friends,
        &{&1.display_name, {&1.presence, &1[:table_company]}}
      )

    assert presence == %{
             "Solo" => {"at_table", "bots"},
             "PairA" => {"at_table", "people"},
             "PairB" => {"at_table", "people"},
             "MixedA" => {"at_table", "people"},
             "MixedB" => {"at_table", "people"},
             "Spectator" => {"online", nil},
             "Lobby" => {"online", nil},
             "Offline" => {"offline", nil}
           }
  end

  test "incoming-only entries are newest first, not alphabetical" do
    caller = user_fixture()
    old = user_fixture(%{display_name: "Aaron"})
    new = user_fixture(%{display_name: "Zora"})
    {:ok, _} = Friends.add(old.id, caller.id)
    {:ok, _} = Friends.add(new.id, caller.id)
    assert Enum.map(Friends.list(caller.id).added_you, & &1.user_id) == [new.id, old.id]
  end

  test "search uses name_key prefix, excludes self and guests, and derives all four relations" do
    caller = user_fixture(%{display_name: "Marcel Self"})
    mutual = user_fixture(%{display_name: "Márcel"})
    incoming = user_fixture(%{display_name: "ＭＡＲＣＯ"})
    outgoing = user_fixture(%{display_name: "M a r i e"})
    unrelated = user_fixture(%{display_name: "Marina"})
    guest_fixture(%{display_name: "Mar Guest"})
    user_fixture(%{display_name: "Omar"})
    {:ok, _} = Friends.add(caller.id, mutual.id)
    {:ok, _} = Friends.add(mutual.id, caller.id)
    {:ok, _} = Friends.add(incoming.id, caller.id)
    {:ok, _} = Friends.add(caller.id, outgoing.id)

    for q <- [nil, "", "ma", " é ", ["mar"]] do
      assert {:error, :query_too_short} = Friends.search(caller.id, q)
    end

    assert {:ok, entries} = Friends.search(caller.id, " ＭÁＲ ")

    assert Map.new(entries, &{&1.user_id, &1.relation}) == %{
             mutual.id => "friend",
             incoming.id => "added_you",
             outgoing.id => "added",
             unrelated.id => "none"
           }
  end

  test "a player without a display name is listed and found by username" do
    caller = user_fixture()
    plain = user_fixture(%{username: "nora_plain"})
    named = user_fixture(%{username: "nora_named", display_name: "Vera"})
    {:ok, _} = Friends.add(plain.id, caller.id)

    assert [%{user_id: id, display_name: "nora_plain"}] = Friends.list(caller.id).added_you
    assert id == plain.id

    assert {:ok, [%{display_name: "nora_plain"}]} = Friends.search(caller.id, "nora")
    assert {:ok, [%{display_name: "Vera"}]} = Friends.search(caller.id, "ver")
    assert named.display_name == "Vera"
  end

  test "search returns ten matches, not ten candidates before folding" do
    caller = user_fixture()
    for n <- 1..12, do: user_fixture(%{display_name: "Nora #{n}"})
    for n <- 1..12, do: user_fixture(%{display_name: "Aaron #{n}"})
    assert {:ok, users} = Friends.search(caller.id, "nor")
    assert length(users) == 10
    assert Enum.all?(users, &String.starts_with?(&1.display_name, "Nora"))
  end

  test "recent deduplicates humans, excludes friends and non-accounts, and limits the game window" do
    caller = user_fixture()
    friend = user_fixture()
    old = user_fixture()
    newer = user_fixture()
    newest = user_fixture()
    guest = guest_fixture()
    {:ok, _} = Friends.add(caller.id, friend.id)
    {:ok, _} = Friends.add(friend.id, caller.id)
    {:ok, _} = Friends.add(newer.id, caller.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    game(caller.id, [old.id], DateTime.add(now, -30))
    for n <- 1..19, do: game(caller.id, [friend.id], DateTime.add(now, -n))
    game(caller.id, [newest.id, newer.id, friend.id, guest.id, Ecto.UUID.generate()], now)
    game(friend.id, [old.id], DateTime.add(now, 1))

    assert Enum.map(Friends.recent(caller.id), &{&1.user_id, &1.relation}) == [
             {newest.id, "none"},
             {newer.id, "added_you"}
           ]

    game(caller.id, [newer.id, newest.id], DateTime.add(now, 2))
    assert Enum.map(Friends.recent(caller.id), & &1.user_id) == [newer.id, newest.id]
  end

  test "recent returns at most ten distinct tablemates" do
    caller = user_fixture()
    users = for _ <- 1..12, do: user_fixture()
    game(caller.id, Enum.map(users, & &1.id), DateTime.utc_now() |> DateTime.truncate(:second))

    assert Enum.map(Friends.recent(caller.id), & &1.user_id) ==
             users |> Enum.take(10) |> Enum.map(& &1.id)
  end

  test "a completed table with bots suggests only the other human" do
    caller = user_fixture()
    human = user_fixture()
    alias PidroServer.Games.Room.Seat

    room = %{
      code: "BOTS",
      created_at: DateTime.utc_now(),
      seats: %{
        north: Seat.new_human(:north, caller.id),
        east: Seat.new_human(:east, human.id),
        south: Seat.new_bot(:south, self()),
        west: Seat.new_bot(:west, self())
      }
    }

    assert {:ok, _} =
             PidroServer.Stats.save_completed_game(room, :north_south, %{
               north_south: 62,
               east_west: 40
             })

    assert [%{user_id: id, relation: "none"}] = Friends.recent(caller.id)
    assert id == human.id
  end

  defp game(caller, others, completed_at) do
    %GameStats{}
    |> GameStats.changeset(%{
      room_code: "TEST",
      completed_at: completed_at,
      player_ids: [caller | others]
    })
    |> Repo.insert!()
  end

  defp table([host | guests], bot_positions) do
    {:ok, room} = RoomManager.create_room(host.id, %{})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    for guest <- guests, do: {:ok, _, :east} = RoomManager.join_room(room.code, guest.id, :east)

    for position <- bot_positions,
        do:
          {:ok, _, ^position} =
            RoomManager.join_bot(room.code, "bot_#{room.code}_#{position}", self(), position)

    room
  end
end
