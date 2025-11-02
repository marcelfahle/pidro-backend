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

  alias PidroServer.Games.RoomManager
  alias PidroServer.Accounts
  alias PidroServerWeb.{UserSocket, LobbyChannel}

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

    test "room list includes metadata", %{socket: socket, user: user} do
      # Create a room with metadata
      {:ok, room} =
        RoomManager.create_room(user.id, %{name: "Epic Game", difficulty: "hard"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      created_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert created_room.metadata.name == "Epic Game"
      assert created_room.metadata.difficulty == "hard"
    end
  end

  describe "presence tracking" do
    test "tracks presence when user joins lobby", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Should receive presence_state after join
      assert_push "presence_state", _presence_state, 1000
    end
  end

  describe "lobby_update event" do
    test "broadcasts when new room is created", %{socket: socket, user: user} do
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

      # Should receive lobby_update broadcast
      assert_broadcast "lobby_update", %{rooms: rooms}, 1000
      assert is_list(rooms)
      # Find our created room
      assert Enum.any?(rooms, fn r -> r.code == room.code end)
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

      {:ok, _updated_room} = RoomManager.join_room(room.code, other_user.id)

      # Should receive lobby_update broadcast
      assert_broadcast "lobby_update", %{rooms: _rooms}, 1000
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
        RoomManager.join_room(room.code, u.id)
        # Each join should broadcast lobby_update
        assert_broadcast "lobby_update", %{rooms: _}, 1000
      end)
    end

    test "broadcasts when host leaves and room closes", %{socket: socket, user: user} do
      # Create a room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Closing Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Host leaves (this should close the room)
      :ok = RoomManager.leave_room(user.id)

      # Should receive lobby_update broadcast
      assert_broadcast "lobby_update", %{rooms: rooms}, 1000
      # Room should not be in the list anymore
      refute Enum.any?(rooms, fn r -> r.code == room.code end)
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

      # All sockets should receive the broadcast
      Enum.each(sockets, fn _socket ->
        assert_broadcast "lobby_update", %{rooms: rooms}, 1000
        assert Enum.any?(rooms, fn r -> r.code == room.code end)
      end)
    end
  end

  describe "room serialization" do
    test "serializes room data correctly", %{socket: socket, user: user} do
      {:ok, room} =
        RoomManager.create_room(user.id, %{
          name: "Test Room",
          mode: "competitive"
        })

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
      assert is_binary(serialized_room.created_at)
      assert serialized_room.metadata.name == "Test Room"
      assert serialized_room.metadata.mode == "competitive"
    end
  end
end
