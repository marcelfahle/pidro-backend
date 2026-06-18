# Naming & Terminology — UI/UX reference

The settled naming + display guidance for the player-profile system. Use this to build the profile UI.

**Context:** Pidro is a classic partnership (2v2) trick-taking/bidding card game, played mostly in Swedish-speaking Finland and in Louisiana / California (Pedro/Cinch lineage). English UI, classic and legible, non-regional.

**Principle — four separate axes, four distinct voices.** A profile answers four different questions; each gets its own vocabulary and visual language so players never confuse them:

| Axis | Question | Voice | Has a number? |
|------|----------|-------|---------------|
| **Veteran** | how much you've played (dedication) | tenure words | yes — level 1–100 |
| **Skill** | how good you are (competence) | competence words | no — bands only |
| **Playstyle** | what kind of player you are (character) | an axis, Careful↔Aggressive | a 0–1 needle |
| **Mastery** | what you've accomplished | milestone badges | — |

Dedication uses *tenure* words and Skill uses *competence* words on purpose: the two ladders never share a word, so "dedication ≠ skill" reads at a glance.

**Display copy is owned by the frontend**, mapped from stable backend identifiers (Veteran: the level number; Skill: the tier atom). Names can change freely without touching the API, the database, or old clients.

---

## Veteran — dedication

Continuous level 1–100 (XP-driven, never resets), then an **uncapped Prestige** tail past 100. Named milestone titles attach at level thresholds. Use the **short** form in chips/HUD, the **full** form on the profile/detail/preview.

The curve is a re-paced power law — `threshold(level) = 80 · level²` — **data-calibrated** against Pidro 1 (~78 XP/game; top player 5.0M XP over 63,336 games). It replaces the old exponential curve where the top titles were mathematically unreachable. Every title is now reachable, and Hall of Famer is a genuine ~top-1% honor.

| Level | Full | Short | Total XP | ≈ games | Who reaches it* |
|------|------|-------|---------|---------|-----------------|
| 1 | Newcomer | Newcomer | 0 | 0 | everyone |
| 5 | Regular | Regular | 2,000 | ~25 | early dopamine |
| 10 | Old Hand | Old Hand | 8,000 | ~100 | early dopamine |
| 20 | Table Fixture | Fixture | 32,000 | ~410 | ~top 18% |
| 35 | Mainstay | Mainstay | 98,000 | ~1,260 | ~top 10% |
| 50 | Pillar of the Table | Pillar | 200,000 | ~2,560 | ~top 5% |
| 75 | Living Legend | Legend | 450,000 | ~5,770 | ~top 2% |
| 100 | Hall of Famer | Hall of Fame | 800,000 | ~10,250 | ~top 1% (~240 lifers) |

\* % of the ~27,500 Pidro 1 players who have any finished-game history (of ~70k accounts — the rest import as Newcomer).

**Prestige (past Hall of Famer):** every **500,000 XP** beyond the level-100 cap adds one Prestige star, uncapped. The all-time top player (5.0M XP) lands at **Hall of Famer ★8**; #30 (1.94M XP) at ★2. Render it as a small, quiet star/number on top of the Hall of Famer badge — it's a lifer flex, deliberately understated (dedication, not skill).

Backend gives you `veteran_level` (number), `veteran_xp`, `veteran_title`, `veteran_progress` (into / span, or "max"), `veteran_prestige` (integer, 0 below the cap), and `veteran_prestige_progress` (into / step toward the next star, or null). Lean on the **level number** (and the Prestige star) as the hero of this axis.

## Skill — competence

Broad bands, no number. The backend emits a stable atom; the **frontend maps it to the display name**, so renames are a one-line frontend change.

| Backend atom (API) | Display name |
|--------------------|--------------|
| `provisional` | Unrated |
| `bronze` | Novice |
| `silver` | Steady Hand |
| `gold` | Sharp |
| `platinum` | Cardsharp |
| `master` | Master |

`Unrated` = a player still being placed (their first ~10 rated games, or while uncertainty is high). It's the most common early state — give it a distinct "calibrating / being placed" treatment, not a low-rank one. Players never see the raw rating numbers (μ/σ stay server-side).

## Playstyle — character

The **Aggression Meter**: a needle from **Careful → Aggressive**, plus the player's **average winning bid**. Labels: **Careful · Balanced · Aggressive**. Backend gives a `0.0–1.0` needle + label + avg bid; until a player has bid in a few games it reports a "not enough data yet" state — design a neutral/empty meter for that.

## Mastery — achievements

Permanent once earned. Names carry over from Pidro 1 (continuity for returning players) except Partnership.

**Live now:**

| Name | Description |
|------|-------------|
| Player | Finish 10 games |
| The Winner | Win 5 games |
| Win Streak | Win 3 games in a row |
| Ace | Win while the opposing team finishes at 0 or below |
| The Loser | Finish a game with your team in negative points |
| Partnership | Win 10 games with the same partner |

**Coming soon** (in the backlog — PID-57…60, behind the per-hand-facts enabler PID-56):

| Name | Description |
|------|-------------|
| Homerun | Bid 14 and make it |
| Forcer | As dealer, be forced to bid 6 and still make it |
| Full House | Take all 14 points in a single hand |
| Unstoppable | Win a game in 5 hands or fewer |

Backend gives an earned list (name / description / tier / awarded_at) plus the active catalog with an `earned` flag for locked/unlocked rendering. Design slots for the "coming soon" four now; they light up later without a rebuild.

## Heritage — returning Pidro 1 players

Origin recognition for migrated accounts (distinct from freshly-earned Mastery — read it as "your history"):

`Played Pidro 1 · Founding Member · Pidro 1 Premium · Legacy Level · Legacy Accolades`

---

## Display guidance

### Keep Skill and Dedication visually distinct
The strongest lever is the number asymmetry — **Dedication has a level number, Skill has none.** Build on it:

- **Dedication** = an *accumulation* visual — progress ring/bar, service-stripes, a "membership card" feel. Brand-neutral palette; the **level number + title** are the hero.
- **Skill** = a *single emblem* (crest / medal / shield) that **swaps** as you rank up. Owns the competitive/metallic palette. **No progress bar** — it's a standing, not a journey.
- **Icons:** Dedication → time/place (table, seat, hourglass, calendar). Skill → merit (star, medal, crest).
- **Always caption the axis** ("Lvl 23 · Old Hand" under "Experience" vs "Sharp" under "Skill"). Never place two same-shaped badges side by side — co-located identical shapes are what cause the mix-up.

### The post-game moment
Every finished game shows a per-player "what changed" beat:
- **Always** (the guaranteed signal, win or lose): XP earned + any level-up — even a loss.
- **Ranked (4-human) games only:** the skill-tier move + any achievement unlocked.
- **Casual** leads with Veteran/Mastery, not a loud skill number.

### Mobile
Use the short title forms in chips/HUD; full forms on profile/detail/preview (table above). Skill bands are already short.

---

## Where each name lives

| Vocabulary | Source of truth | Display copy owned by |
|-----------|-----------------|------------------------|
| Veteran titles | backend config (level → title) | frontend (or use `veteran_title` as-is) |
| Skill band names | backend emits the atom | **frontend** (atom → label map) |
| Playstyle labels | backend atoms (`careful`/`balanced`/`aggressive`) | frontend |
| Achievement name/description | backend `Catalog` (in the payload) | backend (low churn) |
| Heritage labels | backend `Heritage` vocabulary | backend (low churn) |

One endpoint feeds all of it: `GET /api/v1/profile`.
