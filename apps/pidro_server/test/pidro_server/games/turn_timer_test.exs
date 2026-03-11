defmodule PidroServer.Games.TurnTimerTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.TurnTimer

  describe "start_timer/8" do
    test "schedules expiry after the action duration plus transition delay" do
      key = {:seat, :north, :bidding, 7}

      timer =
        TurnTimer.start_timer(self(), "ROOM", key, :seat, :north, :bidding, 40, 20)

      assert timer.scope == :seat
      assert timer.actor_position == :north
      assert timer.phase == :bidding
      assert timer.duration_ms == 40
      assert timer.transition_delay_ms == 20

      refute_receive {:turn_timer_expired, "ROOM", _, ^key}, 40
      assert_receive {:turn_timer_expired, "ROOM", timer_id, ^key}, 80
      assert timer_id == timer.timer_id
    end
  end

  describe "cancel_timer/1" do
    test "cancels a running timer" do
      key = {:seat, :east, :playing, 3}
      timer = TurnTimer.start_timer(self(), "ROOM", key, :seat, :east, :playing, 50, 0)

      assert :ok = TurnTimer.cancel_timer(timer)
      refute_receive {:turn_timer_expired, "ROOM", _, ^key}, 80
    end
  end

  describe "pause_timer/1" do
    test "returns paused timer metadata and cancels expiry" do
      key = {:seat, :south, :playing, 12}
      timer = TurnTimer.start_timer(self(), "ROOM", key, :seat, :south, :playing, 80, 0)

      Process.sleep(20)
      paused = TurnTimer.pause_timer(timer)

      assert paused.key == key
      assert paused.actor_position == :south
      assert paused.phase == :playing
      assert paused.remaining_ms > 0
      assert paused.remaining_ms <= 80

      refute_receive {:turn_timer_expired, "ROOM", _, ^key}, 100
    end
  end

  describe "remaining_ms/1 and event_seq/1" do
    test "exposes remaining time and event sequence for seat timers" do
      key = {:seat, :west, :playing, 19}
      timer = TurnTimer.start_timer(self(), "ROOM", key, :seat, :west, :playing, 60, 0)

      assert TurnTimer.remaining_ms(timer) <= 60
      assert TurnTimer.remaining_ms(timer) >= 0
      assert TurnTimer.event_seq(timer.key) == 19

      TurnTimer.cancel_timer(timer)
    end

    test "extracts event sequence for room timers" do
      assert TurnTimer.event_seq({:room, :dealer_selection, 4}) == 4
    end
  end
end
