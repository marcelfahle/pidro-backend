# Bot catalogue — implementation evidence

Review-ready backend work on `admin-ops/bot-catalogue`, based on origin/main.
No main push, PR, merge, deployment, OTA, native dependency, or CI changes.
GameDetailLive/card_components, diagnostics, archives and engine rules untouched.
The [contract](bot-catalogue-contract.md) is the client/Watch integration source.

## Verified behavior

- Real authenticated browser: sign in; seeded Antti/Jocke/Marcel faces loaded;
  edit/save Marcel; create fourth profile Sisu using a PNG rasterization of
  the actual Jocke artwork; normalized JPEG loads; second open admin tab sees
  Sisu without reloading; edit/disable Sisu and select existing Random strategy.
- Browser: switching profiles replaces editor values correctly. A stale-form
  regression first failed without the selection guard, then passed with it.
  390px Chromium viewport has scrollWidth 390 (no horizontal overflow).
- Eight focused catalogue/LiveView regressions cover auth denial and revoked
  sessions, add/edit/disable, public field allowlist, forged strategy/URL input,
  signature/size rejection, JPEG serving and invalid versions, retained upload
  after validation failure, four distinct real bot seats, zero-enabled fallback,
  unknown ID fallback, active-game profile edits, process reattachment, human
  reconnect and rematch stability, and no bot user/rating-profile insertion.
- Four-seat proof uses the same empty-table setup as the existing admin preset,
  then starts four actual BotPlayers in a room created before the fourth profile.
  Rematch proof runs the real room/game processes but signals the existing
  game-over event; it is not a new full-playthrough scoring proof.

## Commands and results

Run from the umbrella root using the pinned `mise exec --` toolchain:

| Check | Result |
|---|---|
| `mix precommit` on final source | exit 0; engine 911 passed, 1 skipped; server 1965 passed, 1 skipped |
| Included format/strict compile/Hex audit | passed; no retired/security-advisory packages |
| Included diff-scoped Credo | added no issues |
| Included Dialyzer | passed; 56 existing filtered warnings, no ignore-file changes |
| Catalogue + admin LiveView tests | 8 passed |
| Earlier catalogue + game/lobby channel targeted run | 114 passed (before the additional stale-form regression) |
| `mix do --app pidro_server assets.build` | passed |
| `git diff --check` | passed |

Initial full runs found two expected old `avatar_url == nil` assertions; they
now assert the additive portrait URL/profile contract. No checks were weakened.
Existing engine negative-case warnings and server fixture/teardown logs remain.
No frontend code changed, so bun/shared/mobile checks belong to the client orb.
No native device execution is claimed.

## Migration, concurrency and independent review

In disposable local database `pidro_bot_catalogue_safety`, ran full migrations,
rolled back only `20261022120000`, booted final application code without that
table, and started a real rulebook bot: `PRE_MIGRATION_BOOT_AND_BOT_OK`.
Reapplied the migration twice: `Migrations already up`, exactly three defaults,
`IDEMPOTENT_THREE_DEFAULTS_OK`. No production migration was run.

A controlled scratch check suspended the catalogue owner, queued a refresh,
disabled a profile in the database, then resumed the owner. It read the latest
DB state: `QUEUED_REFRESH_READS_LATEST_DB_OK`. Scratch tooling was removed.
Cross-node invalidation is source-reviewed, not exercised on a multi-node cluster.

Independent migration/socket/upload review found two P2 issues: stale snapshot
publication and consuming valid uploads after failed persistence. Both were
fixed; follow-up review found them resolved and ran the seven then-current
catalogue tests successfully. Browser verification then caught the automatic
upload start and selection/width issues; those are fixed and included in the
final passing checks. The coordinator still owns combined integration review.

Migration is additive: only bot_profiles and its strategy constraint; no user,
rating, game or room table changes. Seeds preserve all three legacy IDs with
ON CONFLICT DO NOTHING. Down drops catalogue data/uploads: back them up before
any production schema rollback. Migrate before opening administration; if code
starts first, restart/open admin after migration to refresh fallback snapshots.

## Artifacts and limitations

Artifacts are in the source orb, not Git. Source thread:
https://ampcode.com/threads/T-01a163d1-2817-7499-a8c3-705bd829db3e
The coordinator can use `download_thread_file` with that thread and these paths:

- `.amp/in/artifacts/bot-catalogue-seeded.png` — original seeded list.
- `.amp/in/artifacts/bot-catalogue-edit.png` — final Marcel editor.
- `.amp/in/artifacts/bot-catalogue-fourth.png` — uploaded fourth profile, disabled.
- `.amp/in/artifacts/bot-catalogue-narrow.png` — final 390px viewport (not a phone).
- `.amp/in/artifacts/bot-catalogue-edit.mp4` / `.loop.webp` — inspected pointer
  tour, edit/save Marcel, then switch to Sisu with correct independent values.
- `.amp/in/artifacts/bot-catalogue-public.json` — safe real local API response.
- `.amp/in/artifacts/bot-catalogue-validation.txt` — sanitized decisive output.

All final captures were inspected, including a recording contact sheet. The
temporary authenticated preview service was stopped; no live preview is promised.
Catalogue changes update catalogue admin views, not game/lobby roster events;
normal subsequent snapshots or catalogue fetches show new profile presentation.
Only the current uploaded image is retained; obsolete image URLs return 404.

Old frontend source accepts UUID personas without a parser/render crash but
shows a background-only face, ignoring bot avatar_url. Legacy faces are intact.
The client orb must implement the contract's metadata/unknown-image fallback
once; subsequent server-side profiles need no native build. This old-client
assessment is source-derived, not a native device test.
