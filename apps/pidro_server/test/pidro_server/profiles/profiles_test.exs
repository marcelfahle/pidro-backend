defmodule PidroServer.ProfilesTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Stats

  defp insert_user do
    {:ok, user} =
      PidroServer.Accounts.Auth.register_user(%{
        username: "user_#{System.unique_integer([:positive])}",
        password: "password123"
      })

    user
  end

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  describe "get_or_create_profile/1" do
    test "creates a default row when none exists" do
      user_id = Ecto.UUID.generate()

      assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.user_id == user_id
      assert profile.games_played == 0
      assert profile.wins == 0
      assert profile.losses == 0
      assert profile.rating_mu == 25.0
      assert profile.rating_sigma == 8.333
      assert profile.rating_games_count == 0
      assert profile.veteran_level == 0
      assert profile.heritage_flags == %{}
    end

    test "returns the existing row on second call (no duplicate)" do
      user_id = Ecto.UUID.generate()

      assert {:ok, first} = Profiles.get_or_create_profile(user_id)
      assert {:ok, second} = Profiles.get_or_create_profile(user_id)

      assert first.id == second.id
      assert Repo.aggregate(PlayerProfile, :count) == 1
    end

    test "calling twice never raises and never creates a duplicate" do
      user_id = Ecto.UUID.generate()

      assert {:ok, _} = Profiles.get_or_create_profile(user_id)
      assert {:ok, _} = Profiles.get_or_create_profile(user_id)

      assert Repo.aggregate(from(p in PlayerProfile, where: p.user_id == ^user_id), :count) == 1
    end
  end

  describe "get_profile_for_screen/1" do
    test "lazily creates and returns win_rate 0.0 with no games" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.games_played == 0
      assert view.win_rate == 0.0
      assert view.avg_winning_bid == 0.0
      assert view.first_seen_at == Repo.reload!(user).inserted_at
      assert is_integer(view.account_age_days)
    end

    test "computes win_rate correctly for a populated profile" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{games_played: 4, wins: 3, losses: 1})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 0.75
    end

    test "computes avg_winning_bid from sum/count" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{avg_winning_bid_sum: 30, avg_winning_bid_count: 3})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.avg_winning_bid == 10.0
    end

    test "untouched profile reports veteran_level 1 (XP-derived, not raw 0) and empty heritage" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.veteran_xp == 0
      assert view.veteran_level == 1
      assert view.veteran_title == "Rookie"
      assert view.veteran_progress == {0, 83}
      assert view.heritage == []
      assert view.heritage_flags == %{}
    end

    test "veteran fields derive from stored XP" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      # Stale/zero cached level on purpose; the screen recomputes from XP.
      profile
      |> PlayerProfile.changeset(%{veteran_xp: 200, veteran_level: 0})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.veteran_xp == 200
      assert view.veteran_level == PidroServer.Progression.level_for_xp(200)
      assert view.veteran_title == PidroServer.Progression.title_for_level(view.veteran_level)
      assert view.veteran_progress == PidroServer.Progression.level_progress(200)
    end

    test "heritage display list reflects heritage_flags" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{
        heritage_flags: %{"played_pidro_one" => true, "legacy_level" => 73}
      })
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert Enum.map(view.heritage, & &1.key) == [:played_pidro_one, :legacy_level]
    end
  end

  describe "apply_completed_game/2" do
    test "winner gets games_played +1 and wins +1" do
      user_id = Ecto.UUID.generate()
      player_results = %{user_id => result_for(:north_south, :north_south, :north)}

      assert :ok = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
      assert profile.wins == 1
      assert profile.losses == 0
    end

    test "loser gets games_played +1 and losses +1" do
      user_id = Ecto.UUID.generate()
      player_results = %{user_id => result_for(:east_west, :north_south, :east)}

      assert :ok = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
      assert profile.wins == 0
      assert profile.losses == 1
    end

    test "creates profiles lazily for previously-unknown users" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      player_results = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      assert :ok = Profiles.apply_completed_game(player_results, :north_south)

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u1)
      assert {:ok, %{losses: 1}} = Profiles.get_or_create_profile(u2)
    end

    test "abandoned-but-on-winning-team user counts as a win" do
      user_id = Ecto.UUID.generate()

      player_results = %{
        user_id => %{
          participation: :abandoned,
          result: :win,
          team: :north_south,
          position: :north
        }
      }

      assert :ok = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.wins == 1
    end

    test "skips non-UUID ids without crashing" do
      valid = Ecto.UUID.generate()

      player_results = %{
        valid => result_for(:north_south, :north_south, :north),
        "dev_host" => result_for(:east_west, :north_south, :east)
      }

      assert :ok = Profiles.apply_completed_game(player_results, :north_south)

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(valid)
      assert Repo.aggregate(PlayerProfile, :count) == 1
    end
  end

  describe "win% edge cases" do
    test "0 games -> 0.0" do
      user_id = Ecto.UUID.generate()
      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 0.0
    end

    test "all wins -> 1.0" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      profile |> PlayerProfile.changeset(%{games_played: 3, wins: 3}) |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 1.0
    end
  end

  describe "rebuild_from_history/1" do
    defp save_game(room_code, winner, user_ids, results) do
      {:ok, _} =
        Stats.save_game_result(%{
          room_code: room_code,
          winner: winner,
          final_scores: %{north_south: 62, east_west: 45},
          bid_amount: 8,
          bid_team: :north_south,
          duration_seconds: 300,
          completed_at: DateTime.utc_now(),
          player_ids: user_ids,
          player_results: results
        })
    end

    test "reproduces the same counters as incremental application (DB round-trip)" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      results1 = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      results2 = %{
        u1 => result_for(:north_south, :east_west, :north),
        u2 => result_for(:east_west, :east_west, :east)
      }

      # Incremental
      assert :ok = Profiles.apply_completed_game(results1, :north_south)
      assert :ok = Profiles.apply_completed_game(results2, :east_west)

      {:ok, inc_u1} = Profiles.get_or_create_profile(u1)
      {:ok, inc_u2} = Profiles.get_or_create_profile(u2)

      # Persist the same games (string-keyed JSONB after round-trip)
      save_game("ROOMA", :north_south, [u1, u2], results1)
      save_game("ROOMB", :east_west, [u1, u2], results2)

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      assert {reb_u1.games_played, reb_u1.wins, reb_u1.losses} ==
               {inc_u1.games_played, inc_u1.wins, inc_u1.losses}

      assert {reb_u2.games_played, reb_u2.wins, reb_u2.losses} ==
               {inc_u2.games_played, inc_u2.wins, inc_u2.losses}

      assert {reb_u1.games_played, reb_u1.wins} == {2, 1}
    end

    test "is idempotent (running twice yields identical counters)" do
      u1 = Ecto.UUID.generate()

      save_game("ROOMC", :north_south, [u1], %{
        u1 => result_for(:north_south, :north_south, :north)
      })

      assert {:ok, first} = Profiles.rebuild_from_history(u1)
      assert {:ok, second} = Profiles.rebuild_from_history(u1)

      assert {first.games_played, first.wins, first.losses} ==
               {second.games_played, second.wins, second.losses}
    end

    test "overwrites drifted counters" do
      u1 = Ecto.UUID.generate()

      save_game("ROOMD", :north_south, [u1], %{
        u1 => result_for(:north_south, :north_south, :north)
      })

      {:ok, profile} = Profiles.get_or_create_profile(u1)
      profile |> PlayerProfile.changeset(%{games_played: 99, wins: 99}) |> Repo.update!()

      assert {:ok, rebuilt} = Profiles.rebuild_from_history(u1)
      assert rebuilt.games_played == 1
      assert rebuilt.wins == 1
      assert rebuilt.losses == 0
    end

    test "tolerates a historical row with nil player_results via position fallback" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      # player_results nil; position derived from order in player_ids:
      # index 0 -> :north (north_south), index 1 -> :east (east_west)
      save_game("ROOME", :north_south, [u1, u2], nil)

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      assert reb_u1.games_played == 1
      assert reb_u1.wins == 1
      assert reb_u2.wins == 0
      assert reb_u2.losses == 1
    end
  end

  describe "rebuild_all/0" do
    test "rebuilds every user appearing in player_ids and returns the count" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()
      u3 = Ecto.UUID.generate()

      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "ROOMF",
          winner: :north_south,
          completed_at: DateTime.utc_now(),
          duration_seconds: 100,
          player_ids: [u1, u2],
          player_results: %{
            u1 => result_for(:north_south, :north_south, :north),
            u2 => result_for(:east_west, :north_south, :east)
          }
        })

      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "ROOMG",
          winner: :east_west,
          completed_at: DateTime.utc_now(),
          duration_seconds: 100,
          player_ids: [u3],
          player_results: %{u3 => result_for(:east_west, :east_west, :east)}
        })

      assert {:ok, 3} = Profiles.rebuild_all()

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u1)
      assert {:ok, %{losses: 1}} = Profiles.get_or_create_profile(u2)
      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u3)
    end
  end
end
