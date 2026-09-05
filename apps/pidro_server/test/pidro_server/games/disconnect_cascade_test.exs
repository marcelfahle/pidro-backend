defmodule PidroServer.Games.DisconnectCascadeTest do
  @moduledoc """
  Tests for the three-phase disconnect cascade.

  Phase 1 (Hiccup): Player disconnects → seat becomes :reconnecting → timer scheduled
  Phase 2 (Grace): Hiccup timer fires → bot spawned → seat becomes :bot_substitute
  Phase 3 (Gone): Grace timer fires → bot becomes permanent → seat no longer reclaimable

  These tests verify Phase 1 behavior: disconnect triggers :reconnecting state,
  PubSub events are broadcast, reconnect during Phase 1 restores the seat,
  and phase timers are properly scheduled and cancelled.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # BotSupervisor needed for Phase 2 (SubstituteBot spawning)
    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  # Creates a room with 4 players in :playing state.
  # Returns the room struct and a map of position => user_id.
  defp create_playing_room(user_ids \\ ["user1", "user2", "user3", "user4"]) do
    [host | others] = user_ids
    {:ok, room} = RoomManager.create_room(host, %{name: "Cascade Test"})
    for user_id <- others, do: assert({:ok, _, _} = RoomManager.join_room(room.code, user_id))
    {:ok, playing_room} = RoomManager.get_room(room.code)

    assert playing_room.status == :playing

    # Build position->user_id lookup
    player_positions =
      Enum.reduce(playing_room.seats, %{}, fn {pos, seat}, acc ->
        if seat.user_id, do: Map.put(acc, pos, seat.user_id), else: acc
      end)

    {playing_room, player_positions}
  end

  # Finds the position for a given user_id in the room seats.
  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  describe "explicit live departure" do
    for user_id <- ["user1", "user2"] do
      test "#{user_id} leaves a permanent controller and keeps the room playing" do
        {room, _positions} = create_playing_room()
        user_id = unquote(user_id)
        position = position_for(room, user_id)
        Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

        assert :ok = RoomManager.leave_room(user_id)
        assert {:ok, updated} = RoomManager.get_room(room.code)
        assert updated.status == :playing
        seat = updated.seats[position]
        assert seat.occupant_type == :bot
        assert seat.status == :bot_substitute
        assert Process.alive?(seat.bot_pid)
        assert seat.reserved_for == nil
        refute user_id in Map.values(updated.positions)
        assert {:ok, _game} = GameAdapter.get_state(room.code)
        assert_receive {:bot_substitute_active, %{position: ^position, user_id: ^user_id}}
        assert_receive {:seat_permanently_botted, %{position: ^position}}
      end
    end

    for phase <- [:hiccup, :grace, :permanent] do
      test "leave during #{phase} cancels obsolete timers and retains one controller" do
        {room, _positions} = create_playing_room()
        position = position_for(room, "user2")
        assert :ok = RoomManager.handle_player_disconnect(room.code, "user2")

        if unquote(phase) != :hiccup do
          send(RoomManager, {:phase2_start, room.code, position})
        end

        if unquote(phase) == :permanent do
          send(RoomManager, {:phase3_gone, room.code, position})
        end

        {:ok, before_leave} = RoomManager.get_room(room.code)
        previous_pid = before_leave.seats[position].bot_pid
        assert :ok = RoomManager.leave_room("user2")
        {:ok, after_leave} = RoomManager.get_room(room.code)
        bot_pid = after_leave.seats[position].bot_pid
        assert is_pid(bot_pid) and Process.alive?(bot_pid)
        if previous_pid, do: assert(bot_pid == previous_pid)
        assert after_leave.seats[position].reserved_for == nil
        refute Map.has_key?(after_leave.phase_timers, position)

        send(RoomManager, {:phase2_start, room.code, position})
        send(RoomManager, {:phase3_gone, room.code, position})
        RoomManager.handle_player_disconnect(room.code, "user2")
        {:ok, later} = RoomManager.get_room(room.code)
        assert later.seats[position].bot_pid == bot_pid
        assert later.seats[position].status == :bot_substitute
        assert later.phase_timers == %{}
      end
    end

    test "the last human leaves four live bots in an active multiplayer game" do
      {room, _positions} = create_playing_room()

      for user <- ["user2", "user3", "user4", "user1"],
          do: assert(:ok = RoomManager.leave_room(user))

      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing

      assert Enum.all?(updated.seats, fn {_, seat} ->
               seat.occupant_type == :bot and Process.alive?(seat.bot_pid)
             end)
    end

    test "a failed bot start preserves membership and its existing timer" do
      {room, _positions} = create_playing_room()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, before_leave} = RoomManager.get_room(room.code)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      original_limit = :sys.get_state(supervisor).max_children
      :sys.replace_state(supervisor, &%{&1 | max_children: 0})

      try do
        assert {:error, :bot_start_failed} = RoomManager.leave_room("user2")
        assert {:ok, after_leave} = RoomManager.get_room(room.code)
        assert after_leave.positions == before_leave.positions
        assert after_leave.seats == before_leave.seats
        assert after_leave.phase_timers == before_leave.phase_timers
        assert Process.alive?(Process.whereis(RoomManager))
      after
        :sys.replace_state(supervisor, &%{&1 | max_children: original_limit})
      end
    end

    test "an owner-opened vacancy stays open when its former occupant leaves" do
      {room, _positions} = create_playing_room()
      position = position_for(room, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      send(RoomManager, {:phase2_start, room.code, position})
      assert {:ok, _} = RoomManager.open_seat(room.code, position, room.host_id)

      assert :ok = RoomManager.leave_room("user2")
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].occupant_type == :vacant
      assert updated.seats[position].bot_pid == nil
      assert updated.phase_timers == %{}
    end

    test "an unavailable bot supervisor preserves the room and membership" do
      {room, _positions} = create_playing_room()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, before_leave} = RoomManager.get_room(room.code)
      manager = Process.whereis(RoomManager)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      supervisor_pid = Process.whereis(supervisor)
      Process.unregister(supervisor)

      try do
        assert {:error, :bot_start_failed} = RoomManager.leave_room("user2")
        assert Process.whereis(RoomManager) == manager
        assert {:ok, after_leave} = RoomManager.get_room(room.code)
        assert after_leave.positions == before_leave.positions
        assert after_leave.seats == before_leave.seats
        assert after_leave.phase_timers == before_leave.phase_timers
      after
        Process.register(supervisor_pid, supervisor)
      end
    end

    test "an engine exit during an action does not take down other rooms" do
      {room, positions} = create_playing_room()
      bidding = start_bidding(room.code)
      {:ok, other_room} = RoomManager.create_room("other-user")
      manager = Process.whereis(RoomManager)
      {:ok, game_pid} = PidroServer.Games.GameSupervisor.get_game(room.code)
      :sys.suspend(game_pid)

      try do
        action =
          Task.async(fn ->
            RoomManager.apply_player_action(
              room.code,
              positions[bidding.current_turn],
              bidding.current_turn,
              {:bid, 6}
            )
          end)

        eventually(fn ->
          {:messages, messages} = Process.info(game_pid, :messages)

          Enum.any?(messages, fn
            {:"$gen_call", {^manager, _}, :get_state} -> true
            _ -> false
          end)
        end)

        Process.exit(game_pid, :kill)
        assert {:error, :game_unavailable} = Task.await(action)
        assert Process.whereis(RoomManager) == manager
        assert {:ok, ^other_room} = RoomManager.get_room(other_room.code)
      after
        if Process.alive?(game_pid), do: :sys.resume(game_pid)
      end
    end

    test "cleaning the old room preserves a departed user's new membership and channels" do
      {old_room, _} = create_playing_room()
      assert :ok = RoomManager.leave_room("user2")
      assert {:ok, new_room} = RoomManager.create_room("user2", %{})
      assert :ok = RoomManager.register_game_channel(new_room.code, "user2", self())

      assert :ok = RoomManager.close_room(old_room.code)
      assert {:error, :already_in_room} = RoomManager.create_room("user2", %{})

      assert :last_channel_closed =
               RoomManager.unregister_game_channel(new_room.code, "user2", self())

      assert {:ok, room} = RoomManager.get_room(new_room.code)
      assert room.seats.north.user_id == "user2"
    end
  end

  describe "game progression after multiple departures" do
    setup do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          hiccup_timeout_ms: 20,
          grace_timeout_ms: 80,
          bot_delay_ms: 1,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 1,
          trick_transition_delay_ms: 1,
          hand_transition_delay_ms: 1,
          turn_timer_bid_ms: 60_000,
          turn_timer_play_ms: 60_000,
          empty_room_ttl_ms: 60_000
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
      :ok
    end

    for {mode, host_first?} <- [
          leave: true,
          leave: false,
          disconnect: true,
          mixed: true,
          mixed: false
        ] do
      test "three #{mode} departures (host first: #{host_first?}) reach the next hand" do
        {room, _positions} = create_playing_room()
        bidding = start_bidding(room.code)

        {human_position, human_id} =
          Enum.find(room.positions, fn {pos, user} ->
            pos != bidding.current_turn and user != room.host_id
          end)

        departing =
          room.positions
          |> Enum.reject(fn {pos, _} -> pos == human_position end)
          |> Enum.sort_by(fn {_, user} -> user == room.host_id != unquote(host_first?) end)

        for {position, user_id} <- departing do
          if unquote(mode) == :leave or
               (unquote(mode) == :mixed and position == bidding.current_turn) do
            assert :ok = RoomManager.leave_room(user_id)
          else
            assert :ok = RoomManager.handle_player_disconnect(room.code, user_id)
          end
        end

        # No owner decision is answered and no departed player's turn is driven.
        eventually(fn ->
          {:ok, game} = GameAdapter.get_state(room.code)

          if game.hand_number > bidding.hand_number do
            true
          else
            play_human_turn(room.code, human_id, human_position, game)
            false
          end
        end)

        continued =
          eventually(fn ->
            {:ok, current} = RoomManager.get_room(room.code)
            if current.host_id == human_id, do: current
          end)

        assert continued.status == :playing
        assert continued.host_id == human_id

        for {position, _} <- departing do
          assert Process.alive?(continued.seats[position].bot_pid)
        end
      end
    end

    test "a bot taking the current bid acts without an external update and retires the human timer" do
      {room, _} = create_playing_room()
      bidding = start_bidding(room.code)
      bidder = bidding.current_turn

      timer =
        eventually(fn ->
          {:ok, current} = RoomManager.get_room(room.code)
          current.turn_timer
        end)

      assert timer.actor_position == bidder

      assert :ok = RoomManager.leave_room(room.positions[bidder])

      eventually(fn ->
        {:ok, game} = GameAdapter.get_state(room.code)
        game.current_turn != bidder
      end)

      assert Process.read_timer(timer.ref) == false
      {:ok, continued} = RoomManager.get_room(room.code)
      assert continued.paused_turn_timer == nil
      assert continued.turn_timer == nil or continued.turn_timer.actor_position != bidder
    end

    test "all bots finish the game and persist every departed human's result" do
      user_ids = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
      {room, _} = create_playing_room(user_ids)
      for user_id <- user_ids, do: assert(:ok = RoomManager.leave_room(user_id))

      saved =
        eventually(
          fn -> Repo.get_by(PidroServer.Stats.GameStats, room_code: room.code) end,
          4_000
        )

      assert Enum.sort(saved.player_ids) == Enum.sort(user_ids)

      assert Enum.all?(saved.player_results, fn {_, result} ->
               result["participation"] == "abandoned"
             end)

      {:ok, finished} = RoomManager.get_room(room.code)
      assert finished.status == :finished
      assert length(PidroServer.Stats.list_abandonments_for_room(room.code)) == 4
    end
  end

  defp start_bidding(room_code) do
    {:ok, initial} = GameAdapter.get_state(room_code)

    if initial.phase == :dealer_selection,
      do: GameAdapter.apply_action(room_code, :north, :select_dealer)

    eventually(fn ->
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding} = game} -> game
        _ -> nil
      end
    end)
  end

  defp play_human_turn(room_code, user_id, position, %{current_turn: position} = game) do
    {:ok, actions} = GameAdapter.get_legal_actions(room_code, position)

    if actions != [] do
      {:ok, action, _} = PidroServer.Games.Bots.TimeoutStrategy.pick_action(actions, game)
      resolved = PidroServer.Games.Bots.BotBrain.resolve_action(action, game, position)
      assert {:ok, _} = RoomManager.apply_player_action(room_code, user_id, position, resolved)
    end
  end

  defp play_human_turn(_room_code, _user_id, _position, _game), do: :ok

  defp eventually(fun, attempts \\ 2_000)
  defp eventually(_fun, 0), do: flunk("game did not progress before the deadline")

  defp eventually(fun, attempts) do
    case fun.() do
      result when result in [nil, false] ->
        Process.sleep(5)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  describe "Phase 1 (Hiccup) — disconnect triggers reconnecting" do
    test "disconnect marks seat as :reconnecting with disconnected_at set" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[position]

      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at != nil
    end

    test "disconnect does not affect other seats" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)

      for {pos, seat} <- updated_room.seats, pos != position do
        assert seat.status == :connected,
               "Expected seat at #{pos} to remain :connected, got #{seat.status}"
      end
    end

    test "player_reconnecting event is broadcast on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      assert_receive {:player_reconnecting, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "reconnect during Phase 1 restores seat to :connected :human" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      # Verify seat is reconnecting
      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      assert disconnected_room.seats[position].status == :reconnecting

      # Reconnect
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)
      seat = reconnected_room.seats[position]

      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at == nil
    end

    test "reconnect during Phase 1 broadcasts player_reconnected event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      # Drain the disconnect broadcast
      assert_receive {:player_reconnecting, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reconnected, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "phase transition timer is scheduled on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      timer_ref = updated_room.phase_timers[position]

      assert timer_ref != nil
      # Timer should still be active (not yet fired)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 1 cancels the phase timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      timer_ref = disconnected_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      {:ok, reconnected_room} = RoomManager.get_room(room.code)
      # Timer should be cleared from phase_timers
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled (returns false if already cancelled)
      assert Process.cancel_timer(timer_ref) == false
    end

    test "a :waiting room disconnect holds the seat without the cascade" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      {:ok, waiting_room} = RoomManager.get_room(room.code)
      assert waiting_room.status == :waiting
      user2_position = position_for(waiting_room, "user2")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[user2_position]
      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert %DateTime{} = seat.disconnected_at
      assert updated_room.phase_timers == %{}

      assert_receive {:player_reconnecting, %{user_id: "user2", position: ^user2_position}}, 100

      # The hiccup timeout passes without Phase 2: no bot, the seat stays held.
      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 50)

      {:ok, later_room} = RoomManager.get_room(room.code)
      later_seat = later_room.seats[user2_position]
      assert later_seat.status == :reconnecting
      assert later_seat.bot_pid == nil
      assert later_room.phase_timers == %{}
      refute_received {:bot_substitute_active, _}
    end

    test "multiple simultaneous disconnects are independent" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both seats should be independently :reconnecting
      assert updated_room.seats[user2_position].status == :reconnecting
      assert updated_room.seats[user3_position].status == :reconnecting

      # Both should have independent phase timers
      assert updated_room.phase_timers[user2_position] != nil
      assert updated_room.phase_timers[user3_position] != nil

      assert updated_room.phase_timers[user2_position] !=
               updated_room.phase_timers[user3_position]

      # Should receive two independent PubSub events
      assert_receive {:player_reconnecting, %{user_id: "user2", position: ^user2_position}}, 200
      assert_receive {:player_reconnecting, %{user_id: "user3", position: ^user3_position}}, 200
    end

    test "reconnecting one player does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Reconnect user2 only
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # user2 should be back to :connected
      assert updated_room.seats[user2_position].status == :connected

      # user3 should still be :reconnecting with active timer
      assert updated_room.seats[user3_position].status == :reconnecting
      assert updated_room.phase_timers[user3_position] != nil

      # user2's timer should be cleaned up
      assert updated_room.phase_timers[user2_position] == nil
    end

    test "disconnecting host triggers cascade (host seat becomes :reconnecting)" do
      {room, _positions} = create_playing_room()
      host_position = position_for(room, "user1")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[host_position]

      assert seat.status == :reconnecting
      assert seat.is_owner == true
      assert seat.user_id == "user1"
    end
  end

  # Helper: disconnect a player and manually trigger Phase 2 by sending
  # the {:phase2_start, ...} message to RoomManager (bypasses 20s timer).
  # Returns the updated room after Phase 2 completes.
  defp trigger_phase2(room_code, user_id) do
    {_room, position} = disconnect_and_get_position(room_code, user_id)

    # Manually send the Phase 2 timer message
    send(GenServer.whereis(RoomManager), {:phase2_start, room_code, position})

    # Synchronize: get_room is a GenServer.call, ensuring handle_info processed
    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  defp disconnect_and_get_position(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)
    {room, position}
  end

  # Helper: trigger Phase 2 then Phase 3 for a player.
  defp trigger_phase3(room_code, user_id) do
    {_room, position} = trigger_phase2(room_code, user_id)

    # Manually send the Phase 3 timer message
    send(GenServer.whereis(RoomManager), {:phase3_gone, room_code, position})

    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  describe "Phase 2 (Grace) — bot spawned after hiccup timeout" do
    test "Phase 2 spawns a bot — seat becomes :bot_substitute with live bot_pid" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase2(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
      assert seat.reserved_for == user_id
      assert seat.grace_expires_at != nil
      assert seat.user_id == nil
    end

    test "Phase 2 broadcasts bot_substitute_active event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase2(room.code, user_id)

      # Drain the disconnect broadcast first
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, %{position: ^position, user_id: ^user_id}}, 200
    end

    test "Phase 2 schedules Phase 3 timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase2(room.code, "user2")

      timer_ref = updated_room.phase_timers[position]
      assert timer_ref != nil
      # Timer should still be active (Phase 3 hasn't fired yet)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 2 terminates bot and restores seat" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      # Capture bot pid before reconnect
      bot_pid = phase2_room.seats[position].bot_pid
      assert Process.alive?(bot_pid)

      # Reconnect during Phase 2
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      seat = reconnected_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.bot_pid == nil
      assert seat.reserved_for == nil
      assert seat.grace_expires_at == nil

      # Bot process should be dead
      Process.sleep(50)
      refute Process.alive?(bot_pid)
    end

    test "reconnect during Phase 2 cancels Phase 3 timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      timer_ref = phase2_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Timer should be cleared
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled
      assert Process.cancel_timer(timer_ref) == false
    end

    test "reconnect during Phase 2 broadcasts player_reclaimed_seat event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_phase2_room, position} = trigger_phase2(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reclaimed_seat, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "Phase 2 does nothing if player already reconnected (Phase 1)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, disc_room} = RoomManager.get_room(room.code)
      position = position_for(disc_room, user_id)

      # Reconnect during Phase 1
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 2 message (timer would have fired)
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 2 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end
  end

  describe "Phase 3 (Gone) — bot becomes permanent" do
    test "Phase 3 makes bot permanent — reserved_for is nil" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase3(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.reserved_for == nil
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
    end

    test "Phase 3 cleans up phase timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase3(room.code, "user2")

      assert updated_room.phase_timers[position] == nil
    end

    test "Phase 3 broadcasts seat_permanently_botted event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      assert_receive {:seat_permanently_botted, %{position: ^position}}, 200
    end

    test "reconnect during Phase 3 is rejected — seat permanently filled" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {_updated_room, _position} = trigger_phase3(room.code, user_id)

      result = RoomManager.handle_player_reconnect(room.code, user_id)
      assert result == {:error, :seat_permanently_filled}
    end

    test "Phase 3 does nothing if player already reclaimed (Phase 2)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {_phase2_room, position} = trigger_phase2(room.code, user_id)

      # Reconnect during Phase 2
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 3 message (timer would have fired)
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 3 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end

    test "Phase 3 notifies owner about decision when owner is a different connected human" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      assert_receive {:seat_permanently_botted, _}, 200

      # Owner (user1) should get notified since they're still connected
      assert_receive {:owner_decision_available, %{position: ^position, owner_id: "user1"}}, 200
    end
  end

  describe "Multiple disconnects and full lifecycle" do
    test "multiple simultaneous disconnects each have independent cascades through Phase 2" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user2_position})
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user3_position})
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both should have independent bots
      seat2 = updated_room.seats[user2_position]
      seat3 = updated_room.seats[user3_position]

      assert seat2.status == :bot_substitute
      assert seat3.status == :bot_substitute
      assert seat2.bot_pid != seat3.bot_pid
      assert seat2.reserved_for == "user2"
      assert seat3.reserved_for == "user3"
      assert Process.alive?(seat2.bot_pid)
      assert Process.alive?(seat3.bot_pid)
    end

    test "reclaiming one bot does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user2_position})
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, user3_position})
      {:ok, _} = RoomManager.get_room(room.code)

      # Reclaim user2's seat only
      {:ok, updated_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      # user2 should be back
      assert updated_room.seats[user2_position].status == :connected
      assert updated_room.seats[user2_position].user_id == "user2"

      # user3 should still have bot
      assert updated_room.seats[user3_position].status == :bot_substitute
      assert updated_room.seats[user3_position].reserved_for == "user3"
      assert Process.alive?(updated_room.seats[user3_position].bot_pid)
    end

    test "full lifecycle: disconnect → Phase 2 → Phase 3 → rejected reconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      # Phase 1: Disconnect
      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, room1} = RoomManager.get_room(room.code)
      assert room1.seats[position].status == :reconnecting

      # Phase 2: Bot spawns
      send(GenServer.whereis(RoomManager), {:phase2_start, room.code, position})
      {:ok, room2} = RoomManager.get_room(room.code)
      assert room2.seats[position].status == :bot_substitute
      assert room2.seats[position].reserved_for == user_id

      # Phase 3: Bot permanent
      send(GenServer.whereis(RoomManager), {:phase3_gone, room.code, position})
      {:ok, room3} = RoomManager.get_room(room.code)
      assert room3.seats[position].status == :bot_substitute
      assert room3.seats[position].reserved_for == nil

      # Reconnect rejected
      assert {:error, :seat_permanently_filled} =
               RoomManager.handle_player_reconnect(room.code, user_id)
    end
  end
end
