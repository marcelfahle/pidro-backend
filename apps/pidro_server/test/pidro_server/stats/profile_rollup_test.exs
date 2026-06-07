defmodule PidroServer.Stats.ProfileRollupTest do
  @moduledoc """
  Integration tests for the profile rollup hook in Stats.save_completed_game/4.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Progression
  alias PidroServer.Rating
  alias PidroServer.Stats
  alias PidroServer.Stats.GameStats

  @delta 1.0e-9
  @base ~U[2026-06-07 12:00:00Z]

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
        {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)
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

      {:ok, _} = Profiles.apply_completed_game(results, :north_south)

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
      {:ok, _} = Profiles.apply_completed_game(results, :north_south)

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
          {:ok, _} = Profiles.apply_completed_game(results, :north_south)
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

  describe "veteran XP (PID-49)" do
    test "awards XP to ALL participants of a 4-human game, incl. losers" do
      [n, e, s, w] = for _ <- 1..4, do: Ecto.UUID.generate()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      scores = %{north_south: 62, east_west: 45}
      seed_completed("XP4", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      # Winners: 62 + 50 = 112; losers: 45 (no bonus).
      for id <- [n, s] do
        p = profile(id)
        assert p.veteran_xp == 112
        assert p.veteran_level == Progression.level_for_xp(112)
      end

      for id <- [e, w] do
        p = profile(id)
        assert p.veteran_xp == 45
        assert p.veteran_level == Progression.level_for_xp(45)
      end
    end

    test "single-player / bot-filled game still pays XP (NOT rated-gated)" do
      human = Ecto.UUID.generate()
      results = %{human => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 45}

      seed_completed("XPSOLO", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      p = profile(human)
      # XP accrues (dedication) while the skill rating stays untouched.
      assert p.veteran_xp == 112
      assert p.veteran_level == Progression.level_for_xp(112)
      assert p.games_played == 1
      assert p.rating_games_count == 0
    end

    test "an :abandoned seat earns XP like the counters credit it" do
      user_id = Ecto.UUID.generate()

      results = %{
        user_id => %{
          participation: :abandoned,
          result: :win,
          team: :north_south,
          position: :north
        }
      }

      scores = %{north_south: 62, east_west: 45}
      seed_completed("XPABANDON", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      p = profile(user_id)
      assert p.veteran_xp == 112
    end

    test "live completion XP/level == rebuild_all/0 XP/level (parity)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: Ecto.UUID.generate()

      complete_4human_xp("PG1", {a, b, c, d}, :north_south, %{north_south: 62, east_west: 30})
      complete_4human_xp("PG2", {a, c, e, b}, :east_west, %{north_south: 40, east_west: 62})
      complete_4human_xp("PG3", {e, f, a, d}, :north_south, %{north_south: 62, east_west: 51})
      complete_4human_xp("PG4", {b, d, f, c}, :east_west, %{north_south: 22, east_west: 62})

      live = xp_snapshot()

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = xp_snapshot()
      assert Map.keys(live) |> Enum.sort() == Map.keys(rebuilt) |> Enum.sort()

      Enum.each(live, fn {user_id, {xp, level}} ->
        assert {xp, level} == Map.fetch!(rebuilt, user_id)
      end)
    end

    test "rebuild tolerates legacy string-keyed final_scores and missing team score" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      results = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      # Persist with a final_scores map missing the east_west key (legacy floor 0).
      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "XPLEGACY",
          winner: :north_south,
          final_scores: %{north_south: 62},
          duration_seconds: 100,
          completed_at: DateTime.utc_now(),
          player_ids: [u1, u2],
          player_results: results
        })

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      # Winner: 62 + 50; loser: missing score floors to 0.
      assert reb_u1.veteran_xp == 112
      assert reb_u2.veteran_xp == 0
    end
  end

  describe "achievements (PID-50)" do
    alias PidroServer.Profiles.Achievement

    test "10th game awards :player exactly at the threshold, not before" do
      u = Ecto.UUID.generate()

      for n <- 1..9 do
        complete_solo("PLAYER#{n}", u, :north_south, DateTime.add(@base, n))
      end

      refute "player" in earned_keys(u)

      complete_solo("PLAYER10", u, :north_south, DateTime.add(@base, 10))
      assert "player" in earned_keys(u)
    end

    test "5th win awards :winner exactly at the threshold" do
      u = Ecto.UUID.generate()

      # 4 wins, then a loss, then the 5th win.
      for n <- 1..4 do
        complete_solo("WIN#{n}", u, :north_south, DateTime.add(@base, n))
      end

      refute "winner" in earned_keys(u)
      # A loss does not count toward wins.
      complete_solo("WINLOSS", u, :east_west, DateTime.add(@base, 5))
      refute "winner" in earned_keys(u)

      complete_solo("WIN5", u, :north_south, DateTime.add(@base, 6))
      assert "winner" in earned_keys(u)
    end

    test "3 straight wins award :winstreak; a prior loss does not block it" do
      u = Ecto.UUID.generate()

      complete_solo("WS_L", u, :east_west, DateTime.add(@base, 1))
      complete_solo("WS_W1", u, :north_south, DateTime.add(@base, 2))
      complete_solo("WS_W2", u, :north_south, DateTime.add(@base, 3))
      refute "winstreak" in earned_keys(u)

      complete_solo("WS_W3", u, :north_south, DateTime.add(@base, 4))
      assert "winstreak" in earned_keys(u)
    end

    test "an opponent-shutout win awards :ace" do
      u = Ecto.UUID.generate()

      complete_solo("ACE_NO", u, :north_south, DateTime.add(@base, 1), %{
        north_south: 62,
        east_west: 10
      })

      refute "ace" in earned_keys(u)

      complete_solo("ACE_YES", u, :north_south, DateTime.add(@base, 2), %{
        north_south: 62,
        east_west: -3
      })

      assert "ace" in earned_keys(u)
    end

    test "a negative-finish game awards :the_loser" do
      u = Ecto.UUID.generate()

      # User sits on north_south, loses (east_west wins), and finishes negative.
      complete_solo("LOSER", u, :east_west, DateTime.add(@base, 1), %{
        north_south: -8,
        east_west: 62
      })

      assert "the_loser" in earned_keys(u)
    end

    test ":partnership needs a full 4-human 2v2 win, not a bot-filled game" do
      solo = Ecto.UUID.generate()

      # A solo (1-human) win is not a partnered win.
      complete_solo("PART_SOLO", solo, :north_south, DateTime.add(@base, 1))
      refute "partnership" in earned_keys(solo)

      [n, e, s, w] = for _ <- 1..4, do: Ecto.UUID.generate()
      complete_4human("PART_FULL", {n, e, s, w}, :north_south, DateTime.add(@base, 2))

      # Winners earn partnership; losers do not.
      assert "partnership" in earned_keys(n)
      assert "partnership" in earned_keys(s)
      refute "partnership" in earned_keys(e)
      refute "partnership" in earned_keys(w)
    end

    test "awards are permanent + idempotent (no dup rows, no downgrade on rebuild)" do
      u = Ecto.UUID.generate()

      complete_solo("PERM_W1", u, :north_south, DateTime.add(@base, 1))
      complete_solo("PERM_W2", u, :north_south, DateTime.add(@base, 2))
      complete_solo("PERM_W3", u, :north_south, DateTime.add(@base, 3))
      assert "winstreak" in earned_keys(u)

      # Break the streak with later losses — the earned row must survive.
      complete_solo("PERM_L1", u, :east_west, DateTime.add(@base, 4))
      complete_solo("PERM_L2", u, :east_west, DateTime.add(@base, 5))
      assert "winstreak" in earned_keys(u)

      # A full rebuild recomputes a now-broken streak but never removes the row.
      assert {:ok, _} = Profiles.rebuild_all()
      assert "winstreak" in earned_keys(u)

      # No duplicate rows for the key.
      count =
        Repo.aggregate(
          from(a in Achievement, where: a.user_id == ^u and a.achievement_key == "winstreak"),
          :count
        )

      assert count == 1
    end

    test "apply_completed_game returns per-user newly-earned keys; not re-reported next game" do
      u = Ecto.UUID.generate()

      for n <- 1..9 do
        complete_solo("RET#{n}", u, :north_south, DateTime.add(@base, n))
      end

      # The 10th completion crosses :player; capture its return value directly.
      results = %{u => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 30}
      seed_completed("RET10", :north_south, results, DateTime.add(@base, 10))
      assert {:ok, newly} = Profiles.apply_completed_game(results, :north_south, scores)
      assert :player in Map.fetch!(newly, u)

      # A subsequent game does NOT re-report :player (idempotent).
      results2 = %{u => result_for(:north_south, :north_south, :north)}
      seed_completed("RET11", :north_south, results2, DateTime.add(@base, 11))
      assert {:ok, newly2} = Profiles.apply_completed_game(results2, :north_south, scores)
      refute :player in Map.get(newly2, u, [])
    end

    test "live award set == rebuild award set (headline parity guard)" do
      [a, b, c, d] = for _ <- 1..4, do: Ecto.UUID.generate()

      # A scripted sequence exercising counters, streaks, shutouts, partnered wins.
      complete_4human("P1", {a, b, c, d}, :north_south, DateTime.add(@base, 1), %{
        north_south: 62,
        east_west: -5
      })

      complete_4human("P2", {a, b, c, d}, :north_south, DateTime.add(@base, 2))
      complete_4human("P3", {a, b, c, d}, :north_south, DateTime.add(@base, 3))
      complete_4human("P4", {a, b, c, d}, :east_west, DateTime.add(@base, 4))

      live = earned_snapshot([a, b, c, d])

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = earned_snapshot([a, b, c, d])
      assert live == rebuilt
    end

    test "rebuild is idempotent (running it twice awards nothing the second time)" do
      u = Ecto.UUID.generate()
      complete_solo("IDEM1", u, :north_south, DateTime.add(@base, 1))
      complete_solo("IDEM2", u, :north_south, DateTime.add(@base, 2))
      complete_solo("IDEM3", u, :north_south, DateTime.add(@base, 3))

      assert {:ok, _} = Profiles.rebuild_all()
      first = earned_keys(u)
      assert {:ok, _} = Profiles.rebuild_all()
      assert earned_keys(u) == first

      assert Repo.aggregate(from(a in Achievement, where: a.user_id == ^u), :count) ==
               length(first)
    end

    test "dormant achievements never appear after completions or a rebuild" do
      [a, b, c, d] = for _ <- 1..4, do: Ecto.UUID.generate()
      complete_4human("DORM", {a, b, c, d}, :north_south, DateTime.add(@base, 1))
      assert {:ok, _} = Profiles.rebuild_all()

      dormant = ~w(homerun forcer full_house unstoppable)
      all_earned = Repo.all(Achievement) |> Enum.map(& &1.achievement_key)
      refute Enum.any?(dormant, &(&1 in all_earned))
    end

    test "adding a def is trivial: a synthetic active def is picked up by both paths" do
      # Inject a config override so :player's threshold is 1 — i.e. exactly the
      # kind of data-only change "adding/tuning a def" represents — and assert
      # BOTH the live path and rebuild pick it up with no other code change.
      Application.put_env(:pidro_server, PidroServer.Achievements.Catalog,
        thresholds: %{player: 1}
      )

      on_exit(fn -> Application.delete_env(:pidro_server, PidroServer.Achievements.Catalog) end)

      u = Ecto.UUID.generate()
      complete_solo("TRIV", u, :north_south, DateTime.add(@base, 1))
      assert "player" in earned_keys(u)

      assert {:ok, _} = Profiles.rebuild_all()
      assert "player" in earned_keys(u)
    end
  end

  # --- helpers ---

  # Seed + apply a single-human game (the rest of the table is bots / absent),
  # with controllable winner, completed_at, and scores.
  # The user always sits on north_south; pass winner: :north_south for a win,
  # :east_west for a loss.
  defp complete_solo(room_code, user_id, winner, completed_at, scores \\ nil) do
    results = %{user_id => result_for(:north_south, winner, :north)}
    scores = scores || %{north_south: 62, east_west: 45}

    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores,
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at,
        player_ids: Map.keys(results),
        player_results: results
      })

    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp earned_keys(user_id) do
    user_id |> Profiles.list_achievements() |> Enum.map(& &1.achievement_key) |> Enum.sort()
  end

  defp earned_snapshot(user_ids) do
    Map.new(user_ids, fn id -> {id, earned_keys(id)} end)
  end

  defp complete_4human_xp(room_code, {n, e, s, w}, winner, scores) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores,
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: DateTime.utc_now(),
        player_ids: Map.keys(results),
        player_results: results
      })

    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp xp_snapshot do
    Repo.all(PlayerProfile)
    |> Map.new(fn p -> {p.user_id, {p.veteran_xp, p.veteran_level}} end)
  end

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  # Seed a game_stats row AND run the live completion update, mirroring the
  # save_completed_game/4 transaction (insert + apply_completed_game). The same
  # `scores` are persisted AND passed live, so the live and rebuild paths agree
  # on score-derived achievements (ace / the_loser).
  defp complete_4human(room_code, {n, e, s, w}, winner, completed_at \\ nil, scores \\ nil) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    scores = scores || %{north_south: 62, east_west: 45}
    seed_completed(room_code, winner, results, completed_at, scores)
    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp seed_completed(room_code, winner, results, completed_at \\ nil, scores \\ nil) do
    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores || %{north_south: 62, east_west: 45},
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
