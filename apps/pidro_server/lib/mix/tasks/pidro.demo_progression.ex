defmodule Mix.Tasks.Pidro.DemoProgression do
  @moduledoc """
  Dev demonstration: four real users play many full Pidro games against each
  other — every move chosen by the existing bot strategy on the current seat's
  legal actions — and their player profiles PROGRESS as a result.

  Nothing is faked: games are driven turn-by-turn through the real
  `GameAdapter`/engine until a team reaches 62 and the engine reports
  `phase: :complete`. After each game we synchronize on the post-commit
  `{:progression_summary, ...}` broadcast (the same signal the live game-over
  path fires once stats + profile rollups have committed) and then read each
  user's profile via `Profiles.public_profile/1`.

  ## Usage

      MIX_ENV=dev mix pidro.demo_progression       # 12 games (default)
      MIX_ENV=dev mix pidro.demo_progression 20     # custom game count

  Boots the app (no web server / browser needed). At the end it prints a
  per-user progression report and runs `Profiles.rerate_all/0` to demonstrate
  the rebuild-from-history == live-ratings parity guarantee on real games.
  """
  use Mix.Task

  alias PidroServer.Accounts.Auth
  alias PidroServer.Games.Bots.Strategies.RandomStrategy
  alias PidroServer.Games.{GameAdapter, GameSupervisor, RoomManager}
  alias PidroServer.Profiles
  alias PidroServer.Rating

  @positions [:north, :east, :south, :west]
  # Hard ceiling on APPLIED actions so a pathological random game can never
  # infinite-loop. A normal Pidro game is a few hundred applied actions; random
  # bidding can stretch a game over many hands, so this is generous.
  @max_actions 50_000
  # Hard ceiling on consecutive polls where NO seat can act. With the cosmetic
  # transition delays collapsed to 0, every automatic phase advances within a
  # poll or two; a long run of idle polls therefore means a genuine engine wedge
  # (see play_one_game/3), which we detect and replay rather than spin on.
  @max_idle_polls 200
  @summary_timeout_ms 15_000
  # Max fresh re-deals for a single game number before giving up (a transient
  # engine wedge clears on a new deal; a persistent one should surface).
  @max_game_attempts 8

  @shortdoc "Dev: 4 users play N real games; show profile progression + rerate parity"

  @impl Mix.Task
  def run(args) do
    num_games = parse_games(args)

    # Boot the OTP app (Repo, RoomManager, supervisors, PubSub) without Phoenix
    # endpoint serving — we drive the engine directly.
    Mix.Task.run("app.start")

    # Collapse the cosmetic UI delays for a fast headless run: the dealer-
    # selection ceremony (3s), trick (1.5s) and hand (3s) transition pauses exist
    # only so a human client can watch them. None affect game logic or the
    # profile/rating math — they just slow the driver's poll loop. Drop them to 0
    # so games complete quickly. (start_game/1 reads dealer_selection_delay_ms at
    # game start; trick/hand delays are read per-transition.)
    existing = Application.get_env(:pidro_server, PidroServer.Games.Lifecycle, [])

    Application.put_env(
      :pidro_server,
      PidroServer.Games.Lifecycle,
      Keyword.merge(existing,
        dealer_selection_delay_ms: 0,
        trick_transition_delay_ms: 0,
        hand_transition_delay_ms: 0
      )
    )

    suffix = Integer.to_string(System.system_time(:millisecond), 36)
    users = create_users(suffix)

    IO.puts("\n=== Pidro progression demo: #{num_games} real games, 4 agents ===")
    IO.puts("Users (demo, suffix #{suffix}):")

    Enum.each(users, fn u ->
      IO.puts("  #{u.label} -> #{u.username} (#{u.id})")
    end)

    # Per-game progression snapshots, accumulated for the final report.
    #
    # `game_stats.completed_at`/`inserted_at` are SECOND-precision. The demo
    # finishes games in well under a second, so without spacing many games share
    # one timestamp and the canonical rerate order `[completed_at, inserted_at,
    # id]` tiebreaks on a random UUID — a different (but equally valid) order than
    # the live sequential order. OpenSkill is order-sensitive, so that would make
    # the live values and a from-scratch rerate diverge purely as a timestamp-
    # resolution artifact (NOT a ratings bug). Spacing completions into distinct
    # seconds makes the live application order == the rerate total order, so the
    # parity guarantee is exact. ~1.1s/game.
    history =
      Enum.reduce(1..num_games, [], fn game_no, acc ->
        if game_no > 1, do: Process.sleep(1_100)
        snapshot = play_one_game(game_no, users)
        print_game_line(game_no, users, snapshot)
        [snapshot | acc]
      end)
      |> Enum.reverse()

    print_report(users, history)
    print_rerate_parity(users)

    IO.puts("\nDone.")
  end

  # --- Setup ---

  defp parse_games([]), do: 12

  defp parse_games([arg | _]) do
    case Integer.parse(arg) do
      {n, _} when n > 0 -> n
      _ -> 12
    end
  end

  defp create_users(suffix) do
    [
      {"North", :north},
      {"East", :east},
      {"South", :south},
      {"West", :west}
    ]
    |> Enum.map(fn {label, seat} ->
      username = "demo_#{String.downcase(label)}_#{suffix}"

      {:ok, user} =
        Auth.register_user(%{
          username: username,
          email: "#{username}@demo.pidro",
          password: "demo_password_123"
        })

      %{id: user.id, username: username, label: label, seat: seat}
    end)
  end

  # --- Drive one full game ---

  # Plays ONE real game to a natural finish and returns the post-game profile
  # snapshot. Rarely, a random play-out wedges the engine in a known edge case
  # (a non-eliminated player left holding only non-trump cards in :playing — no
  # legal move exists and the phase can't transition). That is an engine corner,
  # not a persistence/profile issue; we discard the wedged, UNPERSISTED room and
  # replay this game number with a fresh deal so every reported game is a real,
  # completed game. Capped so a persistent wedge still surfaces loudly.
  defp play_one_game(game_no, users, attempt \\ 1)

  defp play_one_game(game_no, _users, attempt) when attempt > @max_game_attempts do
    raise "demo: game #{game_no} failed to complete after #{@max_game_attempts} fresh deals — engine wedge is not transient"
  end

  defp play_one_game(game_no, users, attempt) do
    [host | rest] = users

    {:ok, room} = RoomManager.create_room(host.id, %{name: "demo-#{game_no}"})
    room_code = room.code

    # Seat the other three at deterministic positions so North/East/South/West
    # map to the same users each game (host auto-took the first open seat).
    Enum.each(rest, fn u ->
      {:ok, _room, _pos} = RoomManager.join_room(room_code, u.id, u.seat)
    end)

    # The 4th join auto-starts the game (status :ready -> start_game_for_room).
    # Be robust if that path changes: ensure a game process exists.
    case GameSupervisor.get_game(room_code) do
      {:ok, _pid} -> :ok
      {:error, :not_found} -> {:ok, _} = GameSupervisor.start_game(room_code)
    end

    # Subscribe BEFORE the game can finish so we never miss the post-commit
    # progression broadcast.
    :ok = GameAdapter.subscribe(room_code)

    case drive(room_code, 0, 0) do
      :ok ->
        # Synchronize on persistence: the RoomManager :game_over handler saves
        # stats + profile rollups asynchronously, then broadcasts
        # {:progression_summary, room_code, summaries} POST-COMMIT. Block until we
        # see it (or fall back to draining the RoomManager mailbox) before reading.
        await_persistence(room_code)
        GameAdapter.unsubscribe(room_code)

        # Capture each user's public profile after this game.
        snapshot = Map.new(users, fn u -> {u.id, Profiles.public_profile(u.id)} end)

        # Tear the finished room down so its players are released from
        # player_rooms and the next game's create/join don't hit :already_in_room.
        RoomManager.close_room(room_code)

        snapshot

      {:deadlock, detail} ->
        GameAdapter.unsubscribe(room_code)
        # Nothing was persisted (the engine never reached :complete, so no
        # :game_over fired). Drop the room and replay this game number.
        RoomManager.close_room(room_code)

        IO.puts(
          "  (game #{game_no}: engine wedge on attempt #{attempt} — #{detail}; replaying with a fresh deal)"
        )

        play_one_game(game_no, users, attempt + 1)
    end
  end

  # Turn-by-turn loop: read state, find the seat with legal actions, pick one via
  # the existing RandomStrategy, apply it. Automatic phases (dealing, discarding,
  # scoring, hand_complete) and the timed dealer_selection ceremony expose no
  # legal actions to anyone; we briefly yield and re-poll so the engine's
  # internal auto-transition / timer can run.
  #
  # `actions` counts only APPLIED moves; `idle` counts consecutive no-op polls
  # since the last applied move. Both have independent caps so neither a long
  # random game nor a wedged automatic phase can spin forever.
  defp drive(room_code, actions, _idle) when actions >= @max_actions do
    {:deadlock, stuck_detail(room_code, "exceeded #{@max_actions} applied actions")}
  end

  defp drive(room_code, _actions, idle) when idle >= @max_idle_polls do
    {:deadlock, stuck_detail(room_code, "#{@max_idle_polls} idle polls, no actionable seat")}
  end

  defp drive(room_code, actions, idle) do
    case GameAdapter.get_state(room_code) do
      {:ok, %{phase: :complete}} ->
        :ok

      {:ok, state} ->
        case next_actionable_seat(room_code) do
          {:ok, position, legal_actions} ->
            {:ok, action, _reasoning} = RandomStrategy.pick_action(legal_actions, state)

            case GameAdapter.apply_action(room_code, position, action) do
              {:ok, _new_state} ->
                drive(room_code, actions + 1, 0)

              {:error, _reason} ->
                # Lost a race against an auto-transition; re-poll.
                Process.sleep(5)
                drive(room_code, actions, idle + 1)
            end

          :none ->
            # No seat can act: an automatic/timed phase is mid-transition
            # (e.g. dealing, scoring, or the dealer_selection timer). Yield and
            # re-poll rather than busy-spin. Does NOT consume the action budget.
            Process.sleep(15)
            drive(room_code, actions, idle + 1)
        end

      {:error, _reason} ->
        # Game process gone (already completed + torn down) — treat as done.
        :ok
    end
  end

  defp stuck_detail(room_code, why) do
    case GameAdapter.get_state(room_code) do
      {:ok, state} ->
        "#{why} (phase=#{state.phase} current_turn=#{inspect(state.current_turn)} " <>
          "hand=#{Map.get(state, :hand_number)} scores=#{inspect(state.cumulative_scores)})"

      _ ->
        why
    end
  end

  defp next_actionable_seat(room_code) do
    Enum.reduce_while(@positions, :none, fn position, _acc ->
      case GameAdapter.get_legal_actions(room_code, position) do
        {:ok, [_ | _] = actions} -> {:halt, {:ok, position, actions}}
        _ -> {:cont, :none}
      end
    end)
  end

  # Wait for the post-commit progression broadcast. If we somehow miss it (very
  # fast completion before subscribe propagated), fall back to draining the
  # RoomManager via a synchronous call — by the time that call returns, the
  # earlier :game_over handle_info has been processed and persistence committed.
  defp await_persistence(room_code) do
    receive do
      {:progression_summary, ^room_code, _summaries} -> :ok
    after
      @summary_timeout_ms ->
        # Synchronous round-trip to the RoomManager flushes its mailbox: the
        # :game_over handle_info (which persists synchronously) ran before this
        # reply is produced.
        _ = RoomManager.get_room(room_code)
        :ok
    end
  end

  # --- Reporting ---

  defp print_game_line(game_no, users, snapshot) do
    cells =
      Enum.map(users, fn u ->
        p = Map.fetch!(snapshot, u.id)
        tier = tier_str(p.skill)
        "#{u.label}: #{p.wins}-#{p.losses} L#{p.veteran.level} #{tier}"
      end)

    IO.puts("game #{pad(game_no, 2)} | " <> Enum.join(cells, " | "))
  end

  defp print_report(users, history) do
    IO.puts("\n=== FINAL REPORT ===")

    final = List.last(history)

    Enum.each(users, fn u ->
      p = Map.fetch!(final, u.id)

      IO.puts("\n#{u.label} — #{u.username}")
      IO.puts("  games_played: #{p.games_played}  wins: #{p.wins}  losses: #{p.losses}")
      IO.puts("  win_rate: #{Float.round(p.win_rate * 1.0, 3)}")

      IO.puts("  veteran: level #{p.veteran.level} — \"#{p.veteran.title}\" (#{p.veteran.xp} XP)")

      IO.puts("  skill: #{tier_str(p.skill)} (provisional: #{p.skill.provisional})")

      IO.puts("  playstyle: #{playstyle_str(p.playstyle)}")
      IO.puts("  achievements: #{achievements_str(p.achievements)}")
    end)

    print_evolution(users, history)
  end

  # Show how tier / provisional / level evolved across the run, and pinpoint the
  # game at which provisional cleared and at which each achievement unlocked.
  defp print_evolution(users, history) do
    IO.puts("\n=== EVOLUTION ACROSS THE RUN ===")

    Enum.each(users, fn u ->
      IO.puts("\n#{u.label}:")

      # Tier / provisional / level trail, per game.
      trail =
        history
        |> Enum.with_index(1)
        |> Enum.map(fn {snapshot, game_no} ->
          p = Map.fetch!(snapshot, u.id)
          {game_no, tier_str(p.skill), p.skill.provisional, p.veteran.level}
        end)

      Enum.each(trail, fn {g, tier, prov, level} ->
        IO.puts("  after g#{pad(g, 2)}: tier=#{tier} provisional=#{prov} level=#{level}")
      end)

      case provisional_cleared_at(trail) do
        nil ->
          IO.puts("  -> still PROVISIONAL after #{length(trail)} games")

        game_no ->
          IO.puts("  -> left PROVISIONAL after game #{game_no}")
      end

      print_achievement_unlocks(u, history)
    end)
  end

  defp provisional_cleared_at(trail) do
    Enum.find_value(trail, fn {game_no, _tier, prov, _level} ->
      if prov == false, do: game_no
    end)
  end

  # First game at which each achievement key appears in the snapshot.
  defp print_achievement_unlocks(u, history) do
    {unlocks, _seen} =
      history
      |> Enum.with_index(1)
      |> Enum.reduce({[], MapSet.new()}, fn {snapshot, game_no}, {acc, seen} ->
        p = Map.fetch!(snapshot, u.id)
        keys = Enum.map(p.achievements, & &1.key)

        new_keys = Enum.reject(keys, &MapSet.member?(seen, &1))

        acc =
          Enum.reduce(new_keys, acc, fn key, acc ->
            name = name_for_key(p.achievements, key)
            [{game_no, key, name} | acc]
          end)

        {acc, MapSet.union(seen, MapSet.new(keys))}
      end)

    case Enum.reverse(unlocks) do
      [] ->
        IO.puts("  achievements unlocked: (none)")

      list ->
        IO.puts("  achievements unlocked:")

        Enum.each(list, fn {game_no, key, name} ->
          IO.puts("    g#{pad(game_no, 2)}: #{name} (#{key})")
        end)
    end
  end

  # --- Rerate parity ---

  # The headline guarantee: wipe ratings and rebuild from full game_stats
  # history, then assert the rebuilt μ/σ/count match the live values produced
  # incrementally during the run. Demonstrated on the real games just played.
  defp print_rerate_parity(users) do
    IO.puts("\n=== LIVE == REBUILD PARITY ===")

    before = Map.new(users, fn u -> {u.id, live_rating(u.id)} end)

    {:ok, %{profiles: profiles, games: games}} = Profiles.rerate_all()
    IO.puts("rerate_all/0 replayed #{games} rated games across #{profiles} profiles")

    mismatches =
      Enum.filter(users, fn u ->
        before_r = Map.fetch!(before, u.id)
        after_r = live_rating(u.id)
        not ratings_equal?(before_r, after_r)
      end)

    Enum.each(users, fn u ->
      {mu, sigma, count} = live_rating(u.id)

      IO.puts(
        "  #{u.label}: mu=#{Float.round(mu, 4)} sigma=#{Float.round(sigma, 4)} rated_games=#{count} (ordinal=#{Float.round(Rating.ordinal({mu, sigma}), 4)})"
      )
    end)

    if mismatches == [] do
      IO.puts("\nlive == rebuild: OK")
    else
      labels = Enum.map_join(mismatches, ", ", & &1.label)
      IO.puts("\nlive == rebuild: MISMATCH (#{labels})")
    end
  end

  defp live_rating(user_id) do
    {:ok, screen} = Profiles.get_profile_for_screen(user_id)
    {screen.rating_mu, screen.rating_sigma, screen.rating_games_count}
  end

  defp ratings_equal?({mu1, s1, c1}, {mu2, s2, c2}) do
    c1 == c2 and abs(mu1 - mu2) < 1.0e-9 and abs(s1 - s2) < 1.0e-9
  end

  # --- Formatting helpers ---

  defp tier_str(%{tier: tier, provisional: true}), do: "provisional(#{tier})"
  defp tier_str(%{tier: tier}), do: Atom.to_string(tier)

  defp playstyle_str(%{aggression_insufficient: true}),
    do: "(insufficient bidding data)"

  defp playstyle_str(ps) do
    rate =
      case ps.bidding_win_rate do
        nil -> "n/a"
        r -> Float.round(r * 1.0, 3)
      end

    avg =
      case ps.avg_winning_bid do
        nil -> "n/a"
        a -> Float.round(a * 1.0, 2)
      end

    "#{ps.aggression_label} (needle=#{ps.aggression_needle}, bid_win_rate=#{rate}, avg_winning_bid=#{avg})"
  end

  defp achievements_str([]), do: "(none)"

  defp achievements_str(list) do
    Enum.map_join(list, ", ", & &1.name)
  end

  defp name_for_key(achievements, key) do
    case Enum.find(achievements, &(&1.key == key)) do
      %{name: name} -> name
      _ -> Atom.to_string(key)
    end
  end

  defp pad(n, width) do
    n |> Integer.to_string() |> String.pad_leading(width)
  end
end
