# Bot difficulty and evaluation

PID-7 builds on the Finnish rulebook and the deterministic engine from PID-134.
The rules engine still owns legality, scoring, dealing, dealer rob and kills.
Policies choose from a seat view; the server selects a profile and schedules it.

## Profiles

| Product name | Engine profile | Existing room API value | Behavior |
| --- | --- | --- | --- |
| Casual | `:casual` | `random` | Same bidding and partnership rules, conservative current-trick safety, no tracking of played/killed trumps |
| Regular | `:regular` | `basic` (default) | Existing full rulebook with public-card tracking |
| Regular compatibility alias | `:regular` | `smart` | Same as Regular; Strong is not implemented |

Casual recognises a safe winner when it is the Ace or no opponent with cards
remains to act. It feeds a safe partner, protects Fives, takes opposing points,
and avoids needless overtrumping. It does not inject random mistakes. Both
profiles use the same conservative bidding and trump-selection policy.

`Rulebook.decide(view, legal)` retains Regular behavior.
`Rulebook.decide(view, legal, :casual)` selects Casual. Both return a legal intent
and a sentence explaining it. They receive only `SeatView`, never private
opponent hands, the hidden deck or the authoritative chance stream.

`Strategy.resolve/1` owns the runtime mapping. The room's stored difficulty
reaches initial bots, disconnect substitutes, voluntary-departure replacements,
owner-filled vacancies, recovered substitutes and substitutes revived for a
rematch. Seated bots keep their profile on rematch. Scheduling and the separate
passive policy for connected-human timeouts are unchanged.

The mobile Solo entry currently requests `basic`. PID-9 covers exposing the
Casual/Regular choice. Keep the legacy API names until client and server agree
on a coordinated rename. PID-136 covers offline analysis for stronger play.

## Run evaluation

From `apps/pidro_engine`, using the pinned toolchain:

```sh
mise exec -- mix pidro.selfplay --pairs 1000 --seed 71 --a regular --b casual
mise exec -- mix pidro.selfplay --games 2000 --seed 1 --a rulebook --b random
```

**The CLI policy `random` is the genuinely random benchmark, not the room API's
legacy `random` value.** CLI `rulebook` aliases Regular.

`--pairs N` runs 2N games. Pair i uses engine seed `seed * 100_000 + i` twice:
first A sits North/South, then A sits East/West. Cuts and deck order match for
corresponding hand numbers. Decisions, trump choices and the number of hands
can diverge. Random-policy actions can diverge too. This is a paired experiment,
not a claim that the two game traces are identical.

The report includes wins, pair sweeps/splits, contracts (including forced dealer
bids), made/set rates, Five outcomes and decision times. Five counts refer to
completed tricks, including completed tricks in failed games:

- Captured: all Fives won, including the team's own Fives.
- Taken: an opponent's Five captured.
- Lost: an own Five captured by the opponents.

These are card counts, not points or automatic judgments of a tactical mistake.
Shared partnership expectations are pinned by scenario tests. Human play remains
necessary to assess whether the bot is a readable, trustworthy partner.

The CLI fails if any game crashes, stalls, exceeds its action cap, or produces
an illegal action. Inspect failures before interpreting win rates. Paired API
results include each pair's seed and winners for reproducibility. Non-timing
summaries are invariant under task concurrency. Elapsed-time samples include
seat-view construction and scheduler delays; they are not production latency
promises.

## Baseline and held-out procedure

1. Keep Regular behavior fixed as the reference. Existing 2,000-game
   rulebook-vs-random and four-rulebook contract gates remain unchanged.
2. Use development seeds (for example base 71) and scenario tests while changing
   a candidate. A reported bad move should become a seat-view regression case.
3. Reserve evaluation seeds before tuning. For this change, base 901 was first
   run only after both profiles and tests were implemented; no policy or bidding
   thresholds were changed in response to that result.
4. Compare on paired games and retain failures, contracts, Five outcomes and
   timing alongside wins. Do not lower gates to fit an observed result.
5. After inspecting a held-out result, use a fresh reserved set for future
   tuning claims. Never tune on base 901 and describe it as unseen afterward.

Recorded on 2026-09-25, engine based on main `58c7e8b`, OTP 29.0.3 /
Elixir 1.20.2-otp-29, with this PID-7 profile implementation:

| Metric | Regular | Casual |
| --- | ---: | ---: |
| Wins (2,000 games) | 1,033 (51.65%) | 967 (48.35%) |
| Pair sweeps (1,000 pairs) | 56 | 23 |
| Contracts | 8,615 | 8,597 |
| Made contracts | 6,607 (76.7%) | 6,581 (76.5%) |
| Fives captured | 17,404 | 16,982 |
| Opposing Fives taken | 6,024 | 5,827 |
| Own Fives lost | 5,827 | 6,024 |

921 pairs split. All 2,000 games completed; zero illegal moves, crashes, stalls
or caps. Regular has a modest measured advantage, not a demonstrated wide
Easy/Hard gap. Keep partner safeguards rather than manufacturing that gap.

## Simulator smoke check (manual, still outstanding)

Use the iOS simulator and local backend; a web build is not required. Start the
backend with `mise exec -- iex -S mix phx.server` from the backend root and use
the monorepo's `just ios local` command for the mobile app.

- Enter Solo, confirm readiness, and play through at least hands 1, 2 and 3.
  The current entry uses Regular. Verify dealer cuts appear only at game start,
  cards and dealer rotation remain correct, and trick/scoring windows remain
  readable.
- Observe partner behavior: feed a Five under a safe partner Ace, avoid spending
  a high trump over an already-safe partner, and retain Fives on unsafe tricks.
- Finish a game and rematch. The room and difficulty should stay the same.
- To exercise Casual before PID-9, create a room using the existing room flow
  with `bot_difficulty: "random"` and three bot seats. The UI may still call
  this legacy setting Random. Repeat the partner/rematch checks.
- Record the room, seat, hand/trick, cards, expected move and actual move when a
  decision looks wrong. Do not expose live hidden hands or chance in client
  payloads to diagnose it.

Automated tests cover bot profile selection, disconnect/recovery and rematch
propagation. This document does not claim a human simulator run was completed.
