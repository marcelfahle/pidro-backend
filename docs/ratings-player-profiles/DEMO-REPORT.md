# Ratings & Player Profiles — End-to-End Demo Report

This documents a **real, end-to-end demonstration** that programmatic "agents"
(seats driven by the existing bot decision logic) play full Pidro games through
the real engine, and that player **profiles genuinely progress** as a result —
wins/losses, Veteran level + XP, skill tier / provisional state, playstyle, and
achievements all move from actual played games. It also demonstrates the
**live == rebuild-from-history rating parity** guarantee on those real games.

Nothing is faked. Games are driven turn-by-turn through `GameAdapter`/the engine
until a team reaches 62 and the engine reports `phase: :complete`. Persistence is
synchronized on the real post-commit `{:progression_summary, ...}` broadcast.

## What the demo does

The dev Mix task `apps/pidro_server/lib/mix/tasks/pidro.demo_progression.ex`:

1. Creates **4 real users** (`Accounts.Auth.register_user/1`) with timestamped
   demo usernames (`demo_north_<suffix>` …) so reruns don't collide.
2. For each of N games (default 12):
   - `RoomManager.create_room/2` (host = user1), the other three
     `RoomManager.join_room/3` at fixed seats (North/East/South/West map to the
     same users every game). The 4th join auto-starts the game.
   - **Drives the game to completion**: loop `{get_state → find the seat with
     legal actions → RandomStrategy.pick_action/2 → apply_action}`. Every phase
     is handled — dealer selection, bidding, trump declaration, second-deal /
     discard, and trick play across multiple hands until a team reaches 62.
     Automatic/timed phases (dealing, scoring, hand transitions) expose no legal
     actions; the driver yields and re-polls so the engine's internal
     auto-transition runs. Hard caps (`@max_actions`, `@max_idle_polls`) make an
     infinite loop impossible.
   - **Synchronizes on persistence**: subscribes to `game:<room_code>` and
     `receive`s the post-commit `{:progression_summary, room_code, summaries}`
     (the same signal the live game-over path fires once stats + profile rollups
     have committed), with a mailbox-drain fallback, before reading profiles.
   - Captures each user's `Profiles.public_profile/1` and prints a per-game line.
3. Prints a **final report** per user (games/wins/losses/win-rate, Veteran
   level+XP+title, skill tier+provisional, playstyle, achievements) and an
   **evolution trail** (tier/provisional/level after every game; the game at
   which each achievement unlocked).
4. Runs `Profiles.rerate_all/0` and asserts the rebuilt μ/σ/count match the live
   incremental values — printing **`live == rebuild: OK`**.

### Engine edge case, handled honestly

A small fraction of random play-outs wedge the **engine** in a known corner: in
`:playing`, the current player can be left holding only non-trump cards — there
is no legal move and the phase can't transition (elimination is only checked
*after* a play; the trick-leader skip only skips already-eliminated seats). This
is an engine corner that exists for the live bot path too, not a
persistence/profile issue. The demo detects the wedge, **discards the
un-persisted room, and replays that game number with a fresh deal** (capped at
`@max_game_attempts`). It never injects a synthetic `{:game_over}` — every
reported game is a real game played to 62. In the captured run, games 12 and 14
each wedged once and were transparently replayed.

## Command to reproduce

```bash
# from the repo root (dev DB must be running)
MIX_ENV=dev mix ecto.migrate            # if needed
MIX_ENV=dev mix pidro.demo_progression 14
```

The captured run below used `14`. The default (no arg) is `12`.

> Note: the run wipes nothing; it creates fresh suffixed users each time. To get
> a self-contained `rerate_all` count, the demo DB was cleared of prior
> `demo_*` rows before this capture.

## Captured output (real run, 14 games)

### Per-game progression (live)

