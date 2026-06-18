defmodule PidroServer.RerateTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Profiles.RatingState
  alias PidroServer.Rating
  alias PidroServer.Stats

  @delta 1.0e-9

  # Builds a 4-seat 2v2 player_results map (north_south = [n, s], east_west =
  # [e, w]) and seeds a real game_stats row via the Stats save path so
  # player_results round-trips to string-keyed JSONB.
  defp complete_game(room_code, {n, e, s, w}, winner, completed_at) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    seed_game(room_code, winner, [n, e, s, w], results, completed_at)
    results
  end

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  defp seed_game(room_code, winner, player_ids, results, completed_at) do
    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: %{north_south: 62, east_west: 45},
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at,
        player_ids: player_ids,
        player_results: results
      })
  end

  defp profile(user_id) do
    {:ok, p} = Profiles.get_or_create_profile(user_id)
    p
  end

  defp snapshot do
    PidroServer.Repo.all(PlayerProfile)
    |> Map.new(fn p ->
      {p.user_id, {p.rating_mu, p.rating_sigma, p.rating_games_count}}
    end)
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

  # "Live" simulation: apply the shared step read-modify-write against the
  # accumulator in completion order, seeding each user lazily at default.
  defp live_fold(games) do
    Enum.reduce(games, {%{}, %{}}, fn {results, winner}, {acc, counts} ->
      case Profiles.rate_game(results, winner, acc) do
        {:rated, updated} ->
          ids = Map.keys(results)
          counts = Enum.reduce(ids, counts, &Map.update(&2, &1, 1, fn c -> c + 1 end))
          {updated, counts}

        :unrated ->
          {acc, counts}
      end
    end)
  end

  describe "rate_game/3 (pure)" do
    test "4-human 2v2 game rates: winners' mu up, losers' mu down, sigmas shrink" do
      {n, e, s, w} = teams = {uuid(), uuid(), uuid(), uuid()}
      results = team_results(teams, :north_south)
      {dmu, dsig} = Rating.default()

      assert {:rated, updated} = Profiles.rate_game(results, :north_south, %{})

      assert {wmu, wsig} = Map.fetch!(updated, n)
      assert {lmu, lsig} = Map.fetch!(updated, e)
      assert wmu > dmu
      assert lmu < dmu
      assert wsig < dsig
      assert lsig < dsig
      # south is a winner, west is a loser
      assert Map.fetch!(updated, s) == {wmu, wsig}
      assert Map.fetch!(updated, w) == {lmu, lsig}
    end

    test "non-participant priors are left untouched" do
      teams = {uuid(), uuid(), uuid(), uuid()}
      bystander = uuid()
      results = team_results(teams, :north_south)
      priors = %{bystander => {30.0, 4.0}}

      assert {:rated, updated} = Profiles.rate_game(results, :north_south, priors)
      assert Map.fetch!(updated, bystander) == {30.0, 4.0}
    end

    test "missing prior defaults to Rating.default/0" do
      {n, _e, _s, _w} = teams = {uuid(), uuid(), uuid(), uuid()}
      results = team_results(teams, :north_south)

      assert {:rated, from_empty} = Profiles.rate_game(results, :north_south, %{})

      {dmu, dsig} = Rating.default()
      seeded = Map.new(Tuple.to_list(teams), &{&1, {dmu, dsig}})
      assert {:rated, from_seeded} = Profiles.rate_game(results, :north_south, seeded)

      {a_mu, a_sig} = Map.fetch!(from_empty, n)
      {b_mu, b_sig} = Map.fetch!(from_seeded, n)
      assert_in_delta a_mu, b_mu, @delta
      assert_in_delta a_sig, b_sig, @delta
    end

    test "tolerates string-keyed JSONB results and atom-keyed in-memory results" do
      teams = {uuid(), uuid(), uuid(), uuid()}
      atom_keyed = team_results(teams, :north_south)

      string_keyed =
        Map.new(atom_keyed, fn {id, r} ->
          {id, %{"team" => Atom.to_string(r.team), "result" => Atom.to_string(r.result)}}
        end)

      assert {:rated, from_atoms} = Profiles.rate_game(atom_keyed, :north_south, %{})
      assert {:rated, from_strings} = Profiles.rate_game(string_keyed, "north_south", %{})

      assert_profiles_close(from_atoms, from_strings)
    end

    test "string vs atom winner select the same winning team" do
      teams = {n, _e, _s, _w} = {uuid(), uuid(), uuid(), uuid()}
      results = team_results(teams, :north_south)

      assert {:rated, from_atom} = Profiles.rate_game(results, :north_south, %{})
      assert {:rated, from_string} = Profiles.rate_game(results, "north_south", %{})

      {a_mu, _} = Map.fetch!(from_atom, n)
      {b_mu, _} = Map.fetch!(from_string, n)
      assert_in_delta a_mu, b_mu, @delta
    end

    test "unrated: 3 human + 1 bot (only 3 keys)" do
      {n, e, s, _w} = {uuid(), uuid(), uuid(), uuid()}

      results = %{
        n => %{team: :north_south, result: :win},
        e => %{team: :east_west, result: :loss},
        s => %{team: :north_south, result: :win}
      }

      assert :unrated = Profiles.rate_game(results, :north_south, %{})
    end

    test "unrated: a non-UUID key is dropped, leaving 3 valid keys" do
      {n, e, s} = {uuid(), uuid(), uuid()}

      results = %{
        n => %{team: :north_south, result: :win},
        e => %{team: :east_west, result: :loss},
        s => %{team: :north_south, result: :win},
        "dev_host" => %{team: :east_west, result: :loss}
      }

      assert :unrated = Profiles.rate_game(results, :north_south, %{})
    end

    test "unrated: nil player_results" do
      assert :unrated = Profiles.rate_game(nil, :north_south, %{})
    end

    test "unrated: 4 humans all on one team" do
      teams = {uuid(), uuid(), uuid(), uuid()}

      results =
        Map.new(Tuple.to_list(teams), fn id ->
          {id, %{team: :north_south, result: :win}}
        end)

      assert :unrated = Profiles.rate_game(results, :north_south, %{})
    end

    test "deterministic: same inputs twice yield identical output" do
      teams = {uuid(), uuid(), uuid(), uuid()}
      results = team_results(teams, :north_south)

      assert Profiles.rate_game(results, :north_south, %{}) ==
               Profiles.rate_game(results, :north_south, %{})
    end
  end

  describe "rerate_all/0 (parity)" do
    test "from-scratch replay equals sequential live application (acceptance c)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: uuid()
      base = ~U[2026-06-07 12:00:00Z]

      games = [
        {complete_game("R1", {a, b, c, d}, :north_south, at(base, 0)), :north_south},
        {complete_game("R2", {a, c, e, b}, :east_west, at(base, 1)), :east_west},
        {complete_game("R3", {e, f, a, d}, :north_south, at(base, 2)), :north_south},
        {complete_game("R4", {b, d, f, c}, :east_west, at(base, 3)), :east_west},
        {complete_game("R5", {a, b, e, f}, :north_south, at(base, 4)), :north_south},
        {complete_game("R6", {c, d, a, e}, :east_west, at(base, 5)), :east_west}
      ]

      {live_acc, live_counts} = live_fold(games)

      live =
        Map.new(live_acc, fn {id, {mu, sigma}} ->
          {id, {mu, sigma, Map.fetch!(live_counts, id)}}
        end)

      assert {:ok, %{profiles: profiles, games: rated}} = Profiles.rerate_all()
      assert profiles == 6
      assert rated == 6

      assert_profiles_match(live, snapshot())
    end

    test "is idempotent (two full runs yield identical results)" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      base = ~U[2026-06-07 12:00:00Z]
      complete_game("R1", {a, b, c, d}, :north_south, at(base, 0))
      complete_game("R2", {a, c, b, d}, :east_west, at(base, 1))

      assert {:ok, _} = Profiles.rerate_all()
      first = snapshot()
      assert {:ok, _} = Profiles.rerate_all()
      second = snapshot()

      assert_profiles_match(first, second)
    end

    test "overwrites drifted ratings; zero-rated-game user reset to default" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      lonely = uuid()
      complete_game("R1", {a, b, c, d}, :north_south, ~U[2026-06-07 12:00:00Z])

      # Pre-corrupt a participant and create a user with no rated games.
      profile(a)
      |> PlayerProfile.changeset(%{rating_mu: 999.0, rating_games_count: 77})
      |> Repo.update!()

      profile(lonely)
      |> PlayerProfile.changeset(%{rating_mu: 1.0, rating_sigma: 0.5, rating_games_count: 9})
      |> Repo.update!()

      assert {:ok, _} = Profiles.rerate_all()

      {dmu, dsig} = Rating.default()
      reloaded_a = profile(a)
      assert reloaded_a.rating_mu != 999.0
      assert reloaded_a.rating_games_count == 1

      reloaded_lonely = profile(lonely)
      assert_in_delta reloaded_lonely.rating_mu, dmu, @delta
      assert_in_delta reloaded_lonely.rating_sigma, dsig, @delta
      assert reloaded_lonely.rating_games_count == 0
    end

    test "deterministic ordering under same-second completed_at ties" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      tie = ~U[2026-06-07 12:00:00Z]
      # Three games share the same completed_at (distinct inserted_at/id by
      # insertion order).
      complete_game("R1", {a, b, c, d}, :north_south, tie)
      complete_game("R2", {a, c, b, d}, :east_west, tie)
      complete_game("R3", {b, d, a, c}, :north_south, tie)

      assert {:ok, _} = Profiles.rerate_all()
      first = snapshot()
      assert {:ok, _} = Profiles.rerate_all()
      second = snapshot()

      assert_profiles_match(first, second)
    end

    test "unrated games leave ratings and counts untouched" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      bot_only = uuid()
      base = ~U[2026-06-07 12:00:00Z]

      # One rated 4-human game.
      complete_game("RATED", {a, b, c, d}, :north_south, at(base, 0))

      # One unrated 3-human game (bot_only + 2 others, only 3 keys).
      unrated = %{
        bot_only => result_for(:north_south, :north_south, :north),
        a => result_for(:east_west, :north_south, :east),
        b => result_for(:north_south, :north_south, :south)
      }

      seed_game("UNRATED", :north_south, [bot_only, a, b], unrated, at(base, 1))

      assert {:ok, %{games: rated}} = Profiles.rerate_all()
      assert rated == 1

      # bot_only appears only in the unrated game, so the rating job never
      # touches it: no profile row is created/written by the replay.
      refute Repo.exists?(from p in PlayerProfile, where: p.user_id == ^bot_only)

      # Lazily created now, it holds the untouched schema default and a zero
      # count — the unrated game contributed nothing.
      lonely = profile(bot_only)
      assert lonely.rating_mu == 25.0
      assert lonely.rating_games_count == 0

      # a played only the rated game -> count 1
      assert profile(a).rating_games_count == 1
    end

    test "empty history: returns zero counts, clears cursor" do
      assert {:ok, %{profiles: 0, games: 0}} = Profiles.rerate_all()

      assert %RatingState{last_completed_at: nil, last_game_id: nil} =
               Repo.get(RatingState, RatingState.singleton_id())
    end
  end

  describe "rerate_incremental/0" do
    test "incremental equals full rebuild (headline correctness)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: uuid()
      base = ~U[2026-06-07 12:00:00Z]

      # Batch A.
      complete_game("A1", {a, b, c, d}, :north_south, at(base, 0))
      complete_game("A2", {a, c, b, d}, :east_west, at(base, 1))

      assert {:ok, _} = Profiles.rerate_all()

      # Batch B (later completed_at).
      complete_game("B1", {e, f, a, b}, :north_south, at(base, 10))
      complete_game("B2", {c, d, e, f}, :east_west, at(base, 11))

      assert {:ok, %{games: applied}} = Profiles.rerate_incremental()
      assert applied == 2

      incremental = snapshot()

      # Fresh full rebuild over A+B is the source of truth.
      assert {:ok, _} = Profiles.rerate_all()
      full = snapshot()

      assert_profiles_match(incremental, full)
    end

    test "empty batch (cursor at latest) applies 0 games, changes nothing" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      complete_game("R1", {a, b, c, d}, :north_south, ~U[2026-06-07 12:00:00Z])

      assert {:ok, _} = Profiles.rerate_all()
      before = snapshot()

      assert {:ok, %{games: 0}} = Profiles.rerate_incremental()
      assert_profiles_match(before, snapshot())
    end

    test "first-ever incremental (null cursor) processes all games" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      base = ~U[2026-06-07 12:00:00Z]
      complete_game("R1", {a, b, c, d}, :north_south, at(base, 0))
      complete_game("R2", {a, c, b, d}, :east_west, at(base, 1))

      assert {:ok, %{games: 2}} = Profiles.rerate_incremental()
      from_incremental = snapshot()

      assert {:ok, _} = Profiles.rerate_all()
      assert_profiles_match(from_incremental, snapshot())
    end

    test "cursor advances to the last processed game" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      complete_game("R1", {a, b, c, d}, :north_south, ~U[2026-06-07 12:00:01Z])

      assert {:ok, _} = Profiles.rerate_incremental()

      last =
        Repo.one(
          from gs in PidroServer.Stats.GameStats, order_by: [desc: gs.completed_at], limit: 1
        )

      state = Repo.get(RatingState, RatingState.singleton_id())
      assert state.last_game_id == last.id
      assert state.last_completed_at == last.completed_at
    end

    test "composite-cursor boundary: same-second games after the cursor are picked up" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      tie = ~U[2026-06-07 12:00:00Z]

      # Three games all share `completed_at == tie`.
      complete_game("R1", {a, b, c, d}, :north_south, tie)
      complete_game("R2", {a, c, b, d}, :east_west, tie)
      complete_game("R3", {b, d, a, c}, :north_south, tie)

      # The total order is [completed_at, inserted_at, id]; pin the cursor to the
      # FIRST game in that order so the other two share the cursor's second but
      # sort strictly after it. A naive `completed_at >` filter would skip them.
      ordered =
        Repo.all(
          from gs in PidroServer.Stats.GameStats,
            order_by: [asc: gs.completed_at, asc: gs.inserted_at, asc: gs.id]
        )

      [first | _rest] = ordered

      %RatingState{id: RatingState.singleton_id()}
      |> RatingState.changeset(%{
        last_completed_at: first.completed_at,
        last_inserted_at: first.inserted_at,
        last_game_id: first.id
      })
      |> Repo.insert!()

      # The two games after the cursor (same second) must be picked up, not skipped.
      assert {:ok, %{games: 2}} = Profiles.rerate_incremental()
    end

    test "--all resets the cursor so a following incremental applies 0 games" do
      [a, b, c, d] = for _ <- 1..4, do: uuid()
      base = ~U[2026-06-07 12:00:00Z]
      complete_game("R1", {a, b, c, d}, :north_south, at(base, 0))
      complete_game("R2", {a, c, b, d}, :east_west, at(base, 1))

      assert {:ok, _} = Profiles.rerate_all()
      assert {:ok, %{games: 0}} = Profiles.rerate_incremental()
    end
  end

  # --- local helpers ---

  defp uuid, do: Ecto.UUID.generate()

  defp at(%DateTime{} = base, seconds), do: DateTime.add(base, seconds, :second)

  # In-memory atom-keyed results for the pure tests (no DB round-trip).
  defp team_results({n, e, s, w}, winner) do
    %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }
  end

  defp assert_profiles_close(a, b) do
    assert Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort()

    Enum.each(a, fn {id, {mu, sigma}} ->
      {b_mu, b_sigma} = Map.fetch!(b, id)
      assert_in_delta mu, b_mu, @delta
      assert_in_delta sigma, b_sigma, @delta
    end)
  end
end
