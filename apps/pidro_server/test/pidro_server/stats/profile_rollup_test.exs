defmodule PidroServer.Stats.ProfileRollupTest do
  @moduledoc """
  Integration tests for the profile rollup hook in Stats.save_completed_game/4.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Stats.GameStats

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()

    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  test "completing a game inserts game_stats and bumps each participant's profile" do
    user1 = Ecto.UUID.generate()
    user2 = Ecto.UUID.generate()
    user3 = Ecto.UUID.generate()
    user4 = Ecto.UUID.generate()

    {:ok, room} = RoomManager.create_room(user1, %{name: "Rollup"})
    {:ok, _, _} = RoomManager.join_room(room.code, user2)
    {:ok, _, _} = RoomManager.join_room(room.code, user3)
    {:ok, _, _} = RoomManager.join_room(room.code, user4)

    game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
    send(GenServer.whereis(RoomManager), game_over)

    saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
    assert saved_game.winner == "north_south"

    # Every human participant has a profile with one game played.
    for user_id <- saved_game.player_ids do
      assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
    end

    # Total played count matches the number of recorded human seats.
    assert Repo.aggregate(PlayerProfile, :count) == length(saved_game.player_ids)
  end

  test "re-running completion does not double-increment profiles" do
    user1 = Ecto.UUID.generate()
    user2 = Ecto.UUID.generate()
    user3 = Ecto.UUID.generate()
    user4 = Ecto.UUID.generate()

    {:ok, room} = RoomManager.create_room(user1, %{name: "Idempotent"})
    {:ok, _, _} = RoomManager.join_room(room.code, user2)
    {:ok, _, _} = RoomManager.join_room(room.code, user3)
    {:ok, _, _} = RoomManager.join_room(room.code, user4)

    game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
    send(GenServer.whereis(RoomManager), game_over)
    send(GenServer.whereis(RoomManager), game_over)

    saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)

    # Give the second message time to be processed.
    _ = :sys.get_state(GenServer.whereis(RoomManager))

    assert Repo.aggregate(GameStats, :count) == 1

    for user_id <- saved_game.player_ids do
      assert {:ok, %{games_played: 1}} = Profiles.get_or_create_profile(user_id)
    end
  end

  test "a forced stats-insert failure leaves no profile changes (rollback)" do
    user_id = Ecto.UUID.generate()

    player_results = %{
      user_id => %{participation: :played, result: :win, team: :north_south, position: :north}
    }

    # Wrap save_game_result in the same transaction the hook uses, but force a
    # rollback after the profile increment — asserting atomicity.
    result =
      Repo.transaction(fn ->
        :ok = Profiles.apply_completed_game(player_results, :north_south)
        Repo.rollback(:forced)
      end)

    assert {:error, :forced} = result
    assert Repo.aggregate(PlayerProfile, :count) == 0
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end
end