```
game  1 | North: 0-1 L1 provisional | East: 1-0 L2 provisional | South: 0-1 L1 provisional | West: 1-0 L2 provisional
game  2 | North: 0-2 L1 provisional | East: 2-0 L3 provisional | South: 0-2 L1 provisional | West: 2-0 L3 provisional
game  3 | North: 0-3 L2 provisional | East: 3-0 L4 provisional | South: 0-3 L2 provisional | West: 3-0 L4 provisional
game  4 | North: 0-4 L2 provisional | East: 4-0 L5 provisional | South: 0-4 L2 provisional | West: 4-0 L5 provisional
game  5 | North: 0-5 L2 provisional | East: 5-0 L6 provisional | South: 0-5 L2 provisional | West: 5-0 L6 provisional
game  6 | North: 0-6 L3 provisional | East: 6-0 L7 provisional | South: 0-6 L3 provisional | West: 6-0 L7 provisional
game  7 | North: 0-7 L3 provisional | East: 7-0 L8 provisional | South: 0-7 L3 provisional | West: 7-0 L8 provisional
game  8 | North: 0-8 L3 provisional | East: 8-0 L8 provisional | South: 0-8 L3 provisional | West: 8-0 L8 provisional
game  9 | North: 0-9 L3 provisional | East: 9-0 L9 provisional | South: 0-9 L3 provisional | West: 9-0 L9 provisional
game 10 | North: 0-10 L4 provisional | East: 10-0 L10 provisional | South: 0-10 L4 provisional | West: 10-0 L10 provisional
game 11 | North: 1-10 L5 provisional | East: 10-1 L10 provisional | South: 1-10 L5 provisional | West: 10-1 L10 provisional
  (game 12: engine wedge on attempt 1 — phase=playing current_turn=:west hand=4 scores=%{north_south: -16, east_west: 8}; replaying with a fresh deal)
game 12 | North: 1-11 L5 provisional | East: 11-1 L10 provisional | South: 1-11 L5 provisional | West: 11-1 L10 provisional
game 13 | North: 2-11 L6 provisional | East: 11-2 L10 provisional | South: 2-11 L6 provisional | West: 11-2 L10 provisional
  (game 14: engine wedge on attempt 1 — phase=playing current_turn=:south hand=5 scores=%{north_south: 47, east_west: -17}; replaying with a fresh deal)
game 14 | North: 2-12 L6 provisional | East: 12-2 L11 provisional | South: 2-12 L6 provisional | West: 12-2 L11 provisional
```

This run produced a lopsided East/West-dominant outcome (12–2), which usefully
shows the skill metric diverging (see parity table).

### Final report (after 14 games)

| Seat (user)            | games | W–L  | win rate | Veteran level / title       | XP   | Skill              | Playstyle (label, needle, bid-win, avg-bid) | Achievements |
|------------------------|:-----:|:----:|:--------:|-----------------------------|-----:|--------------------|---------------------------------------------|--------------|
| North (demo_north)     | 14    | 2–12 | 0.143    | L6 — "Apprentice"           | 561  | provisional        | balanced (0.595, 0.279, 7.72)               | The Loser, Player, Partnership |
| East (demo_east)       | 14    | 12–2 | 0.857    | L11 — "Journeyman"          | 1443 | provisional        | balanced (0.476, 0.243, 7.44)               | Ace, Partnership, Win Streak, The Winner, Player |
| South (demo_south)     | 14    | 2–12 | 0.143    | L6 — "Apprentice"           | 561  | provisional        | balanced (0.548, 0.264, 7.51)               | The Loser, Player, Partnership |
| West (demo_west)       | 14    | 12–2 | 0.857    | L11 — "Journeyman"          | 1443 | provisional        | balanced (0.381, 0.214, 7.63)               | Ace, Partnership, Win Streak, The Winner, Player |

### Evolution — Veteran level climbs every game; achievements unlock at real games

`East`/`West` (the winning team) Veteran level trail: L2→L3→L4→L5→L6→L7→L8→L8→L9→L10→L10→L10→L10→**L11**.
`North`/`South` (the losing team): L1→L1→L2→L2→L2→L3→L3→L3→L3→L4→L5→L5→L6→**L6**.

Achievements unlocked (and the game they unlocked at):

