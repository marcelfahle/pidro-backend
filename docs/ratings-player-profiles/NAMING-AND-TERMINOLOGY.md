# Naming & Terminology — working doc

Reference for the UX pass on the Ratings & player-profiles system. Captures **what we call things today**, the **known collisions/issues** (kept on purpose, to think further), the **Partnership achievement problem**, the **dormant achievements** we want soon, and **2–3 alternate naming sets** to react to.

Audience context: Pidro is a classic partnership (2v2) trick-taking/bidding card game, played mostly in **Swedish-speaking Finland** and in **Louisiana / California** (Pedro/Cinch lineage). English UI. **Not** going regional/Nordic-themed for now — keep it classic and legible.

**Key fact for editing:** none of the game logic depends on the display strings. Stable identifiers are the atoms/keys (`:bronze`, `:winstreak`, `:careful`, …); the human-readable names are config (Veteran titles), data (`Catalog` name/description), or pure UI. Rename anything freely without touching rules.

---

## 1. Current naming inventory (as shipped)

### Veteran level — milestone titles *(dedication: "how much you've played"; levels 1–100)*
Source: `config/config.exs` → `PidroServer.Progression` `titles`. **All placeholders.**

| Level | Title |
|------|-------|
| 1 | Rookie |
| 5 | Apprentice |
| 10 | Journeyman |
| 20 | Veteran |
| 35 | Expert |
| 50 | Master |
| 75 | Grandmaster |
| 100 | Legend |

### Skill tier — ranked bands *(the honest "how good are you")*
Source: `PidroServer.Rating.Tier`. **Placeholders (generic esports ranks).**

`Provisional → Bronze → Silver → Gold → Platinum → Master`

### Playstyle *(character)*
Source: `PidroServer.Playstyle`. **Placeholders, but a good fit.**

- Meter: **Aggression Meter**, axis **Careful ↔ Aggressive**
- Labels: `Careful · Balanced · Aggressive`

### Mastery — achievements *(name → description)*
Source: `PidroServer.Achievements.Catalog`. **Names inherited from Pidro 1** (continuity) except Partnership (new).

Active at launch:

| Name | Description |
|------|-------------|
| Player | Finish 10 games |
| The Winner | Win 5 games |
| Win Streak | Win 3 games in a row |
| Ace | Win while the opposing team finishes at 0 or below |
| The Loser | Finish a game with your team in negative points |
| Partnership | Win a full 4-player game alongside your partner *(new — see §3)* |

Dormant (defined, not yet earnable — see §4): Homerun, Forcer, Full House, Unstoppable.

### Heritage *(returning Pidro 1 players)*
Source: `PidroServer.Progression.Heritage`.

`Played Pidro 1 · Founding Member · Pidro 1 Premium · Legacy Level · Legacy Accolades`

---

## 2. Known collisions & issues *(kept on purpose — decide later)*

1. **"Master" collision.** "Master" is both a **Veteran title** (level 50) and the **top Skill tier**. A player could be "Veteran: Master" + "Skill: Bronze" — two unrelated "masters." Confusing.
2. **Veteran ladder reads as skill.** Rookie → Apprentice → Journeyman → Expert → Grandmaster sounds like a *competence* ladder, but it's **dedication/time**. This undercuts the whole "dedication ≠ skill" premise — the two ladders should *sound* different. Fix direction: Veteran = **tenure/time** words; Skill = **competence** words. (Both alternate sets below do this.)
3. **"Veteran" overloaded.** It's the name of the whole layer *and* a milestone title (level 20).
4. **Esports tiers vs. a classic card game.** Bronze→Platinum→Master is very *League of Legends*. The Pidro base is older/traditional in two regions — generic ranks may read off-brand. (Status quo kept as an option; alternates offer card-competence ladders.)
5. **Borrowed metaphors in legacy achievements.** "Homerun" (baseball), "Full House" (poker), "Ace" (also a literal Pidro card + a scoring card, so the badge name overlaps the card). They're authentic to Pidro 1 (continuity argument to keep), but cross-game metaphors. "Forcer" + the forced-6 rule, by contrast, are beautifully Pidro-specific.

---

## 3. The Partnership achievement problem ⚠️

Current: **Partnership — "Win a full 4-player game alongside your partner."**

