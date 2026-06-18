# Ratings & Player Profiles — Build Progress

**Linear project:** [Ratings & player profiles](https://linear.app/boldvideo/project/ratings-and-player-profiles-14a215684946)
**Branch:** `mfahle/ratings-player-profiles` (worktree off `main`)
**Started:** 2026-06-07

## Goal (high level)

A relaunch-ready rating + player-profile system for Pidro 2 — four legible layers on a swappable estimator:

- **Veteran level (XP)** — dedication; carries Pidro 1's 1–100 level + reward-the-loser XP. Never resets.
- **Mastery** — achievements curated from the Pidro 1 set. Permanent.
- **Playstyle** — Aggression Meter + average winning bid. Character, not skill.
- **Skill tier** — OpenSkill (μ + σ) shown as broad bands. The honest win%. NEW.

Principles: dedication ≠ skill; estimator swappable (recompute from `game_stats`); every finished game pays one honest signal; skill only moves in multiplayer; migration carries dedication forward, skill re-earned.

## Method

Per ticket: **research → plan → implement**, each in a fresh context (delegated subagent), handed off via a markdown doc. Research → `docs/ratings-player-profiles/research/`. Plans → `docs/plans/`. One atomic commit per ticket on this branch; one PR for the whole project at the end.

## Ticket status

| # | Ticket | Milestone | Status | Commit |
|---|--------|-----------|--------|--------|
| PID-44 | Player profile + lifetime stats store | P1 Foundation | ✅ done | `3c839e2` |
| PID-45 | Integrate OpenSkill team rating (μ+σ) | P2 Rating engine | ✅ done | `8f78ad0` |
| PID-46 | Rerating job — replayable from history | P1 Foundation | ✅ done | `c341b5e` |
| PID-47 | Update ratings on completed games + bot policy | P2 Rating engine | ✅ done | `d25e9d7` |
| PID-48 | Skill tiers + provisional status | P2 Rating engine | ✅ done | `0b15880` |
| PID-49 | Veteran level (XP) + Heritage | P3 Progression | ✅ done | `8068298` |
| PID-50 | Mastery achievements (curate Pidro 1) | P3 Progression | ✅ done | `9f31640` |
| PID-51 | Playstyle: Aggression Meter + avg bid | P3 Progression | ✅ done | `b461652` |
| PID-52 | Post-game progression summary | P3 Progression | ✅ done | `d4e3102` |
| PID-53 | Pidro 1 → Pidro 2 progression carry-over | P4 Migration | ✅ done | `c308fb0` |
| PID-54 | Player profile API | P5 Surface | ✅ done | `9c0bac2` |
| PID-55 | Deferred (Quick Play, ranked queue, seasons) | — | 🚫 out of scope | — |

Plus one cross-cutting fix: **`2940d6a`** — isolate post-game persistence so a stats/profile write failure can't crash the supervised `RoomManager` (and removed a flaky full-suite sandbox-checkout race the heavier transaction exposed).

**All 11 in-scope tickets shipped. Final suite: 44 doctests, 670 tests, 0 failures, 1 skipped (started at 417).**

## Baseline

`mix test` before any change: **417 tests, 0 failures, 1 skipped** (Elixir 1.19 / OTP 28, Postgres).

## What shipped (architecture)

The system is four legible layers over the existing per-game `game_stats`, all hung off a single per-user `player_profiles` row and a small set of **pure** modules the server orchestrates:

- **`PidroServer.Profiles`** — the context. `player_profiles` row per user (lazy, race-safe), lifetime counters, and the completion seam `apply_completed_game/5` that — inside the existing `save_completed_game/4` transaction — updates counters, Veteran XP/level, rating (rated games only), achievements, and playstyle for every human participant, returning the per-player post-game summary. Everything is **rebuildable from `game_stats`** via `rebuild_from_history/1` + the ordered rating replay `rerate_all/0`/`rerate_incremental/0` (cursor in `rating_state`).
- **Skill** — `PidroServer.Rating` (pure, vendored `openskill` Weng-Lin facade, μ/σ swappable) → `Rating.Tier` (pure config-driven bands Provisional→Master, never exposes μ/σ). Moves only in 4-human games.
- **Veteran** — `PidroServer.Progression` (pure; the verbatim Pidro 1 XP curve + 50 win bonus, milestone titles) + `Progression.Heritage`. XP ticks on **every** game incl. single-player.
- **Mastery** — `PidroServer.Achievements.Catalog` (data-driven defs, 3 generic evaluators) + `player_achievements` table. 6 active, 4 dormant (need per-hand facts — documented follow-up).
- **Playstyle** — `PidroServer.Playstyle` (pure Aggression-Meter math) fed by a rebuildable `game_stats.player_bidding` JSONB built from engine events at save.
- **Surface** — `GET /api/v1/profile` returns the whole screen via a fail-closed allowlist (`Profiles.public_profile/1`), μ/σ stripped, OpenApiSpex-documented. Post-game, a per-player `progression_summary` is broadcast to each socket.

New tables: `player_profiles`, `player_achievements`, `rating_state`. New `game_stats` column: `player_bidding`. New dep: `openskill`. Per-ticket research + plans live in `docs/ratings-player-profiles/research/` and `docs/plans/2026-06-07-00*-*`.

## Decisions log

- One feature branch + one PR for the whole project; atomic commit per ticket (reviewable commit-by-commit). "All phases up until PR."
- **PID-45:** vendored `openskill` (MIT, pure Elixir) passed the compile+smoke gate on Elixir 1.19/OTP 28; wrapped behind the pure `Rating` facade so the estimator stays swappable. (It emits harmless compile-time `Math` warnings.)
- **PID-46/47:** one shared per-game `rate_game/3` seam → live updates and batch replay are identical **by construction**. Live updates do NOT advance the `rating_state` cursor (would serialise every game-over on one row lock); `rerate_incremental/0` is a backfill tool not to be run alongside live updates — `rerate_all/0` is the repair source of truth.
- **PID-47 bot policy:** v1 rates only games that started 4 distinct human seats; bot/single-player/3-human are unrated (falls out of `rated_game?/1`).
- **PID-50:** 6 achievements rebuildable from `game_stats` shipped active; 4 (Homerun/Forcer/Full House/Unstoppable) need per-hand facts not persisted → defined as **dormant** data entries, activatable later by persisting game facts (no engine/schema churn crammed in here). Pidro-2 thresholds re-derived (game to 62), not copied from Pidro 1.
- **PID-53:** Pidro 2 has **no entitlement model**, so legacy premium is a display-only Heritage flag (real entitlement out of scope); skill is left fully Provisional on arrival (no μ seed); the auth/claim/website-bridge flow and legacy-blob parsing are separate — this ticket is the pure mapping against a defined `LegacyProgression` contract.
- **Hardening (`2940d6a`):** post-game persistence is isolated from `RoomManager` liveness — a stats write failure logs and the game still finishes for players.
- **PID-55** explicitly out of launch scope per the ticket — not implemented.
- **Post-launch tuning (2026-06-08):** tier provisional gate switched to OR-clear (`ced2c7d`) so bands actually clear; Partnership achievement redefined to "win 10 with the same partner" (`af422ab`); Veteran XP curve re-paced to `80·level²` (L100 caps at 800k) + uncapped Prestige (`e69879`), data-calibrated against the Pidro 1 `xpoints` distribution (top player 5.0M XP/63k games → Hall of Famer ★8). The four dormant achievements are ticketed: PID-56 (per-hand-facts enabler) → PID-57/58/59/60. Naming + curve + display guidance live in `NAMING-AND-TERMINOLOGY.md`.