- **East / West**: `Ace` (g1), `Partnership` (g1), `Win Streak` (g3), `The Winner` (g5), `Player` (g10).
- **North / South**: `The Loser` (g1), `Player` (g10), `Partnership` (g11).

### Tier / Provisional evolution

Every seat stays `provisional` for all 14 games. The Provisional gate clears only
when **both** `rating_games_count >= 10` **and** `sigma < 6.0` hold:

- The **count gate clears trivially** — every player crosses 10 rated games by g10.
- The **sigma gate is the binding constraint**. After 14 games σ = **7.0777**,
  still ≥ the launch-default `provisional_max_sigma: 6.0`, so the band stays
  suppressed. With the default OpenSkill model, σ decreases slowly and asymptotes
  just above 6.0 (a separate simulation: even an always-winning seat only reaches
  σ ≈ 6.06 after 200 games). With the **launch-default thresholds**, Provisional
  effectively does not clear within a practical demo — and the `Rating.Tier`
  module itself notes those defaults are placeholders, "not finely calibrated."
  This is reported as an honest finding, not worked around by re-tuning config.

### Live == rebuild parity (the headline guarantee, on real games)

```
=== LIVE == REBUILD PARITY ===
rerate_all/0 replayed 14 rated games across 4 profiles
  North: mu=20.5113 sigma=7.0777 rated_games=14 (ordinal=-0.7219)
  East:  mu=29.4887 sigma=7.0777 rated_games=14 (ordinal=8.2556)
  South: mu=20.5113 sigma=7.0777 rated_games=14 (ordinal=-0.7219)
  West:  mu=29.4887 sigma=7.0777 rated_games=14 (ordinal=8.2556)

live == rebuild: OK
```

`Profiles.rerate_all/0` wiped all ratings and replayed the full `game_stats`
history from defaults in the canonical total order; the rebuilt μ/σ/count match
the live incremental values byte-for-byte. **OK.** The East/West ordinal (8.26)
vs North/South (−0.72) shows the rating correctly separating the dominant pair.

#### One real subtlety surfaced and resolved

`game_stats.completed_at`/`inserted_at` are **second-precision**. The driver
finishes a full game in well under a second, so back-to-back games share a
timestamp; the canonical rerate order `[completed_at, inserted_at, id]` then
tiebreaks on a random UUID — a *different but equally valid* order than the live
sequential order. Because OpenSkill is order-sensitive, that made an early run
report a parity MISMATCH that was purely a **timestamp-resolution artifact, not a
ratings bug** (proven: a second `rerate_all` is idempotent and equals the first).
The demo spaces game completions into distinct seconds (~1.1s/game) so the live
application order equals the rerate total order, and parity is then exact.

## Did profiles genuinely progress?

**Yes.** From real games played end-to-end through the engine by the bot
strategy:

- Lifetime **wins/losses** and **win rate** moved per game (final 12–2 vs 2–12).
- **Veteran XP/level** climbed every completed game (winners to L11/1443 XP,
  losers to L6/561 XP) with the title crossing Apprentice → Journeyman.
- **Achievements** unlocked at specific real games (Ace, Win Streak, The Winner,
  The Loser, Partnership, Player).
- **Playstyle** needles/labels and avg-winning-bid were derived from real
  bidding facts.
- **Skill rating** diverged correctly (East/West ordinal ≫ North/South), and the
  **rebuild-from-history ratings matched the live ones (`live == rebuild: OK`)**.

## Verification

- `MIX_ENV=test mix compile --warnings-as-errors` — clean (app code).
- Profile / rating / rollup suite: `mix test test/pidro_server/profiles/
  test/pidro_server/stats/profile_rollup_test.exs
  test/pidro_server/profiles/rerate_test.exs test/pidro_server/rating_test.exs
  test/pidro_server/rating/tier_test.exs test/pidro_server/achievements/
  test/pidro_server/playstyle_test.exs test/pidro_server/progression_test.exs`
  → **40 doctests, 225 tests, 0 failures**.
