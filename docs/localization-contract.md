# English / Swedish localization contract

User request: English and Swedish for Pidro, reuse the Unity translations,
work in Amp orbs on dedicated branches, keep branches rebased, follow v2 UI grammar.

Repositories and ownership:
- Frontend: marcelfahle/pidro-frontend, `feat/english-swedish-localization`.
  Own shared catalogs/settings/formatters/error presentation and current React Native
  app including its Expo web rendering. The separate old Vite packages/web client
  is outside this delivery; keep its shared-package compatibility/build intact.
- Backend: marcelfahle/pidro-backend, `feat/localized-error-contract`.
  Own additive machine-readable errors in current app-facing REST/channel paths.
  The game engine remains authoritative; localization cannot change game rules.
- Both branches already exist remotely. Fetch and track them; do not reset them.
- Other agents are working in these repositories. Preserve others' changes,
  resolve overlap on rebase, and incorporate new player-facing main-branch text.
- Keep one draft PR per repository against main, cross-link them. DO NOT MERGE,
  deploy, publish OTA updates, start release builds, or change production settings.

Error transport:
- Add optional top-level `error_code` (stable snake_case string) and `error_params`
  (object, default empty) to existing REST JSON error objects and Phoenix channel
  error reply payloads. Keep ALL existing fields/statuses/semantics unchanged.
- If a path already has stable codes, preserve those and map into the additive
  fields. Never derive a code by slugifying arbitrary English text or matching
  translated text. Carry codes from known failure branches/domain reasons.
- Establish a committed `docs/contracts/localization-errors.json` in backend:
  list code, param names/types, source endpoints/events, meaning. This is the
  shared manifest; frontend can read it from the backend feature branch with gh.
- Cover auth/guest/account/recovery, lobby/create/join/invite, gameplay/rematch,
  friends/profile flows currently exposed in the app. Inventory uncoded paths.
- Unknown domain failures use an explicit generic `action_failed` or
  `request_failed` code with no raw sensitive reason as an interpolation value.
- For field validation preserve existing field error structures; add structured
  field codes only where needed, documenting the exact additive shape and tests.
- Frontend prefers structured codes, maps known existing stable codes during
  rollout, otherwise uses a translated context-appropriate fallback. No raw
  server exception/English sentence should leak into Swedish presentation.
- Frontend must work safely with the currently deployed old backend. Add
  contract tests for old/new payloads and unknown codes in both languages.

Locale behavior:
- Persist `language: 'system' | 'en' | 'sv'` in the existing settings store.
  Existing installs default to system. Resolve device/browser preferred languages
  in order to supported en/sv, fallback en; both sv-FI and sv-SE use sv.
- Inject platform locale detection into platform-agnostic shared code. English
  fallback in production; missing Swedish keys/placeholders fail validation.
- Reactive language changes update all mounted UI, canvas labels, accessibility,
  notices and formatters without resetting navigation, socket, room, or game state.
  Resolve persisted language before rendering initial player-facing copy.
- Automatic follows OS changes on foreground; explicit choice wins. Locale is
  independent of ruleset. Never translate usernames, invite codes or protocol enums.
- Reuse existing i18n-js + expo-localization; avoid a new dependency or store.
  Catalogs/helpers in shared must remain consumable by the existing tsc dist build.

Release verification:
- Validate complete catalog parity and interpolation/plural consistency; test
  detection, persistence, migration, live switching, numbers/dates and fallback.
- Verify an English player and Swedish player can share the same game unchanged.
- v2 UI grammar at 390x844 and 844x390 plus smallest existing phone fixture and
  tablet; gameplay phases in both languages. Preserve at least 44px targets,
  font scaling, safe areas, readable wrapping and Swedish Å/Ä/Ö glyphs.
- Browser screenshots do not certify native safe areas. Report native checks
  separately and honestly if the orb cannot run a simulator.

Branch discipline:
- Fetch/rebase onto origin/main before implementation, at milestones, and before
  final review. Resolve conflicts semantically; never overwrite main's work.
- After rebase rerun relevant checks, push only your dedicated branch using
  --force-with-lease when necessary, and inspect CI on the latest commit.
- A local watcher may send rebase requests when main moves. Continue this same
  branch/PR, include new relevant strings, revalidate and leave PR open.
- Commit only owned files, no blanket git add. Follow repository commit identity
  conventions: Marcel Fahle <m.fahle@gmail.com>, no tool-credit trailers.
- Report actual evidence and limitations, not inferred green status.
