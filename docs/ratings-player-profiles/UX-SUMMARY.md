# Ratings & Player Profiles — UX Summary

A plain-language guide to what the player sees and what it means. For design/product. (Engineering detail lives in `00-PROGRESS.md`.)

## The big idea

A player's profile answers four different questions, kept deliberately separate so none of them lies:

1. **How much have you played?** → **Veteran level** (dedication)
2. **What have you accomplished?** → **Mastery** (achievements)
3. **What *kind* of player are you?** → **Playstyle** (character)
4. **How good are you, honestly?** → **Skill tier** (the new bit)

The golden rule: **dedication is not skill.** A player who's logged 1,000 games is a high Veteran level even if they lose a lot. A sharp newcomer can be a high Skill tier at Veteran level 3. We show these as two separate things and never blend them into one "score." This is the one honest axis Pidro 1 never had.

---

## The four layers

### 1. Veteran level — "how much you've played"
- A 1–100 level driven by XP, carried over from Pidro 1. **Never resets.**
- **You earn XP every game, win or lose** — your end-of-game points become XP, winners get a bonus on top. This is deliberate: losing still moves you forward (anti-rage-quit). A losing player should never see "you got nothing."
- Has **milestone titles** at certain levels (e.g. a name that changes as you climb) — design owns the actual title words; the system just picks "the highest title you've reached."
- Also shows progress toward the next level (how far into the current level you are).
- **Ticks everywhere**, including single-player vs bots — so "play immediately" onboarding still rewards you.

### 2. Mastery — achievements
- A tight, curated set of **measurement-based** badges (not completion-spam), **permanent once earned.**
- Live at launch: *Player* (finish 10 games), *The Winner* (win 5), *Winstreak* (3 in a row), *Ace* (win a shutout — opponent ≤ 0), *The Loser* (lose with a negative score — keep the humour), *Partnership* (win a full 4-human game).
- Defined later (need richer game data first): *Homerun* (bid 14 and make it), *Forcer*, *Full House*, *Unstoppable*. Design can plan slots for these now; they'll light up later without a rebuild.
- UX gives each badge a name + description; the system tells you which are earned (with a date) and which are still locked.

### 3. Playstyle — the Aggression Meter
- A **needle from Careful → Aggressive**, plus your **average winning bid**. It says what *kind* of player you are — neither skill nor dedication, pure character/flavour.
- Driven by how often you win the bidding. The center of the needle is the natural 4-player baseline; very cautious bidders peg Careful, very pushy bidders peg Aggressive.
- The system hands UX a **0.0–1.0 needle position** + a label (`careful` / `balanced` / `aggressive`) — so the dial art is a straight mapping.
- **New players show "not enough data yet"** (a flag) until they've bid in a few games — design a neutral/empty state for the meter.

### 4. Skill tier — the honest answer
- Broad bands: **Provisional → Bronze → Silver → Gold → Platinum → Master.**
- Players **never see a raw number** (no μ/σ, no "1,247 MMR") — just the tier + state. This is intentional: bands feel good, precise numbers invite anxiety and grinding.
- **New players are "Provisional"** until the system is confident (a handful of games). Design a distinct provisional look — it's a first impression a lot of players will see.
- **Skill only moves in real 4-human multiplayer games.** Single-player and games with bots filling seats do **not** affect your tier. (So a casual screen should lead with Veteran/Mastery, not the skill band.)

---

## The post-game moment ("what changed")

Every finished game ends with a **per-player "what changed" summary** so the results screen is **never empty**:

- **Always present (the fallback):** XP earned this game + whether you leveled up (+ title change). Even a loss shows this.
- **Only on ranked (4-human) games:** your skill tier move — `up` / `down` / `none`, and whether you cleared provisional.
- **Any game:** achievements unlocked this round.

Design guidance baked in: **casual games lead with the Veteran/Mastery beat, not a loud skill number.** The level-up celebration is the keeper moment from Pidro 1 — every player gets *something* honest to feel at the end.

Each player receives **their own** summary (it's pushed individually), so the screen is personal, not a shared scoreboard.

---

## Returning Pidro 1 players (migration)

When a Pidro 1 player comes across, they **land already looking like themselves**:
- Their **Veteran level + XP carry over** (old XP is kept — it was always dedication).
- Old badges show up as **Heritage** (origin recognition: "played Pidro 1", founding ribbon, legacy accolades) — a distinct, nostalgic display, separate from freshly-earned Mastery.
- Premium status shows as a Heritage flag (a real entitlement system is a later, separate piece of work).
- **Skill starts Provisional** — it's re-earned by playing, never imported. A veteran of the old game still has to prove their tier.

Design a **Heritage section** on the profile (badges/ribbons from the old game) that reads as "your history," visually distinct from current-game progress.

---

## Edge states to design for

- **Brand-new player:** Veteran level 1, no achievements, Playstyle "not enough data", Skill "Provisional." This is the most common first-load — make it feel inviting, not empty.
- **Provisional skill:** show it as "still figuring you out," not a low rank.
- **Single-player / vs bots:** XP, level, achievements all move; skill tier explicitly does **not** — don't show a skill change on these results screens.
- **Migrated player:** Heritage populated, Veteran carried, Skill provisional.

---

## What the screen actually gets (data contract)

One endpoint — `GET /api/v1/profile` — returns everything a profile screen needs, in one call:

```
{
  "user_id", "games_played", "wins", "losses", "win_rate",
  "first_seen_at", "account_age_days",
  "skill":     { "tier": "provisional|bronze|silver|gold|platinum|master",
                 "provisional": true|false },
  "veteran":   { "level", "xp", "title", "progress": [into, span] | "max" },
  "heritage":  [ { "key", "label", "value" }, ... ],
  "playstyle": { "bidding_win_rate", "aggression_needle" (0–1),
                 "aggression_label", "aggression_insufficient", "avg_winning_bid" },
  "achievements":         [ earned badges, with dates ],
  "achievements_catalog": [ all active badges, earned: true|false ]
}
```

Raw skill internals (μ/σ) are **never** in this payload by design. Note `null`/empty states: `avg_winning_bid` and `bidding_win_rate` are null when there's not enough data; `aggression_insufficient: true` is the meter's "no data yet" flag; `progress: "max"` means level 100.

The post-game summary arrives separately as a `progression_summary` message per player (the "what changed" block above).

---

## One-paragraph version (for a brief)

Pidro 2 profiles show four separate things so none of them lies: a **Veteran level** for how much you've played (XP every game, win or lose, never resets — carried from Pidro 1), **Mastery** badges for what you've accomplished (permanent), a **Playstyle** Aggression Meter for what kind of player you are (Careful↔Aggressive), and an honest **Skill tier** (Provisional→Master, bands not numbers, moves only in real multiplayer). Every game ends with a personal "what changed" beat that always at least shows XP/level, so the results screen is never empty. Returning Pidro 1 players keep their dedication (level + Heritage badges) but re-earn skill from Provisional.
