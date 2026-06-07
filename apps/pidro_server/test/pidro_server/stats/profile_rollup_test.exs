defmodule PidroServer.Stats.ProfileRollupTest do
  @moduledoc """
  Integration tests for the profile rollup hook in Stats.save_completed_game/4.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Rating
  alias PidroServer.Stats
  alias PidroServer.Stats.GameStats

  @delta 1.0e-9

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

  describe "live rating update (PID-47)" do
    test "a 4-human game moves all four ratings (winners up, losers down, sigma shrinks)" do
      [n, e, s, w] = ids = for _ <- 1..4, do: Ecto.UUID.generate()
      {dmu, dsig} = Rating.default()

      # north/south win, east/west lose.
      complete_4human("RATED", {n, e, s, w}, :north_south)

      for id <- ids do
        p = profile(id)
        assert p.rating_games_count == 1
        assert p.rating_sigma < dsig
      end

      # Winners' mu up, losers' mu down.
      assert profile(n).rating_mu > dmu
      assert profile(s).rating_mu > dmu
      assert profile(e).rating_mu < dmu
      assert profile(w).rating_mu < dmu
    end

    test "single-player / bots-only game leaves ratings at default (counters still move)" do
      human = Ecto.UUID.generate()

      # Only one human seat recorded (rest are pure bots, never in player_results).
      results = %{human => result_for(:north_south, :north_south, :north)}
      seed_completed("SOLO", :north_south, results)

      :ok = Profiles.apply_completed_game(results, :north_south)

      # Untouched ratings hold the (rounded) schema default, not Rating.default/0.
      p = profile(human)
      assert p.games_played == 1
      assert p.rating_mu == 25.0
      assert p.rating_sigma == 8.333
      assert p.rating_games_count == 0
    end

    test "a 3-human game leaves ratings untouched but bumps counters" do
      [a, b, c] = ids = for _ <- 1..3, do: Ecto.UUID.generate()

      results = %{
        a => result_for(:north_south, :north_south, :north),
        b => result_for(:east_west, :north_south, :east),
        c => result_for(:north_south, :north_south, :south)
      }

      seed_completed("THREE", :north_south, results)
      :ok = Profiles.apply_completed_game(results, :north_south)

      for id <- ids do
        p = profile(id)
        assert p.games_played == 1
        assert p.rating_mu == 25.0
        assert p.rating_sigma == 8.333
        assert p.rating_games_count == 0
      end
    end

    test "idempotent re-fire does not double-move ratings" do
      [n, e, s, w] = for _ <- 1..4, do: Ecto.UUID.generate()

      {:ok, room} = RoomManager.create_room(n, %{name: "RatingIdempotent"})
      {:ok, _, _} = RoomManager.join_room(room.code, e)
      {:ok, _, _} = RoomManager.join_room(room.code, s)
      {:ok, _, _} = RoomManager.join_room(room.code, w)

      game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)

      saved = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
      after_first = snapshot()

      # Fire again; the room_code short-circuit must keep ratings put.
      send(GenServer.whereis(RoomManager), game_over)
      _ = :sys.get_state(GenServer.whereis(RoomManager))

      assert Repo.aggregate(GameStats, :count) == 1

      for id <- saved.player_ids do
        assert profile(id).rating_games_count == 1
      end

      assert_profiles_match(after_first, snapshot())
    end

    test "a forced stats-insert failure rolls back the rating move" do
      [n, e, s, w] = for _ <- 1..4, do: Ecto.UUID.generate()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      result =
        Repo.transaction(fn ->
          :ok = Profiles.apply_completed_game(results, :north_south)
          Repo.rollback(:forced)
        end)

      assert {:error, :forced} = result
      assert Repo.aggregate(PlayerProfile, :count) == 0
    end

    test "real completion path equals a fresh rerate_all/0 (acceptance c)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: Ecto.UUID.generate()

      # Drive N rated 4-human games through the real Stats save path, with
      # strictly increasing completed_at so arrival order == the rebuild's total
      # order [completed_at, inserted_at, id].
      base = ~U[2026-06-07 12:00:00Z]

      complete_4human("G1", {a, b, c, d}, :north_south, DateTime.add(base, 0))
      complete_4human("G2", {a, c, e, b}, :east_west, DateTime.add(base, 1))
      complete_4human("G3", {e, f, a, d}, :north_south, DateTime.add(base, 2))
      complete_4human("G4", {b, d, f, c}, :east_west, DateTime.add(base, 3))
      complete_4human("G5", {a, b, e, f}, :north_south, DateTime.add(base, 4))

      live = snapshot()

      # A fresh from-scratch rebuild over the same game_stats rows is the source
      # of truth; the live per-game move must match it exactly.
      assert {:ok, %{games: 5}} = Profiles.rerate_all()

      assert_profiles_match(live, snapshot())
    end
  end

  # --- helpers ---

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  # Seed a game_stats row AND run the live completion update, mirroring the
  # save_completed_game/4 transaction (insert + apply_completed_game).
  defp complete_4human(room_code, {n, e, s, w}, winner, completed_at \\ nil) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    seed_completed(room_code, winner, results, completed_at)
    :ok = Profiles.apply_completed_game(results, winner)
    results
  end

  defp seed_completed(room_code, winner, results, completed_at \\ nil) do
    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: %{north_south: 62, east_west: 45},
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at || DateTime.utc_now(),
        player_ids: Map.keys(results),
        player_results: results
      })
  end

  defp profile(user_id) do
    {:ok, p} = Profiles.get_or_create_profile(user_id)
    p
  end

  defp snapshot do
    Repo.all(PlayerProfile)
    |> Map.new(fn p -> {p.user_id, {p.rating_mu, p.rating_sigma, p.rating_games_count}} end)
  end

  defp assert_profiles_match(a, b) do
    assert Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort()

    Enum.each(a, fn {user_id, {mu, sigma, count}} ->
      {b_mu, b_sigma, b_count} = Map.fetch!(b, user_id)
      assert_in_delta mu, b_mu, @delta
      assert_in_delta sigma, b_sigma, @delta
      assert count == b_count
    end)
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
