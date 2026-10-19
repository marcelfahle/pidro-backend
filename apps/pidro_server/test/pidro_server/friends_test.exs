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

    assert Friends.list(b.id) == %{
             friends: [],
             added_you: [],
             requested: [],
             requests_waiting: 0,
             waiting_for_you: 0
           }

    assert Repo.aggregate(Friendship, :count) == 0
    assert {:ok, %{friends: [], added_you: []}} = Friends.remove(a.id, b.id)
  end

  test "a sent request is listed as requested, newest first, until cancelled" do
    caller = user_fixture()
    old = user_fixture()
    new = user_fixture()
    {:ok, _} = Friends.add(caller.id, old.id)
    {:ok, _} = Friends.add(caller.id, new.id)
    {:ok, _} = Friends.add(new.id, caller.id)
    newest = user_fixture()
    {:ok, _} = Friends.add(caller.id, newest.id)

    assert %{friends: [%{user_id: friend_id}], requested: requested} = Friends.list(caller.id)
    assert friend_id == new.id
    assert Enum.map(requested, & &1.user_id) == [newest.id, old.id]
    assert Enum.all?(requested, &match?(%DateTime{}, &1.requested_at))
    assert Friends.list(old.id).requests_waiting == 1

    assert {:ok, %{requested: [%{user_id: id}]}} = Friends.remove(caller.id, newest.id)
    assert id == old.id
  end

  test "cancel removes only the caller's edge and never an incoming request" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(b.id, a.id)

    assert {:ok, %{added_you: [%{user_id: id}], requests_waiting: 1}} = Friends.remove(a.id, b.id)
    assert id == b.id
    assert [%{user_id: ^id}] = Friends.list(a.id).added_you

    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    assert Repo.aggregate(Friendship, :count) == 0
  end

  test "ignore hides a request from the recipient only; add back still makes friends" do
    a = user_fixture()
    b = user_fixture()
    {:ok, sender_view} = Friends.add(a.id, b.id)
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    assert {:ok, %{added_you: [], requests_waiting: 0}} = Friends.ignore(b.id, a.id)
    assert_receive {:friends_changed, id} when id == b.id
    refute_received {:friends_changed, _}
    assert Friends.list(a.id) == sender_view

    assert {:ok, %{added_you: [%{user_id: id}], requests_waiting: 1}} =
             Friends.unignore(b.id, a.id)

    assert id == a.id

    {:ok, _} = Friends.ignore(b.id, a.id)
    assert {:ok, %{friends: [%{user_id: ^id}], requested: []}} = Friends.add(b.id, a.id)
    assert [%{user_id: friend_id}] = Friends.list(a.id).friends
    assert friend_id == b.id
  end

  test "a new request tells only its receiver, with the sender's entry and last shared game" do
    a = user_fixture(%{display_name: "Pekka"})
    b = user_fixture()
    c = user_fixture()
    played = ~U[2026-10-18 19:30:00Z]
    game(a.id, [b.id], DateTime.add(played, -86_400))
    game(a.id, [b.id], played)
    game(a.id, [c.id], DateTime.add(played, 60))
    game(b.id, [c.id], DateTime.add(played, 120))
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

    {:ok, _} = Friends.add(a.id, b.id)
    assert_receive {:friend_event, id, "friend_request", payload} when id == b.id
    assert payload == %{player: hd(Friends.list(b.id).added_you), played_together_at: played}
    assert %{user_id: sender_id, display_name: "Pekka"} = payload.player
    assert sender_id == a.id

    {:ok, _} = Friends.add(user_fixture().id, a.id)

    assert_receive {:friend_event, id, "friend_request", %{played_together_at: nil}}
                   when id == a.id

    refute_received {:friend_event, _, _, _}
  end

  test "adding back tells only the original sender, also after an ignore" do
    for ignore? <- [false, true] do
      a = user_fixture()
      b = user_fixture(%{display_name: "Nora"})
      {:ok, _} = Friends.add(a.id, b.id)
      if ignore?, do: {:ok, _} = Friends.ignore(b.id, a.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _} = Friends.add(b.id, a.id)
      assert_receive {:friend_event, id, "friend_accepted", payload} when id == a.id
      assert payload == %{player: hd(Friends.list(a.id).friends), source: "accept"}
      assert payload.player.user_id == b.id
      refute_received {:friend_event, _, _, _}
      Phoenix.PubSub.unsubscribe(PidroServer.PubSub, "lobby:updates")
    end
  end

  test "repeat adds, ignore, un-ignore, cancel, remove and block tell nobody" do
    [a, b, c, d] = for _ <- 1..4, do: user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)

    for other <- [c, d] do
      {:ok, _} = Friends.add(a.id, other.id)
      {:ok, _} = Friends.add(other.id, a.id)
    end

    Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(a.id, c.id)
    {:ok, _} = Friends.add(c.id, a.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = Friends.unignore(b.id, a.id)
    {:ok, _} = Friends.remove(a.id, b.id)
    {:ok, _} = Friends.remove(a.id, c.id)
    {:ok, _} = PidroServer.Blocks.block(a.id, d.id)

    assert_received {:friends_changed, _}
    refute_received {:friend_event, _, _, _}
  end

  test "waiting_for_you counts requests until answered and seat invitations until gone" do
    a = user_fixture()
    b = user_fixture()
    c = user_fixture()
    {:ok, _} = Friends.add(a.id, c.id)
    {:ok, _} = Friends.add(b.id, c.id)
    assert %{requests_waiting: 2, waiting_for_you: 2} = Friends.list(c.id)
    assert %{waiting_for_you: 0} = Friends.list(a.id)

    assert {:ok, %{waiting_for_you: 1}} = Friends.ignore(c.id, a.id)
    assert {:ok, %{waiting_for_you: 0}} = Friends.add(c.id, b.id)

    {:ok, room} = RoomManager.create_room(b.id, %{seat_holds: %{south: c.id}})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    assert %{requests_waiting: 0, waiting_for_you: 1} = Friends.list(c.id)

    {:ok, _} = RoomManager.set_seat_hold(room.code, b.id, :south, nil)
    assert %{waiting_for_you: 0} = Friends.list(c.id)
  end

  test "blocking clears an ignore mark with the edge" do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.ignore(b.id, a.id)
    {:ok, _} = PidroServer.Blocks.block(b.id, a.id)
    {:ok, _} = PidroServer.Blocks.unblock(b.id, a.id)
    {:ok, _} = Friends.add(a.id, b.id)
    assert [%{user_id: id}] = Friends.list(b.id).added_you
    assert id == a.id
  end

  test "self, guests, missing and malformed targets are rejected without edges" do
    a = user_fixture()
    guest = guest_fixture()

    for operation <- [&Friends.add/2, &Friends.remove/2, &Friends.ignore/2, &Friends.unignore/2] do
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
