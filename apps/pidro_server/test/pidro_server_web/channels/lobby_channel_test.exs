defmodule PidroServerWeb.LobbyChannelTest do
  @moduledoc """
  Integration tests for LobbyChannel - Phase 4: Real-time Gameplay

  Tests the lobby channel functionality:
  - Joining the lobby
  - Receiving current room list
  - Receiving real-time room updates
  - Presence tracking in lobby
  """

  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.Accounts
  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.LobbyChannel

  @moduletag :channel

  setup do
    # Create a test user
    {:ok, user} =
      Accounts.Auth.register_user(%{
        username: "lobby_user",
        email: "lobby@test.com",
        password: "password123"
      })

    {:ok, socket} = create_socket(user)

    %{user: user, socket: socket}
  end

  describe "join/3" do
    test "authenticated user can join lobby", %{socket: socket} do
      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)
    end

    test "returns current room list on join", %{socket: socket, user: user} do
      # Create a room first
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)
      assert length(rooms) >= 1

      # Find our created room
      created_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert created_room != nil
      assert created_room.host_id == user.id
      assert created_room.player_count == 1
      assert created_room.max_players == 4
      assert created_room.status == :waiting
    end

    test "room list carries the config and no metadata", %{socket: socket, user: user} do
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Epic Game"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      created_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert created_room.config == %{name: "Epic Game", bot_difficulty: "basic", solo: false}
      refute Map.has_key?(created_room, :metadata)
    end

    test "an unknown room attribute is rejected and no room reaches the lobby", %{
      socket: socket,
      user: user
    } do
      assert {:error, {:invalid_room_params, [%{field: "difficulty"}]}} =
               RoomManager.create_room(user.id, %{name: "Epic Game", difficulty: "hard"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      refute Enum.any?(reply.rooms, &(&1.host_id == user.id))
      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
    end

    test "does not return single-player rooms on join", %{socket: socket, user: user} do
      {:ok, solo_room} = RoomManager.create_room(user.id, %{name: "Solo", solo: true})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      refute Enum.any?(rooms, fn room -> room.code == solo_room.code end)
    end
  end

  describe "presence tracking" do
    test "tracks presence when user joins lobby", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Should receive presence_state after join
      assert_push "presence_state", _presence_state, 1000
    end
  end

  describe "lobby events" do
    test "broadcasts when new room is created", %{socket: socket, user: _user} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Create another user to create a room (so it's not us)
      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "other_user",
          email: "other@test.com",
          password: "password123"
        })

      # Create a room
      {:ok, room} = RoomManager.create_room(other_user.id, %{name: "New Room"})

      # Should receive room_created push
      assert_push "room_created", %{room: created_room}, 1000
      assert created_room.code == room.code
    end

    test "does not broadcast single-player room creation", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "solo_creator",
          email: "solo_creator@test.com",
          password: "password123"
        })

      {:ok, _room} =
        RoomManager.create_room(other_user.id, %{name: "Solo Table", solo: true})

      refute_push "room_created", _payload, 200
    end

    test "broadcasts when player joins room", %{socket: socket, user: user} do
      # Create initial room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Create another user and have them join
      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "joiner",
          email: "joiner@test.com",
          password: "password123"
        })

      {:ok, _, _} = RoomManager.join_room(room.code, other_user.id)

      # Should receive room_updated push
      %{room: updated_room} = assert_push_for_room("room_updated", room.code)
      assert updated_room.code == room.code
      assert updated_room.player_count == 2
    end

    test "broadcasts when room becomes ready (4 players)", %{socket: socket, user: user} do
      # Create a room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Full Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Add 3 more players to reach 4 total
      other_users =
        Enum.map(1..3, fn i ->
          {:ok, u} =
            Accounts.Auth.register_user(%{
              username: "player#{i}",
              email: "player#{i}@test.com",
              password: "password123"
            })

          u
        end)

      # Join all 3 players
      Enum.each(other_users, fn u ->
        {:ok, _, _} = RoomManager.join_room(room.code, u.id)
        # Each join should broadcast room_updated
        assert_push "room_updated", %{room: _}, 1000
      end)
    end

    test "broadcasts when host leaves and room closes", %{socket: socket, user: user} do
      # Create a room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Closing Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Host leaves (this should close the room)
      :ok = RoomManager.leave_room(user.id)

      # Should receive room_closed
      assert_push "room_closed", %{room_code: code}, 1000
      assert code == room.code
    end
  end

  describe "multiple users in lobby" do
    test "all users receive room updates", %{user: user1} do
      # Create 3 users and have them all join lobby
      users =
        [user1] ++
          Enum.map(1..2, fn i ->
            {:ok, u} =
              Accounts.Auth.register_user(%{
                username: "multi_user#{i}",
                email: "multi#{i}@test.com",
                password: "password123"
              })

            u
          end)

      # All users join lobby
      sockets =
        Enum.map(users, fn user ->
          {:ok, socket} = create_socket(user)

          {:ok, _reply, socket} =
            subscribe_and_join(socket, LobbyChannel, "lobby", %{})

          socket
        end)

      # First user creates a room
      {:ok, room} = RoomManager.create_room(hd(users).id, %{name: "Shared Room"})

      # All sockets should receive the push messages
      Enum.each(sockets, fn _socket ->
        assert_push "room_created", %{room: created}, 1000
        assert created.code == room.code
      end)
    end
  end

  describe "room serialization" do
    test "serializes room data correctly", %{socket: socket, user: user} do
      # A free-form key is no longer carried through to the lobby: it is rejected.
      assert {:error, {:invalid_room_params, [%{field: "mode", message: _}]}} =
               RoomManager.create_room(user.id, %{name: "Test Room", mode: "competitive"})

      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))

      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})
      {:ok, _room} = RoomManager.set_locked(room.code, user.id, true)

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)

      # Find our created room
      serialized_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert serialized_room != nil
      assert serialized_room.code == room.code
      assert serialized_room.host_id == user.id
      assert serialized_room.player_count == 1
      assert serialized_room.max_players == 4
      assert serialized_room.status == :waiting
      assert serialized_room.locked == true
      assert is_binary(serialized_room.created_at)
      assert serialized_room.config == %{name: "Test Room", bot_difficulty: "basic", solo: false}
      refute Map.has_key?(serialized_room, :metadata)
    end

    test "AE4: the lobby payload and the REST serializer report the same config", %{
      socket: socket,
      user: user
    } do
      {:ok, room} =
        RoomManager.create_room(user.id, %{name: "Friday", bot_difficulty: "smart"})

      {:ok, %{rooms: rooms}, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      lobby_room = Enum.find(rooms, &(&1.code == room.code))
      rest_room = RoomJSON.room(room)

      assert lobby_room.config == %{name: "Friday", bot_difficulty: "smart", solo: false}
      assert rest_room.config == lobby_room.config

      # Same shape on the wire, not only in Elixir terms.
      assert Jason.decode!(Jason.encode!(rest_room.config)) ==
               Jason.decode!(Jason.encode!(lobby_room.config))
    end

    test "a room created without a name serializes a null name on both transports", %{
      socket: socket,
      user: user
    } do
      {:ok, room} = RoomManager.create_room(user.id)

      {:ok, %{rooms: rooms}, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      lobby_room = Enum.find(rooms, &(&1.code == room.code))

      assert %{"name" => nil} = Jason.decode!(Jason.encode!(lobby_room.config))
      assert %{"name" => nil} = Jason.decode!(Jason.encode!(RoomJSON.room(room).config))
    end

    test "the room_created push carries the config", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      {:ok, room} = RoomManager.create_room("push-host", %{name: "Pushed"})

      assert_push "room_created", %{room: pushed}, 1000
      assert pushed.code == room.code
      assert pushed.config == %{name: "Pushed", bot_difficulty: "basic", solo: false}
      refute Map.has_key?(pushed, :metadata)
    end

    test "seats carry the display name; a guest shows their name, not the generated username",
         %{socket: socket} do
      guest = PidroServer.AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, room} = RoomManager.create_room(guest.id, %{name: "Guest table"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      serialized_room = Enum.find(reply.rooms, fn r -> r.code == room.code end)
      north = Enum.find(serialized_room.seats, fn seat -> seat.position == :north end)

      assert north.player.id == guest.id
      assert north.player.username == guest.username
      assert north.player.display_name == "Anna"
      refute north.player.display_name == guest.username
    end

    test "a seat whose id resolves to nobody carries display_name nil", %{socket: socket} do
      {:ok, room} = RoomManager.create_room("dev_host", %{name: "Dev table"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      serialized_room = Enum.find(reply.rooms, fn r -> r.code == room.code end)
      north = Enum.find(serialized_room.seats, fn seat -> seat.position == :north end)

      assert north.player.is_bot == true
      assert north.player.display_name == nil
    end
  end

  defp assert_push_for_room(event, room_code, attempts \\ 5)

  defp assert_push_for_room(event, room_code, 0) do
    flunk("timed out waiting for #{event} for room #{room_code}")
  end

  defp assert_push_for_room(event, room_code, attempts) do
    assert_push ^event, payload, 1000

    if payload.room.code == room_code do
      payload
    else
      assert_push_for_room(event, room_code, attempts - 1)
    end
  end
end