**Problem:** Pidro games are *only* won in partnerships (2v2). Every win is "alongside your partner," so this is tautological — it's effectively "win one proper 4-human game," which says nothing partnership-specific and overlaps with *The Winner*. The wording communicates nothing.

A real partnership achievement should measure something about *the partnership itself*. Options (all computable — `game_stats.player_results` records both teammates' user_ids + team, so **your partner per game is derivable**: the other player on your team; correcting an earlier note that "pairing identity isn't modeled"):

- **Option A — loyalty/chemistry:** "Win N games with the **same** partner." (group your wins by partner id; award at N). Genuinely about a partnership. *Recommended.*
- **Option B — versatility:** "Win games with N **different** partners."
- **Option C — a partnership *feat* in a single game** (needs per-hand data → dormant tier): e.g. "Both partners win a bid and make it in the same game," or "Set up your partner" (a partner-assist play).

Decision needed: pick A/B/C (or rename + redefine). Until then, the current `partnership` def is a placeholder.

---

## 4. Dormant achievements — want these soon

Defined as data (`status: :dormant`), not yet earnable. They need **per-hand facts persisted** at game completion (the engine's `events` log has the data live, but `game_stats` doesn't store per-hand/per-player bid+points yet — a small, separable follow-up: add a per-game facts column + writer, then flip these to `:active`). Worth a ticket.

| Name | Description | Needs |
|------|-------------|-------|
| Homerun | Bid 14 and make it | per-player winning-bid amount + hand outcome |
| Forcer | As dealer, be forced to bid 6 and still make it | forced-bid flag + hand outcome |
| Full House | Take all 14 points in a single hand | per-hand points per team |
| Unstoppable | Win a game in 5 hands or fewer | hand count at game end |

(Note: the Playstyle meter already persists a slice of per-player bidding data — `game_stats.player_bidding` — so part of the plumbing exists.)

---

## 5. Alternate naming sets

Each set covers **Veteran ladder** (tenure) + **Skill tiers** (competence) in one consistent voice, and **resolves the Master collision** by keeping the two ladders in different word-pools. Playstyle + Provisional-label options at the end. These are starting points to react to, not final.

### Set 0 — Status quo (for comparison)
- Veteran: Rookie / Apprentice / Journeyman / Veteran / Expert / Master / Grandmaster / Legend
- Skill: Provisional / Bronze / Silver / Gold / Platinum / Master

### Set A — "Card room" *(classic, warm, table-culture)*
Veteran = how long you've been at the table; Skill = card competence.

| Level | Veteran title |
|------|---------------|
| 1 | Newcomer |
| 5 | Regular |
| 10 | Old Hand |
| 20 | Table Fixture |
| 35 | Mainstay |
| 50 | Pillar of the Table |
| 75 | Living Legend |
| 100 | Hall of Famer |

Skill: **Unrated → Novice → Steady Hand → Sharp → Cardsharp → Master**

### Set B — "Plain & legible" *(neutral, minimal theme, instantly clear)*
Veteran = amount played; Skill = plain competence.

| Level | Veteran title |
|------|---------------|
| 1 | Newcomer |
| 5 | Casual |
| 10 | Frequent |
| 20 | Regular |
| 35 | Seasoned |
| 50 | Stalwart |
| 75 | Devotee |
| 100 | Legend |

Skill: **Unrated → Novice → Average → Skilled → Expert → Master**

### Set C — "Characterful" *(a little personality / Pidro flavor)*
Veteran = playful tenure; Skill = card-shark flavor.

| Level | Veteran title |
|------|---------------|
| 1 | Greenhorn |
| 5 | Dealt In |
| 10 | Regular |
| 20 | Card-Carrier |
| 35 | Old Hand |
| 50 | Table Boss |
| 75 | Big Shot |
| 100 | Legend of the Felt |

Skill: **Unrated → Rookie → Contender → Sharp → Shark → Kingpin**

### Playstyle label options *(axis stays Careful ↔ Aggressive)*
- Status quo: Careful / Balanced / Aggressive  *(good fit; bidding aggression is a real Pidro axis)*
- Alt 1: Cautious / Measured / Bold
- Alt 2: Conservative / Even / Daring

### "Provisional" label options
Provisional / Unrated / Calibrating / Placement / Settling In

---

## 6. Where each name lives (for when decisions land)

| Vocabulary | File | Change type |
|-----------|------|-------------|
| Veteran titles | `config/config.exs` → `PidroServer.Progression` `titles` | config edit (no code) |
| Skill tier display | UI / serializer (atoms `:bronze`… stay) | display map (no rules) |
| Playstyle labels | `PidroServer.Playstyle` (atoms) + UI | atoms + display |
| Achievement name/description | `PidroServer.Achievements.Catalog` | data edit |
| Heritage labels | `PidroServer.Progression.Heritage` `@vocabulary` | data edit |

---

## 7. Open decisions

- [x] Pick a naming set → **Set A for both** Veteran + Skill (2026-06-08). Master collision resolved (Veteran = tenure words, no "Master"; Skill keeps "Master" at top).
- [x] Redefine the Partnership achievement → **Option A: "Win N games with the same partner"** (see §8).
- [x] Schedule the per-hand-facts follow-up → ticketed: **PID-56** (enabler) blocks **PID-57 Homerun · PID-58 Forcer · PID-59 Full House · PID-60 Unstoppable**.
- [ ] Veteran "long names on mobile" → short/full forms (see §9); confirm short forms.
- [ ] Keep vs. rename the borrowed-metaphor legacy achievements (Homerun/Full House/Ace) — tracked on PID-57/59.
- [ ] Choose Playstyle labels + "Provisional" label (defaults stand for now).
- [ ] Visual differentiation of Skill vs Dedication (see §10) — design.

---

## 8. Decision: chosen names (2026-06-08)

**Set A** is the chosen direction for both ladders. The two ladders deliberately use different word-pools so they never collide and the dedication≠skill split is reinforced.

- **Veteran (dedication, tenure words):** Newcomer · Regular · Old Hand · Table Fixture · Mainstay · Pillar of the Table · Living Legend · Hall of Famer
- **Skill (competence words):** Unrated · Novice · Steady Hand · Sharp · Cardsharp · Master
- **Partnership achievement → "Win N games with the same partner"** (loyalty/chemistry). N is config-tunable; launch default **10**. Computable from `game_stats.player_results` (your partner = the other player on your team; group wins by partner id). Replaces the tautological "win alongside your partner."

## 9. Mobile: short vs full title forms

Concern: full tenure titles ("Pillar of the Table", "Hall of Famer") are long for tiny screens. Plan: store **both** a short and a full form; UI shows the **short** form in chips/badges/HUD and the **full** form on the profile detail / tab / preview.

| Level | Full (detail/profile) | Short (chip/HUD) |
|------|------------------------|------------------|
| 1 | Newcomer | Newcomer |
| 5 | Regular | Regular |
| 10 | Old Hand | Old Hand |
| 20 | Table Fixture | Fixture |
| 35 | Mainstay | Mainstay |
| 50 | Pillar of the Table | Pillar |
| 75 | Living Legend | Legend |
| 100 | Hall of Famer | Hall of Fame |

Implementation: the `titles` config becomes `level => %{full:, short:}` (or two maps); `Progression.title_for_level/1` returns full, add `short_title_for_level/1`. Small, no rules impact. (Skill bands are already short; no short-form needed there.)

## 10. Visual differentiation — keeping Skill and Dedication apart

The risk is two badges that *look* the same sitting side by side. Ideas to make the two axes instantly distinct:

- **Lean on the number asymmetry.** Dedication has a **level number 1–100** as its hero; Skill has **no number** (bands only). Always show the number for dedication, never for skill. That alone separates them.
- **Different visual grammar:**
  - *Dedication* = **accumulation** motif — a progress ring/bar, chevrons, or service-stripes that visibly *build up*; a "membership card" feel. Brand-neutral color; the **number + title** are the focus.
  - *Skill* = **a single emblem** (crest / medal / shield) that **swaps** as you rank up; owns the competitive/metallic palette (tier colors). No progress bar — it's a standing, not a journey.
- **Iconography:** Dedication → time/place (table, seat, hourglass, calendar). Skill → merit (star, medal, crest).
- **Always label the axis:** "Lvl 23 · Old Hand" (with a small "Experience"/"Dedication" caption) vs. "Sharp" (caption "Skill"). Never rely on the badge alone.
- **Separate cards/rows**, not twin side-by-side badges of the same shape — co-location of identical shapes is what creates the confusion.
- **Provisional = a distinct "calibrating" state** (ghost/dashed crest, "Unrated · placing"), since it's the most common early state players will see.
