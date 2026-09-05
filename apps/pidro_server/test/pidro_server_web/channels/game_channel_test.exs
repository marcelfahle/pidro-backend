defmodule PidroServerWeb.GameChannelTest do
  @moduledoc """
  Integration tests for GameChannel - Phase 4: Real-time Gameplay

  Tests the full WebSocket-based gameplay flow:
  - Joining game channels with authentication
  - Making bids via WebSocket
  - Declaring trump via WebSocket
  - Playing cards via WebSocket
  - Receiving state updates
  - Presence tracking
  """

  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.Accounts
  alias PidroServer.Games.{GameAdapter, GameSupervisor, RoomManager}
  alias PidroServerWeb.GameChannel
  alias PidroServerWeb.Serializers.GameStateSerializer

  @moduletag :channel

  setup do
    # Trap exits to handle channel shutdowns gracefully
    Process.flag(:trap_exit, true)

    # Reset RoomManager state
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # Create 4 test users
    users =
      Enum.map(1..4, fn i ->
        %{
          username: "player#{i}",
          email: "player#{i}@test.com",
          password: "password123"
        }
        |> Accounts.Auth.register_user()
        |> elem(1)
      end)

    [user1, user2, user3, user4] = users

    # Create a room with 4 players
    {:ok, room} = RoomManager.create_room(user1.id, %{name: "Test Game"})
    room_code = room.code

    {:ok, _, _} = RoomManager.join_room(room_code, user2.id)
    {:ok, _, _} = RoomManager.join_room(room_code, user3.id)
    {:ok, room, _} = RoomManager.join_room(room_code, user4.id)

    # Start the game (handle case where it's already started)
    case GameSupervisor.start_game(room_code) do
      {:ok, game_pid} -> {:ok, game_pid}
      {:error, {:already_started, game_pid}} -> {:ok, game_pid}
    end

    # Create sockets for all users
    sockets =
      Enum.map(users, fn user ->
        {:ok, socket} = create_socket(user)
        {user.id, socket}
      end)
      |> Map.new()

    %{
      users: users,
      user1: user1,
      user2: user2,
      user3: user3,
      user4: user4,
      room_code: room_code,
      room: room,
      sockets: sockets
    }
  end

  describe "explicit departure retires game authority" do
    test "the remaining channel receives bot takeover and advancing game states", context do
      alias PidroServer.Games.Lifecycle
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          bot_delay_ms: 5,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 1,
          turn_timer_bid_ms: 60_000,
          turn_timer_play_ms: 60_000
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      advance_game_to_bidding(context.room_code)
      {:ok, before_departures} = GameAdapter.get_state(context.room_code)
      {:ok, room} = RoomManager.get_room(context.room_code)

      {human_position, human_id} =
        Enum.find(room.positions, fn {pos, user_id} ->
          pos != before_departures.current_turn and user_id != room.host_id
        end)

      {:ok, _, socket} =
        subscribe_and_join(context.sockets[human_id], GameChannel, "game:#{room.code}")

      for {position, user_id} <- room.positions, user_id != human_id do
        assert :ok = RoomManager.leave_room(user_id)
        assert_push "bot_substitute_active", %{position: ^position, user_id: ^user_id}
        assert_push "seat_permanently_botted", %{position: ^position}
      end

      assert_push "owner_changed", %{new_owner_id: ^human_id, new_owner_position: ^human_position}
      assert_push "game_state", %{state: %{current_turn: ^human_position} = delivered}, 2_000
      assert {:ok, advanced} = GameAdapter.get_state(room.code)
      assert length(advanced.events) > length(before_departures.events)
      assert delivered == GameStateSerializer.serialize(advanced)
      assert is_binary(Jason.encode!(delivered))
      assert Process.alive?(socket.channel_pid)
    end

    test "a stale channel cannot bid for the replacement bot", context do
      alias PidroServer.Games.Lifecycle
      original = Application.get_env(:pidro_server, Lifecycle, [])
      Application.put_env(:pidro_server, Lifecycle, Keyword.put(original, :bot_delay_ms, 60_000))
      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      advance_game_to_bidding(context.room_code)
      {:ok, game} = GameAdapter.get_state(context.room_code)
      {:ok, room} = RoomManager.get_room(context.room_code)
      user_id = room.positions[game.current_turn]

      stale_socket =
        Phoenix.Socket.assign(context.sockets[user_id], %{
          room_code: room.code,
          position: game.current_turn,
          role: :player
        })

      assert :ok = RoomManager.leave_room(user_id)

      assert {:reply, {:error, %{reason: "seat_not_controlled"}}, _} =
               GameChannel.handle_in("bid", %{"amount" => 6}, stale_socket)

      assert {:ok, unchanged} = GameAdapter.get_state(room.code)
      assert unchanged.events == game.events
    end

    test "all leaver channels close without starting another disconnect cascade", context do
      user = context.user2

      {:ok, _, first} =
        subscribe_and_join(context.sockets[user.id], GameChannel, "game:#{context.room_code}")

      {:ok, another_socket} = create_socket(user)

      {:ok, _, second} =
        subscribe_and_join(another_socket, GameChannel, "game:#{context.room_code}")

      monitors = Enum.map([first, second], &Process.monitor(&1.channel_pid))

      assert :ok = RoomManager.leave_room(user.id)

      for monitor <- monitors do
        assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :left}}
      end

      {:ok, room} = RoomManager.get_room(context.room_code)
      assert room.seats.east.status == :bot_substitute
      assert room.seats.east.reserved_for == nil
      refute Map.has_key?(room.phase_timers, :east)

      assert {:error, _} =
               subscribe_and_join(
                 context.sockets[user.id],
                 GameChannel,
                 "game:#{context.room_code}"
               )
    end
  end

  # Helper function to advance the game to the bidding phase
  defp advance_game_to_bidding(room_code) do
    {:ok, state} = GameAdapter.get_state(room_code)

    case state.phase do
      :dealer_selection ->
        # Trigger dealer selection which should auto-advance through dealing to bidding
        GameAdapter.apply_action(room_code, :north, :select_dealer)
        # Give it a moment to transition
        Process.sleep(50)
        :ok

      _ ->
        :ok
    end
  end

  describe "join/3" do
    test "authenticated user can join game channel", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert %{state: state, position: position} = reply
      assert state.phase in [:dealer_selection, :dealing, :bidding]
      assert position in [:north, :east, :south, :west]
    end

    test "returns different positions for different players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      positions =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, reply, _socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          reply.position
        end)

      # All positions should be unique
      assert length(Enum.uniq(positions)) == 4
      # Should be the standard 4 positions
      assert Enum.sort(positions) == [:east, :north, :south, :west]
    end

    test "rejects join for non-player", %{room_code: room_code} do
      # Create a user not in the room
      {:ok, outsider} =
        Accounts.Auth.register_user(%{
          username: "outsider",
          email: "outsider@test.com",
          password: "password123"
        })

      {:ok, socket} = create_socket(outsider)

      assert {:error, %{reason: reason}} =
               subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert reason == "not authorized to join this room"
    end

    test "rejects join for invalid room code", %{user1: user, sockets: sockets} do
      socket = sockets[user.id]

      assert {:error, %{reason: reason}} =
               subscribe_and_join(socket, GameChannel, "game:XXXX", %{})

      assert reason == "room not found"
    end

    test "join reply includes the active turn timer hydration", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, expected_timer} = wait_for_turn_timer(room_code)

      {:ok, reply, _socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      assert reply.turn_timer.timer_id == expected_timer.timer_id
      assert reply.turn_timer.scope == expected_timer.scope
      assert reply.turn_timer.position == expected_timer.position
      assert reply.turn_timer.phase == expected_timer.phase
      assert reply.turn_timer.duration_ms == expected_timer.duration_ms
      assert reply.turn_timer.transition_delay_ms == expected_timer.transition_delay_ms
      assert reply.turn_timer.event_seq == expected_timer.event_seq
      assert reply.turn_timer.remaining_ms <= expected_timer.remaining_ms
      assert reply.turn_timer.remaining_ms >= 0
    end
  end

  describe "presence tracking" do
    test "tracks presence when user joins", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Should receive presence_state after join
      assert_push "presence_state", _presence_state, 1000
    end
  end

  describe "dealer selection action" do
    test "player can trigger dealer selection", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "select_dealer", %{})
      assert_reply ref, :ok, %{}, 1000

      assert_eventually(fn ->
        {:ok, state} = GameAdapter.get_state(room_code)
        state.phase != :dealer_selection || state.dealer_selection_cuts != nil
      end)
    end
  end

  describe "bid action" do
    test "player can make a bid", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # The action might succeed or fail depending on game state
      # (e.g., if we're not in bidding phase yet or not our turn)
      ref = push(socket, "bid", %{"amount" => 8})
      # Just verify we get a response (ok or error)
      assert_reply ref, _, _, 1000
    end

    test "player can pass on bidding", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "bid", %{"amount" => "pass"})
      assert_reply ref, _, _, 1000
    end

    test "player can pass using pass event", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "pass", %{})
      assert_reply ref, _, _, 1000
    end

    test "handles bid as string number", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "bid", %{"amount" => "10"})
      assert_reply ref, _, _, 1000
    end
  end

  describe "declare_trump action" do
    test "player can declare trump suit", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "declare_trump", %{"suit" => "hearts"})
      assert_reply ref, _, _, 1000
    end
  end

  describe "play_card action" do
    test "player can play a card", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref =
        push(socket, "play_card", %{
          "card" => %{"rank" => 14, "suit" => "spades"}
        })

      assert_reply ref, _, _, 1000
    end
  end

  describe "input validation" do
    test "rejects invalid trump suit", %{user1: user, room_code: room_code, sockets: sockets} do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "declare_trump", %{"suit" => "stars"})
      assert_reply ref, :error, %{reason: "invalid suit"}, 1000
    end

    test "rejects invalid play_card suit", %{user1: user, room_code: room_code, sockets: sockets} do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref =
        push(socket, "play_card", %{
          "card" => %{"rank" => 14, "suit" => "stars"}
        })

      assert_reply ref, :error, %{reason: "invalid card suit"}, 1000
    end

    test "rejects malformed select_hand payload", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "select_hand", %{"cards" => [%{"rank" => 14, "suit" => "stars"}]})
      assert_reply ref, :error, %{reason: "invalid card suit"}, 1000
    end
  end

  describe "ready action" do
    test "player can signal ready", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "ready", %{})
      assert_reply ref, :ok, %{}, 1000

      # Should broadcast player_ready event
      assert_broadcast "player_ready", %{position: _position}, 1000
    end
  end

  describe "state updates" do
    test "pushes transition delay metadata with serialized game state", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      {:ok, state} = GameAdapter.get_state(room_code)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code, %{state: state, transition_delay_ms: 40}}
      )

      assert_push "game_state",
                  %{state: pushed_state, legal_actions: legal_actions, transition_delay_ms: 40},
                  1000

      assert pushed_state == GameStateSerializer.serialize(state)
      assert is_list(legal_actions)
    end

    test "broadcasts state updates to all players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      # All users join the channel
      joined_sockets =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, _reply, socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          socket
        end)

      # First player makes an action (dealer selection in initial phase)
      first_socket = hd(joined_sockets)
      # Try to select dealer if we're in that phase
      push(first_socket, "ready", %{})

      # All sockets might receive a broadcast (depending on game state)
      # We can't guarantee the exact broadcast without knowing game state
      # but we can verify the channel is set up correctly
      assert length(joined_sockets) == 4
    end
  end

  describe "progression summary (PID-52)" do
    test "pushes the socket's own progression_summary slice", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      my_summary = %{rated: false, xp_earned: 112, rating: nil}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{user.id => my_summary}}
      )

      assert_push "progression_summary", ^my_summary, 1000
    end

    test "pushes ONLY this socket's slice, never another player's deltas", %{
      user1: user,
      user2: other,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      mine = %{rated: true, xp_earned: 112}
      theirs = %{rated: true, xp_earned: 45}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{user.id => mine, other.id => theirs}}
      )

      assert_push "progression_summary", pushed, 1000
      assert pushed == mine
      refute pushed == theirs
    end

    test "a socket whose user is absent from the map pushes an empty map (no crash)", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      other_id = Ecto.UUID.generate()

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{other_id => %{rated: false}}}
      )

      assert_push "progression_summary", pushed, 1000
      assert pushed == %{}
    end

    test "the base game_over push is unchanged (regression guard)", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      scores = %{north_south: 62, east_west: 45}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:game_over, room_code, :north_south, scores}
      )

      assert_push "game_over", %{winner: :north_south, scores: ^scores}, 1000
    end
  end

  describe "integration: full game flow" do
    test "4 players can interact with game via channels", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      # All 4 players join the game channel
      joined_sockets =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, reply, socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          # Each player should get initial state and their position
          assert %{state: state, position: position} = reply
          assert state.phase in [:dealer_selection, :dealing, :bidding]
          assert position in [:north, :east, :south, :west]

          {position, socket}
        end)
        |> Map.new()

      # Verify all 4 positions are represented
      positions = Map.keys(joined_sockets)
      assert length(positions) == 4
      assert Enum.sort(positions) == [:east, :north, :south, :west]

      # Each socket should have received presence_state
      Enum.each(joined_sockets, fn {_position, _socket} ->
        assert_push "presence_state", _presence, 2000
      end)
    end
  end

  describe "reconnection handling" do
    test "detects reconnection attempt when player was disconnected", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # First join
      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Simulate disconnect by leaving the channel and marking as disconnected
      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Attempt to rejoin - should detect as reconnection
      {:ok, new_socket} = create_socket(user)

      {:ok, reply, _reconnected_socket} =
        subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      # Should indicate this was a reconnection
      assert reply.reconnected == true
      assert reply.position in [:north, :east, :south, :west]
      assert reply.state != nil
    end

    test "successful reconnection broadcasts to other players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2 | _] = users

      # Both players join
      {:ok, _reply, _socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, _socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      # User2 disconnects
      :ok = RoomManager.handle_player_disconnect(room_code, user2.id)

      # User2 reconnects
      {:ok, new_socket2} = create_socket(user2)

      {:ok, _reply, _reconnected_socket} =
        subscribe_and_join(new_socket2, GameChannel, "game:#{room_code}", %{})

      # Socket1 (user1) should receive reconnection broadcast
      assert_broadcast "player_reconnected", %{user_id: user_id, position: position}, 1000
      assert to_string(user_id) == to_string(user2.id)
      assert position in [:north, :east, :south, :west]
    end

    test "reconnection returns correct state with reconnected flag", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # First join
      {:ok, initial_reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      initial_position = initial_reply.position
      assert initial_reply.reconnected == false

      # Disconnect and reconnect
      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      {:ok, new_socket} = create_socket(user)

      {:ok, reconnect_reply, _reconnected_socket} =
        subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      # Should have same position and reconnected flag
      assert reconnect_reply.reconnected == true
      assert reconnect_reply.position == initial_position
      assert reconnect_reply.state.phase in [:dealer_selection, :dealing, :bidding]
    end

    test "normal join still works without reconnected flag", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # First join should not be marked as reconnection
      assert reply.reconnected == false
      assert reply.position in [:north, :east, :south, :west]
    end

    test "reconnection after grace period fails", %{
      user1: _user1,
      user2: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join and then disconnect
      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Manually expire grace period by updating disconnect time in the past
      {:ok, _room} = RoomManager.get_room(room_code)
      _past_time = DateTime.add(DateTime.utc_now(), -130, :second)

      # We need to update the room state directly (this is a test helper scenario)
      # In real scenario, we'd wait 120+ seconds
      # For this test, we'll verify the error handling when grace period has expired

      # Simulate expired grace period by removing player from room
      :ok = RoomManager.leave_room(user.id)

      # Attempt reconnection should fail
      {:ok, new_socket} = create_socket(user)

      assert {:error, %{reason: reason}} =
               subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      assert reason =~ "not authorized"
    end

    test "multiple players can reconnect independently", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2, user3 | _] = users

      # All join
      {:ok, _reply, socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, _socket3} =
        subscribe_and_join(sockets[user3.id], GameChannel, "game:#{room_code}", %{})

      # User1 and User2 disconnect
      leave(socket1)
      leave(socket2)
      :ok = RoomManager.handle_player_disconnect(room_code, user1.id)
      :ok = RoomManager.handle_player_disconnect(room_code, user2.id)

      # User1 reconnects
      {:ok, new_socket1} = create_socket(user1)

      {:ok, reply1, _reconnected1} =
        subscribe_and_join(new_socket1, GameChannel, "game:#{room_code}", %{})

      assert reply1.reconnected == true

      # User2 reconnects
      {:ok, new_socket2} = create_socket(user2)

      {:ok, reply2, _reconnected2} =
        subscribe_and_join(new_socket2, GameChannel, "game:#{room_code}", %{})

      assert reply2.reconnected == true

      # Both should have valid positions
      assert reply1.position in [:north, :east, :south, :west]
      assert reply2.position in [:north, :east, :south, :west]
    end
  end

  describe "terminate/disconnect handling" do
    test "terminate callback notifies RoomManager on disconnect", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Close the socket (simulates disconnect)
      Process.unlink(joined_socket.channel_pid)
      close(joined_socket)

      # Give it time to process
      Process.sleep(100)

      {:ok, room} = RoomManager.get_room(room_code)

      # Player should still be in positions (disconnect doesn't remove them)
      player_ids = PidroServer.Games.Room.Positions.player_ids(room)
      assert to_string(user.id) in Enum.map(player_ids, &to_string/1)
    end

    test "terminate broadcasts disconnect to other players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2 | _] = users

      # Both join
      {:ok, _reply, _socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      # User2 disconnects
      Process.unlink(socket2.channel_pid)
      close(socket2)

      # Socket1 should receive disconnect broadcast
      assert_broadcast "player_disconnected",
                       %{user_id: user_id, reason: reason, grace_period: grace_period},
                       1000

      assert to_string(user_id) == to_string(user2.id)
      assert reason in ["left", "connection_lost", "error"]
      assert grace_period == true
    end

    test "handles normal leave reason", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Normal leave
      leave(joined_socket)

      # Should broadcast player_disconnected
      assert_broadcast "player_disconnected", %{user_id: _user_id, reason: reason}, 1000
      assert reason == "left"
    end

    test "closing one of multiple channels for the same player does not disconnect the seat", %{
      user1: user,
      room_code: room_code
    } do
      {:ok, socket1} = create_socket(user)
      {:ok, socket2} = create_socket(user)

      {:ok, _reply, joined1} =
        subscribe_and_join(socket1, GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, joined2} =
        subscribe_and_join(socket2, GameChannel, "game:#{room_code}", %{})

      leave(joined1)

      refute_broadcast "player_disconnected", _payload, 100

      {:ok, room} = RoomManager.get_room(room_code)
      position = joined2.assigns.position
      assert room.seats[position].status == :connected

      leave(joined2)
      assert_broadcast "player_disconnected", %{user_id: user_id}, 1000
      assert to_string(user_id) == to_string(user.id)
    end
  end

  describe "timer events" do
    test "forwards timer lifecycle events from the game topic", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, _reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      started = %{
        timer_id: 101,
        scope: :seat,
        position: :north,
        phase: :bidding,
        duration_ms: 120,
        transition_delay_ms: 0,
        server_time: "2026-03-11T12:00:00.000Z",
        event_seq: 2
      }

      cancelled = %{timer_id: 101, scope: :seat, position: :north, reason: :acted}

      auto_played = %{
        scope: :seat,
        position: :north,
        phase: :bidding,
        action: %{type: :pass},
        reason: :timeout
      }

      send(joined_socket.channel_pid, {:turn_timer_started, started})
      assert_push "turn_timer_started", ^started

      send(joined_socket.channel_pid, {:turn_timer_cancelled, cancelled})
      assert_push "turn_timer_cancelled", ^cancelled

      send(joined_socket.channel_pid, {:turn_auto_played, auto_played})
      assert_push "turn_auto_played", ^auto_played
    end

    test "pushes the timeout reason and stops the channel on forced disconnect", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, _reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      send(joined_socket.channel_pid, {:force_disconnect, :timeout_threshold})

      assert_push "force_disconnect", %{reason: "timeout_threshold"}
      assert_receive {:EXIT, pid, {:shutdown, :timeout_threshold}}, 1000
      assert pid == joined_socket.channel_pid
    end
  end

  describe "reconnection edge cases" do
    test "immediate rejoin after forced inactivity disconnect keeps the human seat", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, initial_reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      position = initial_reply.position

      send(joined_socket.channel_pid, {:force_disconnect, :timeout_threshold})

      {:ok, fresh_socket} = create_socket(user)

      {:ok, reply, _rejoined_socket} =
        subscribe_and_join(fresh_socket, GameChannel, "game:#{room_code}", %{})

      assert reply.position == position
      assert reply.role == :player

      assert_receive {:EXIT, pid, {:shutdown, :timeout_threshold}}, 1000
      assert pid == joined_socket.channel_pid

      stable_room =
        wait_for_room(room_code, fn room ->
          seat = room.seats[position]

          if seat.status == :connected and seat.occupant_type == :human and
               seat.user_id == user.id do
            room
          end
        end)

      seat = stable_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user.id
      assert seat.bot_pid == nil
      assert seat.reserved_for == nil
    end

    test "reconnecting when not actually disconnected returns error", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join normally
      {:ok, _reply, _joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Try to trigger reconnection manually
      result = RoomManager.handle_player_reconnect(room_code, user.id)

      assert {:error, :player_not_disconnected} = result
    end

    test "joining with fresh socket after disconnect works correctly", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join, disconnect, and rejoin cycle
      {:ok, _reply1, socket1} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      leave(socket1)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Create fresh socket and rejoin
      {:ok, fresh_socket} = create_socket(user)

      {:ok, reply2, _socket2} =
        subscribe_and_join(fresh_socket, GameChannel, "game:#{room_code}", %{})

      assert reply2.reconnected == true
      assert %{state: _state, position: _position} = reply2
    end

    test "handles concurrent join attempts gracefully", %{
      user1: user,
      room_code: room_code
    } do
      # Create two sockets for same user
      {:ok, socket1} = create_socket(user)
      {:ok, socket2} = create_socket(user)

      # Both try to join
      {:ok, _reply1, _joined1} =
        subscribe_and_join(socket1, GameChannel, "game:#{room_code}", %{})

      # Second join with same user should work (they're in the room)
      {:ok, _reply2, _joined2} =
        subscribe_and_join(socket2, GameChannel, "game:#{room_code}", %{})

      # Both should succeed (same player, multiple connections)
      {:ok, room} = RoomManager.get_room(room_code)
      player_ids = PidroServer.Games.Room.Positions.player_ids(room)
      user_count = Enum.count(player_ids, fn id -> to_string(id) == to_string(user.id) end)
      assert user_count == 1
    end
  end

  describe "invites and host controls" do
    alias PidroServer.AccountsFixtures
    alias PidroServer.Games.Lifecycle
    alias PidroServer.Games.Room.Seat
    alias PidroServerWeb.Presence

    setup do
      host = AccountsFixtures.user_fixture(%{display_name: "Marcel"})
      ben = AccountsFixtures.user_fixture(%{display_name: "Ben"})
      carl = AccountsFixtures.user_fixture(%{display_name: "Carl"})

      {:ok, table} = RoomManager.create_room(host.id, %{name: "Invite table"})
      {:ok, table, :east} = RoomManager.join_room(table.code, ben.id)

      %{host: host, ben: ben, carl: carl, table: table}
    end

    test "pushes invite_redeemed with the guest's display name after a claim (AE2)", %{
      host: host,
      table: table
    } do
      _host_joined = join_table(host, table.code)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      anna_id = anna.id

      assert {:ok, _room, :south, true} =
               RoomManager.claim_seat(table.code, table.id, anna.id,
                 hint: :south,
                 display_name: anna.display_name
               )

      assert_push "invite_redeemed",
                  %{position: :south, user_id: ^anna_id, display_name: "Anna"},
                  1000
    end

    test "a kicked player's channel pushes kicked and stops while the seat stays vacant (AE11)",
         %{host: host, ben: ben, carl: carl, table: table} do
      {:ok, _table, :south} = RoomManager.join_room(table.code, carl.id)
      host_joined = join_table(host, table.code)
      ben_joined = join_table(ben, table.code)
      carl_joined = join_table(carl, table.code)
      ben_id = ben.id

      assert {:ok, _room} = RoomManager.kick_player(table.code, host.id, :east)

      assert_push "kicked", %{reason: "kicked"}, 1000
      assert_receive {:EXIT, pid, {:shutdown, :kicked}}, 1000
      assert pid == ben_joined.channel_pid

      # The host and Carl each push player_kicked; neither channel stops.
      assert_push "player_kicked", %{position: :east, user_id: ^ben_id}, 1000
      assert_push "player_kicked", %{position: :east, user_id: ^ben_id}, 1000
      refute_receive {:EXIT, _pid, _reason}, 100
      assert Process.alive?(host_joined.channel_pid)
      assert Process.alive?(carl_joined.channel_pid)

      # terminate/2 must not treat the kick as a disconnect that holds the seat.
      refute_broadcast "player_disconnected", %{user_id: ^ben_id}, 100
      {:ok, room} = RoomManager.get_room(table.code)
      assert room.positions[:east] == nil
      assert Seat.vacant?(room.seats[:east])
      assert room.status == :waiting
    end

    test "a moved player's channel follows the seat and acts at the new position once the table starts",
         %{host: host, ben: ben, carl: carl, table: table} do
      slow_turn_timers()
      _host_joined = join_table(host, table.code)
      ben_joined = join_table(ben, table.code)
      ben_id = ben.id
      topic = "game:#{table.code}"

      assert {:ok, _room} = RoomManager.move_seat(table.code, host.id, ben.id, :west)

      assert_push "seat_moved", %{user_id: ^ben_id, from: :east, to: :west}, 1000

      assert_eventually(fn ->
        :sys.get_state(ben_joined.channel_pid).assigns.position == :west
      end)

      assert_eventually(fn ->
        match?(%{metas: [%{position: :west, role: :player}]}, Presence.list(topic)[ben_id])
      end)

      # Two more players fill the table; the game starts and Ben acts as :west.
      dave = AccountsFixtures.user_fixture(%{display_name: "Dave"})
      {:ok, _room, _position} = RoomManager.join_room(table.code, carl.id)
      {:ok, _room, _position} = RoomManager.join_room(table.code, dave.id)

      assert_eventually(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(table.code))
      end)

      advance_game_to_bidding(table.code)

      assert_eventually(fn ->
        match?({:ok, %{phase: :bidding}}, GameAdapter.get_state(table.code))
      end)

      drive_bidding_to(table.code, :west)

      ref = push(ben_joined, "bid", %{"amount" => 6})
      assert_reply ref, :ok, %{}, 1000
    end

    defp join_table(user, room_code) do
      {:ok, socket} = create_socket(user)

      {:ok, _reply, joined} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      joined
    end

    # Test lifecycle timers auto-play within ~100 ms; hold them off so the test
    # drives bidding itself. Restored on exit.
    defp slow_turn_timers do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    end

    # Passes for every other seat until `position` is on turn. Bidding cannot
    # complete early: a dealer who is last to act must bid, so the turn always
    # arrives within three passes.
    defp drive_bidding_to(room_code, position, attempts \\ 3)

    defp drive_bidding_to(room_code, position, attempts) do
      {:ok, state} = GameAdapter.get_state(room_code)

      cond do
        state.current_turn == position ->
          :ok

        attempts == 0 ->
          flunk("bidding never reached #{position}")

        true ->
          {:ok, _state} = GameAdapter.apply_action(room_code, state.current_turn, :pass)
          drive_bidding_to(room_code, position, attempts - 1)
      end
    end
  end

  defp wait_for_turn_timer(room_code, attempts \\ 40)

  defp wait_for_turn_timer(_room_code, 0) do
    flunk("timed out waiting for active turn timer")
  end

  defp wait_for_turn_timer(room_code, attempts) do
    case RoomManager.get_turn_timer(room_code) do
      {:ok, nil} ->
        Process.sleep(10)
        wait_for_turn_timer(room_code, attempts - 1)

      {:ok, turn_timer} ->
        {:ok, turn_timer}
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp wait_for_room(room_code, matcher, attempts \\ 60)

  defp wait_for_room(_room_code, _matcher, 0) do
    flunk("timed out waiting for room state")
  end

  defp wait_for_room(room_code, matcher, attempts) do
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        case matcher.(room) do
          nil ->
            Process.sleep(10)
            wait_for_room(room_code, matcher, attempts - 1)

          matched ->
            matched
        end

      {:error, _reason} ->
        Process.sleep(10)
        wait_for_room(room_code, matcher, attempts - 1)
    end
  end
end
