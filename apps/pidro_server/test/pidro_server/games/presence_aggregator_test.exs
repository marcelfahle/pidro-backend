defmodule PidroServer.Games.PresenceAggregatorTest do
  use ExUnit.Case, async: false

  alias PidroServer.Games.PresenceAggregator

  setup do
    case GenServer.whereis(PresenceAggregator) do
      nil -> start_supervised!(PresenceAggregator)
      _pid -> :ok
    end

    PresenceAggregator.reset_for_test()
    :ok
  end

  describe "tracking" do
    test "tracks unique users across joins" do
      assert PresenceAggregator.get_count() == 0

      # Spawn processes that track different users
      spawn_and_track("user_1", :lobby)
      spawn_and_track("user_2", :playing)
      spawn_and_track("user_3", :spectating)

      assert PresenceAggregator.get_count() == 3
    end

    test "deduplicates same user in multiple channels" do
      # Same user tracked from two different processes (lobby + game)
      spawn_and_track("user_1", :lobby)
      spawn_and_track("user_1", :playing)

      assert PresenceAggregator.get_count() == 1
    end

    test "excludes bots from count" do
      spawn_and_track("bot_ABC1_north", :playing)
      spawn_and_track("bot_XYZ2_south", :playing)
      spawn_and_track("user_1", :lobby)

      assert PresenceAggregator.get_count() == 1
    end

    test "cleans up when process exits" do
      pid = spawn_and_track("user_1", :lobby)

      assert PresenceAggregator.get_count() == 1

      Process.exit(pid, :kill)
      # Wait for DOWN message to be processed
      Process.sleep(50)

      assert PresenceAggregator.get_count() == 0
    end

    test "partial cleanup when user has multiple connections" do
      pid1 = spawn_and_track("user_1", :lobby)
      _pid2 = spawn_and_track("user_1", :playing)

      assert PresenceAggregator.get_count() == 1

      # Kill one connection — user still online via the other
      Process.exit(pid1, :kill)
      Process.sleep(50)

      assert PresenceAggregator.get_count() == 1
    end
  end

  describe "breakdown" do
    test "returns correct breakdown by activity" do
      spawn_and_track("user_1", :lobby)
      spawn_and_track("user_2", :playing)
      spawn_and_track("user_3", :spectating)
      spawn_and_track("user_4", :playing)

      breakdown = PresenceAggregator.get_breakdown()
      assert breakdown == %{lobby: 1, playing: 2, spectating: 1}
    end

    test "user in multiple channels uses priority: playing > spectating > lobby" do
      spawn_and_track("user_1", :lobby)
      spawn_and_track("user_1", :playing)

      breakdown = PresenceAggregator.get_breakdown()
      assert breakdown == %{lobby: 0, playing: 1, spectating: 0}
    end

    test "empty state returns zeroes" do
      breakdown = PresenceAggregator.get_breakdown()
      assert breakdown == %{lobby: 0, playing: 0, spectating: 0}
    end
  end

  describe "broadcasts" do
    test "broadcasts count updates on lobby:updates topic" do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      spawn_and_track("user_1", :lobby)

      # Wait for debounce timer to fire
      assert_receive {:online_count_updated, %{count: 1, breakdown: %{lobby: 1}}}, 500
    end

    test "does not broadcast when count hasn't changed" do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      spawn_and_track("user_1", :lobby)

      assert_receive {:online_count_updated, %{count: 1}}, 500

      # Track same user from another process — count stays 1
      spawn_and_track("user_1", :playing)

      # Force a broadcast timer to fire
      Process.sleep(100)

      # Should not receive another broadcast since count is still 1
      refute_receive {:online_count_updated, _}, 200
    end
  end

  # Spawns a long-lived process that tracks the user
  defp spawn_and_track(user_id, activity) do
    test_pid = self()

    pid =
      spawn(fn ->
        PresenceAggregator.track(user_id, activity)
        send(test_pid, :tracked)
        # Stay alive until killed
        Process.sleep(:infinity)
      end)

    receive do
      :tracked -> :ok
    after
      1000 -> raise "track timeout"
    end

    # Give the GenServer time to process the cast
    Process.sleep(10)

    pid
  end
end
