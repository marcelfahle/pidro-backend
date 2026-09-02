defmodule PidroServer.InvitesTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.Event
  alias PidroServer.Invites.Invite
  alias PidroServer.Invites.Redemption

  @code_format ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/
  @day_in_seconds 24 * 60 * 60
  @origin_kinds ~w(created shared landing_viewed crawler_viewed open_app_clicked store_clicked
                   app_opened_via_link deferred_matched code_typed guest_created seat_claimed
                   game_completed guest_upgraded expired revoked)

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        room_id: Ecto.UUID.generate(),
        room_code: "K7QP",
        host_user_id: Ecto.UUID.generate(),
        seat_hint: "partner",
        label: "Anna"
      },
      Map.new(overrides)
    )
  end

  defp create!(overrides \\ %{}, opts \\ []) do
    {:ok, invite} = Invites.create_invite(attrs(overrides), opts)
    invite
  end

  # A room stub honouring the `room_lookup` contract: `id`, `status`, `locked`
  # and `seats_taken`, plus the `code` the stub lookup matches on.
  defp room(invite, overrides \\ %{}) do
    Map.merge(
      %{
        id: invite.room_id,
        code: invite.room_code,
        status: :waiting,
        locked: false,
        seats_taken: 1
      },
      Map.new(overrides)
    )
  end

  defp lookup(nil), do: fn _code -> {:error, :room_not_found} end

  defp lookup(rooms) when is_list(rooms) do
    fn code ->
      case Enum.find(rooms, &(&1.code == code)) do
        nil -> {:error, :room_not_found}
        room -> {:ok, room}
      end
    end
  end

  defp lookup(room) when is_map(room), do: lookup([room])

  defp expire!(invite) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, invite} = invite |> Ecto.Changeset.change(expires_at: past) |> Repo.update()
    invite
  end

  defp reload(invite), do: Repo.get!(Invite, invite.id)

  defp events(invite) do
    Repo.all(from(e in Event, where: e.invite_id == ^invite.id, order_by: e.inserted_at))
  end

  # Returns a zero-arity generator that yields `codes` in order and then
  # repeats the last one forever.
  defp sequence_generator(codes) do
    index = :counters.new(1, [])
    codes = List.to_tuple(codes)

    fn ->
      position = :counters.get(index, 1)
      :counters.add(index, 1, 1)
      elem(codes, min(position, tuple_size(codes) - 1))
    end
  end

  describe "create_invite/2" do
    test "stores an upper-cased 8-symbol code, a 24-hour expiry and a zero redeem count" do
      now = DateTime.utc_now()

      assert {:ok, %Invite{} = invite} = Invites.create_invite(attrs())

      assert Regex.match?(@code_format, invite.code)
      assert invite.code == String.upcase(invite.code)
      assert invite.seat_hint == "partner"
      assert invite.label == "Anna"
      assert invite.redeem_count == 0
      assert invite.revoked_at == nil
      assert invite.superseded_by == nil
      assert_in_delta DateTime.diff(invite.expires_at, now, :second), @day_in_seconds, 5
    end

    test "accepts every seat hint, and no hint or label at all" do
      for hint <- ~w(north east south west north_south east_west partner) do
        assert {:ok, %Invite{seat_hint: ^hint}} = Invites.create_invite(attrs(seat_hint: hint))
      end

      assert {:ok, %Invite{seat_hint: nil, label: nil}} =
               Invites.create_invite(attrs(seat_hint: nil, label: nil))
    end

    test "rejects a seat hint outside the allowed set" do
      assert {:error, changeset} = Invites.create_invite(attrs(seat_hint: "dealer"))
      assert %{seat_hint: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects a label longer than 40 characters" do
      assert {:error, changeset} = Invites.create_invite(attrs(label: String.duplicate("a", 41)))
      assert %{label: [_]} = errors_on(changeset)

      assert {:ok, _} = Invites.create_invite(attrs(label: String.duplicate("a", 40)))
    end

    test "requires the room and host identity" do
      assert {:error, changeset} = Invites.create_invite(%{seat_hint: "partner"})

      errors = errors_on(changeset)
      assert Map.has_key?(errors, :room_id)
      assert Map.has_key?(errors, :room_code)
      assert Map.has_key?(errors, :host_user_id)
    end

    test "retries once when the generator returns a taken code" do
      create!(%{}, generator: fn -> "AAAAAAAA" end)
      generator = sequence_generator(["AAAAAAAA", "BBBBBBBB"])

      assert {:ok, %Invite{code: "BBBBBBBB"}} =
               Invites.create_invite(attrs(), generator: generator)
    end

    test "returns the unique-constraint error when the generator returns a taken code twice" do
      create!(%{}, generator: fn -> "AAAAAAAA" end)
      calls = :counters.new(1, [])

      generator = fn ->
        :counters.add(calls, 1, 1)
        "AAAAAAAA"
      end

      assert {:error, changeset} = Invites.create_invite(attrs(), generator: generator)
      assert %{code: ["has already been taken"]} = errors_on(changeset)
      assert :counters.get(calls, 1) == 2
    end
  end

  describe "get_by_code/1" do
    test "finds an invite from a dashed, lower-case spelling" do
      invite = create!(%{}, generator: fn -> "7KQ4M2XB" end)

      assert {:ok, %Invite{id: id}} = Invites.get_by_code("7kq4-m2xb")
      assert id == invite.id
    end

    test "maps I, L and O before matching" do
      invite = create!(%{}, generator: fn -> "01Q4M2X1" end)

      assert {:ok, %Invite{id: id}} = Invites.get_by_code("oLq4-m2xI")
      assert id == invite.id
    end

    test "answers not_found for an unknown or malformed code" do
      assert Invites.get_by_code("7KQ4M2XB") == {:error, :not_found}
      assert Invites.get_by_code("abc") == {:error, :not_found}
      assert Invites.get_by_code(nil) == {:error, :not_found}
    end

    test "preloads the superseding invite" do
      old = create!()
      new = create!()
      {:ok, _old} = Invites.supersede(old, new)

      assert {:ok, %Invite{successor: %Invite{id: new_id}}} = Invites.get_by_code(old.code)
      assert new_id == new.id
      assert {:ok, %Invite{successor: nil}} = Invites.get_by_code(new.code)
    end
  end

  describe "active_for_room/1" do
    test "returns the newest live invite of the room" do
      room_id = Ecto.UUID.generate()
      _older = create!(room_id: room_id)
      newest = create!(room_id: room_id)

      assert %Invite{id: id} = Invites.active_for_room(room_id)
      assert id == newest.id
    end

    test "skips revoked, expired and superseded invites" do
      room_id = Ecto.UUID.generate()
      live = create!(room_id: room_id)
      {:ok, _revoked} = Invites.revoke(create!(room_id: room_id))
      _expired = expire!(create!(room_id: room_id))
      {:ok, _moved} = Invites.supersede(create!(room_id: room_id), create!())

      assert %Invite{id: id} = Invites.active_for_room(room_id)
      assert id == live.id
    end

    test "returns nil when the room has no live invite" do
      room_id = Ecto.UUID.generate()
      assert Invites.active_for_room(room_id) == nil

      {:ok, _revoked} = Invites.revoke(create!(room_id: room_id))
      assert Invites.active_for_room(room_id) == nil
    end
  end

  describe "mint_for_room/3" do
    test "creates one active link, then updates that row in place" do
      invite_attrs = attrs()

      assert {:ok, created, :created} = Invites.mint_for_room(invite_attrs)

      assert {:ok, updated, :ok} =
               Invites.mint_for_room(%{invite_attrs | seat_hint: "north", label: "Bob"})

      assert updated.id == created.id
      assert updated.code == created.code
      assert updated.seat_hint == "north"
      assert updated.label == "Bob"
      assert Invites.count_for_room(created.room_id) == 1
    end

    test "supersedes an earlier link in the same mutation" do
      old = create!()
      new_attrs = attrs(room_id: Ecto.UUID.generate(), room_code: "NEXT")

      assert {:ok, new, :created} = Invites.mint_for_room(new_attrs, old)
      assert reload(old).superseded_by == new.id
    end

    test "refuses a new link after the lifetime cap" do
      room_id = Ecto.UUID.generate()

      for _ <- 1..20 do
        invite = create!(room_id: room_id)
        assert {:ok, _revoked} = Invites.revoke(invite)
      end

      assert {:error, :invite_limit} = Invites.mint_for_room(attrs(room_id: room_id))
      assert Invites.count_for_room(room_id) == 20
    end
  end

  describe "update_hint/2" do
    test "changes seat_hint and label without changing the code" do
      invite = create!()

      assert {:ok, updated} = Invites.update_hint(invite, %{seat_hint: "north", label: "Bob"})
      assert updated.id == invite.id
      assert updated.code == invite.code
      assert updated.seat_hint == "north"
      assert updated.label == "Bob"
    end

    test "clears the hint and label when given nil" do
      invite = create!()

      assert {:ok, %Invite{seat_hint: nil, label: nil}} =
               Invites.update_hint(invite, %{seat_hint: nil, label: nil})
    end

    test "rejects an invalid hint" do
      assert {:error, changeset} = Invites.update_hint(create!(), %{seat_hint: "dealer"})
      assert %{seat_hint: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "revoke/1" do
    test "sets revoked_at and keeps the row" do
      invite = create!()

      assert {:ok, %Invite{revoked_at: %DateTime{}}} = Invites.revoke(invite)
      assert Repo.get(Invite, invite.id)
    end

    test "keeps the original timestamp on a second revoke" do
      {:ok, revoked} = Invites.revoke(create!())

      assert {:ok, again} = Invites.revoke(revoked)
      assert again.revoked_at == revoked.revoked_at
    end
  end

  describe "regenerate/1" do
    test "revokes the old row, mints a new one with the same hint and label and links them" do
      old = create!()

      assert {:ok, %Invite{} = new} = Invites.regenerate(old)
      assert new.id != old.id
      assert new.code != old.code
      assert Regex.match?(@code_format, new.code)
      assert new.room_id == old.room_id
      assert new.room_code == old.room_code
      assert new.host_user_id == old.host_user_id
      assert new.seat_hint == "partner"
      assert new.label == "Anna"
      assert new.revoked_at == nil
      assert new.superseded_by == nil

      old = reload(old)
      assert %DateTime{} = old.revoked_at
      assert old.superseded_by == new.id
    end

    test "the old row reads revoked even though the new room is waiting (KD8)" do
      old = create!()
      {:ok, new} = Invites.regenerate(old)
      old = reload(old)

      assert Invites.state(old, lookup(room(old))) == :revoked
      assert Invites.state(new, lookup(room(new))) == :open
    end

    test "enforces the lifetime cap without revoking the old link" do
      room_id = Ecto.UUID.generate()
      old = create!(room_id: room_id)

      for _ <- 1..19 do
        invite = create!(room_id: room_id)
        assert {:ok, _revoked} = Invites.revoke(invite)
      end

      assert {:error, :invite_limit} = Invites.regenerate(old)
      assert reload(old).revoked_at == nil
      assert Invites.count_for_room(room_id) == 20
    end

    test "a repeated regeneration of the same stale struct is rejected" do
      old = create!()

      assert {:ok, _new} = Invites.regenerate(old)
      assert {:error, :invite_revoked} = Invites.regenerate(old)
      assert Invites.count_for_room(old.room_id) == 2
    end
  end

  describe "supersede/2" do
    test "sets superseded_by without revoking" do
      old = create!()
      new = create!()

      assert {:ok, %Invite{superseded_by: id, revoked_at: nil}} = Invites.supersede(old, new)
      assert id == new.id
    end

    test "refuses to point an invite at itself" do
      invite = create!()

      assert Invites.supersede(invite, invite) == {:error, :self_reference}
      assert reload(invite).superseded_by == nil
    end
  end

  describe "record_redemption/2" do
    test "writes the row and increments redeem_count" do
      invite = create!()
      user_id = Ecto.UUID.generate()

      assert {:ok, %Redemption{} = redemption} =
               Invites.record_redemption(invite, %{
                 user_id: user_id,
                 position: "south",
                 platform: "ios",
                 source: "qr"
               })

      assert redemption.invite_id == invite.id
      assert redemption.user_id == user_id
      assert redemption.position == "south"
      assert redemption.platform == "ios"
      assert redemption.source == "qr"
      assert reload(invite).redeem_count == 1

      assert {:ok, %Redemption{position: "north"}} =
               Invites.record_redemption(invite, %{
                 user_id: Ecto.UUID.generate(),
                 position: :north
               })

      assert reload(invite).redeem_count == 2
    end

    test "returns the existing row for a repeated invite/user pair without incrementing" do
      invite = create!()
      user_id = Ecto.UUID.generate()

      assert {:ok, %Redemption{id: redemption_id}} =
               Invites.record_redemption(invite, %{user_id: user_id, position: "south"})

      assert {:ok, %Redemption{id: ^redemption_id, position: "south"}} =
               Invites.record_redemption(invite, %{user_id: user_id, position: "north"})

      assert reload(invite).redeem_count == 1
    end

    test "stores platform and source outside the known sets as unknown" do
      invite = create!()

      assert {:ok, %Redemption{platform: "unknown", source: "unknown"}} =
               Invites.record_redemption(invite, %{
                 user_id: Ecto.UUID.generate(),
                 position: "south",
                 platform: "tv",
                 source: "x"
               })

      assert {:ok, %Redemption{platform: "unknown", source: "unknown"}} =
               Invites.record_redemption(invite, %{
                 user_id: Ecto.UUID.generate(),
                 position: "south"
               })
    end

    test "rejects a missing user or an unknown position and leaves redeem_count untouched" do
      invite = create!()

      assert {:error, changeset} = Invites.record_redemption(invite, %{position: "south"})
      assert %{user_id: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Invites.record_redemption(invite, %{
                 user_id: Ecto.UUID.generate(),
                 position: "middle"
               })

      assert %{position: ["is invalid"]} = errors_on(changeset)
      assert reload(invite).redeem_count == 0
    end
  end

  describe "record_event/2" do
    test "lists the origin kinds" do
      assert Event.kinds() == @origin_kinds
    end

    test "writes a row for every origin kind" do
      invite = create!()

      for kind <- Event.kinds() do
        assert {:ok, %Event{kind: ^kind}} = Invites.record_event(invite, %{kind: kind})
      end

      assert length(events(invite)) == length(Event.kinds())
    end

    test "rejects an unknown kind" do
      assert {:error, changeset} = Invites.record_event(create!(), %{kind: "teleported"})
      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts an atom kind and stores platform, ua_class and user_id" do
      invite = create!()
      user_id = Ecto.UUID.generate()

      assert {:ok, event} =
               Invites.record_event(invite, %{
                 kind: :seat_claimed,
                 platform: "android",
                 ua_class: "mobile",
                 user_id: user_id
               })

      assert event.invite_id == invite.id
      assert event.kind == "seat_claimed"
      assert event.platform == "android"
      assert event.ua_class == "mobile"
      assert event.user_id == user_id
    end

    test "coerces a missing or unknown platform to unknown" do
      assert {:ok, %Event{platform: "unknown"}} =
               Invites.record_event(create!(), %{kind: "shared", platform: "tv"})

      assert {:ok, %Event{platform: "unknown"}} =
               Invites.record_event(create!(), %{kind: "shared"})
    end
  end

  describe "record_upgrade/1" do
    test "writes guest_upgraded on the invite of the user's latest redemption" do
      user_id = Ecto.UUID.generate()
      first = create!()
      latest = create!()
      {:ok, _} = Invites.record_redemption(first, %{user_id: user_id, position: "south"})
      {:ok, _} = Invites.record_redemption(latest, %{user_id: user_id, position: "north"})

      assert {:ok, %Event{kind: "guest_upgraded", user_id: ^user_id, invite_id: invite_id}} =
               Invites.record_upgrade(user_id)

      assert invite_id == latest.id
      assert events(first) == []
      assert [%Event{kind: "guest_upgraded"}] = events(latest)
    end

    test "is a no-op for a user without redemptions" do
      assert Invites.record_upgrade(Ecto.UUID.generate()) == {:ok, nil}
      assert Repo.aggregate(Event, :count) == 0
    end
  end

  describe "revoke_hosted/1" do
    test "revokes the user's active invites, nulls every label and leaves other hosts alone" do
      host = Ecto.UUID.generate()
      active = create!(host_user_id: host, label: "Anna")
      {:ok, revoked} = Invites.revoke(create!(host_user_id: host, label: "Bob"))
      expired = expire!(create!(host_user_id: host, label: "Cid"))
      other = create!(label: "Dee")

      assert {:ok, 1} = Invites.revoke_hosted(host)

      assert %Invite{revoked_at: %DateTime{}, label: nil} = reload(active)
      assert %Invite{revoked_at: revoked_at, label: nil} = reload(revoked)
      assert revoked_at == revoked.revoked_at
      assert %Invite{revoked_at: nil, label: nil} = reload(expired)
      assert %Invite{revoked_at: nil, label: "Dee"} = reload(other)
    end

    test "counts zero for a user without invites" do
      assert {:ok, 0} = Invites.revoke_hosted(Ecto.UUID.generate())
    end
  end

  describe "count_for_room/1" do
    test "counts every invite of the room, revoked ones included" do
      room_id = Ecto.UUID.generate()
      create!(room_id: room_id)
      {:ok, _} = Invites.revoke(create!(room_id: room_id))
      create!()

      assert Invites.count_for_room(room_id) == 2
      assert Invites.count_for_room(Ecto.UUID.generate()) == 0
    end
  end

  describe "redemption_user_ids/1" do
    test "lists the distinct users who redeemed the invite" do
      invite = create!()
      other = create!()
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      {:ok, _} = Invites.record_redemption(invite, %{user_id: a, position: "south"})
      {:ok, _} = Invites.record_redemption(invite, %{user_id: b, position: "north"})
      {:ok, _} = Invites.record_redemption(invite, %{user_id: a, position: "east"})

      {:ok, _} =
        Invites.record_redemption(other, %{user_id: Ecto.UUID.generate(), position: "west"})

      assert Enum.sort(Invites.redemption_user_ids(invite)) == Enum.sort([a, b])
      assert reload(invite).redeem_count == 2
      assert length(Invites.redemption_user_ids(other.id)) == 1
      assert Invites.redemption_user_ids(create!()) == []
    end
  end

  describe "record_game_completed/1" do
    test "writes one game_completed event per redemption of the room's invites" do
      room_id = Ecto.UUID.generate()
      old = create!(room_id: room_id)
      {:ok, new} = Invites.regenerate(old)
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      c = Ecto.UUID.generate()
      {:ok, _} = Invites.record_redemption(old, %{user_id: a, position: "south"})
      {:ok, _} = Invites.record_redemption(new, %{user_id: b, position: "east"})
      {:ok, _} = Invites.record_redemption(new, %{user_id: c, position: "west"})

      {:ok, _} =
        Invites.record_redemption(create!(), %{user_id: Ecto.UUID.generate(), position: "west"})

      assert {:ok, 3} = Invites.record_game_completed(room_id)

      assert [%Event{kind: "game_completed", user_id: ^a, platform: "unknown"}] = events(old)
      assert events(new) |> Enum.map(& &1.user_id) |> Enum.sort() == Enum.sort([b, c])
      assert Enum.all?(events(new), &(&1.kind == "game_completed"))
      assert Repo.aggregate(Event, :count) == 3
    end

    test "writes nothing for a room without invites or redemptions" do
      assert {:ok, 0} = Invites.record_game_completed(Ecto.UUID.generate())

      idle = create!()
      assert {:ok, 0} = Invites.record_game_completed(idle.room_id)
    end
  end

  describe "url/1 and share_text/1" do
    test "url joins the configured base and the code" do
      invite = create!(%{}, generator: fn -> "7KQ4M2XB" end)
      base = Application.fetch_env!(:pidro_server, PidroServer.Invites)[:link_base_url]

      assert Invites.url(invite) == "#{base}/7KQ4M2XB"
      assert String.ends_with?(Invites.url(invite), "/j/7KQ4M2XB")
    end

    test "share_text renders the origin template with the URL and the dashed code" do
      invite = create!(%{}, generator: fn -> "7KQ4M2XB" end)
      url = Invites.url(invite)

      assert Invites.share_text(invite) == "Come play Pidro with me 🃏 #{url} — code 7KQ4-M2XB"
    end
  end

  describe "state/2" do
    test "reads open for a waiting, unlocked room with a free seat" do
      invite = create!()

      assert Invites.state(invite, lookup(room(invite))) == :open
    end

    test "passes the invite's room_code to the lookup" do
      invite = create!(room_code: "ZZ99")
      lookup = fn "ZZ99" -> {:ok, room(invite)} end

      assert Invites.state(invite, lookup) == :open
    end

    test "reads revoked first, without consulting the lookup" do
      {:ok, invite} = Invites.revoke(expire!(create!()))
      {:ok, invite} = Invites.supersede(invite, create!())
      never = fn _code -> flunk("the lookup must not run for a revoked invite") end

      assert Invites.state(invite, never) == :revoked
    end

    test "reads moved while the superseding invite's room is waiting, open or full" do
      old = create!()
      new = create!(room_code: "ZZ99")
      {:ok, old} = Invites.supersede(old, new)

      assert Invites.state(old, lookup([room(old), room(new)])) == :moved
      assert Invites.state(old, lookup([room(old), room(new, seats_taken: 4)])) == :moved
      assert Invites.state(old, lookup([room(new)])) == :moved
    end

    test "reads expired or closed, never moved, once the superseding invite's room has started" do
      old = create!()
      new = create!(room_code: "ZZ99")
      {:ok, old} = Invites.supersede(old, new)
      started = room(new, status: :playing)

      assert Invites.state(old, lookup([started])) == :closed
      assert Invites.state(expire!(old), lookup([started])) == :expired
    end

    test "falls through to its own room when the superseding invite is not open or full" do
      old = create!()
      new = create!(room_code: "ZZ99")
      {:ok, old} = Invites.supersede(old, new)

      assert Invites.state(old, lookup([room(old), room(new, locked: true)])) == :open
      assert Invites.state(old, lookup([room(old)])) == :open

      {:ok, _} = Invites.revoke(new)
      assert Invites.state(old, lookup([room(old), room(new)])) == :open
      assert Invites.state(old, lookup(nil)) == :closed
    end

    test "reads expired before closed" do
      invite = expire!(create!())

      assert Invites.state(invite, lookup(nil)) == :expired
      assert Invites.state(invite, lookup(room(invite))) == :expired
    end

    test "reads closed when no live room carries the invite's room_id" do
      invite = create!()

      assert Invites.state(invite, lookup(nil)) == :closed
      assert Invites.state(invite, lookup(room(invite, id: Ecto.UUID.generate()))) == :closed
      assert Invites.state(invite, lookup(room(invite, status: :closed))) == :closed
    end

    test "reads started when the room is playing or finished" do
      invite = create!()

      assert Invites.state(invite, lookup(room(invite, status: :playing))) == :started
      assert Invites.state(invite, lookup(room(invite, status: :finished))) == :started
    end

    test "reads locked before full" do
      invite = create!()

      assert Invites.state(invite, lookup(room(invite, locked: true))) == :locked
      assert Invites.state(invite, lookup(room(invite, locked: true, seats_taken: 4))) == :locked
    end

    test "reads full when four seats are taken" do
      invite = create!()

      assert Invites.state(invite, lookup(room(invite, seats_taken: 4))) == :full
      assert Invites.state(invite, lookup(room(invite, status: :ready, seats_taken: 4))) == :full
    end

    test "counts seats from a RoomManager room struct" do
      invite = create!()
      # U2 adds :id to Room; until then the stub carries it next to the struct fields.
      base =
        %Room{code: invite.room_code, host_id: "host", status: :waiting}
        |> Map.put(:id, invite.room_id)

      open = %{base | positions: %{north: "host", east: nil, south: nil, west: nil}}
      full = %{base | positions: %{north: "host", east: "b", south: "c", west: "d"}}

      assert Invites.state(invite, lookup(open)) == :open
      assert Invites.state(invite, lookup(full)) == :full
    end
  end
end
