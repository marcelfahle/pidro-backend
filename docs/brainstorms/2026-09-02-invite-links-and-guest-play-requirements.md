---
title: Invite links, guest play and deep linking — requirements
date: 2026-09-02
status: draft requirements — next step is /ce-plan per phase
research: docs/research/2026-09-02-invite-links-deep-linking-guest-play-landscape.md
related: Linear PID-34 (open bot seat to strangers), PID-29 (seat state machine), PID-31 (owner promotion), PID-32/36 (lobby categories)
---

# Invite links, guest play and deep linking

## The one-paragraph version

A host taps **Invite** in the waiting room and gets a short link, `https://www.pidro.online/j/7KQ4M2XB`,
plus a share sheet. Anyone who taps it lands at that table: if the app is installed the OS opens
it straight into the table; if not, a server-rendered landing page sends them to the store and
the app picks the invite back up on first launch (deterministically on Android, best-effort plus
a "type the code" fallback on iOS); on desktop the page hands off to a phone by QR until web join
ships in phase 6. Nobody registers to
play. An invitee types a display name, becomes a **guest user row** with a real id, claims a
seat, plays the whole game, and is asked to "save your result" only after the first game ends.
Saving is an in-place upgrade of the same row, so the game they just won stays theirs. One link
per table, not per seat. The host steers seating with a *hint* on the invite and with seat
controls in the waiting room.

## Decisions, including where I push back on the brief

| # | You proposed | Recommendation | Why |
|---|---|---|---|
| D1 | Invite to a seat *or* to the table, let the host pick | **One link per table.** The invite carries an optional *seat hint* (partner seat, or a team). The server tries the hint and falls back to any open seat. Host gets "Invite partner" and "Invite anyone" from the same mechanism. | Every successful card platform (Board Game Arena, Trickster, CardzMania, Tabletopia) uses a table link with seat picking; only Bridge Base Online binds seats, and it is the clunkiest. Per-seat links create "which link did I send whom" and dead seats when a friend cannot come. A group chat gets *one* link. |
| D2 | A short code "or whatever" | **Invite code ≠ room code.** 8 chars Crockford Base32 (`0-9A-Z` minus `I L O U`), shown `7KQ4-M2XB`, case-insensitive, generated with `:crypto.strong_rand_bytes`, stored as an `invites` row. The 4-char room code stays internal. | Phase 0 secured room-code generation and lookup, but room codes remain short, ephemeral lobby identifiers rather than revocable, countable, durable invite identities. Never put one in a share link. |
| D3 | Link expires "after some time, maybe" | **Multi-use, bound to the table's life** (dies when the table closes or starts and fills), hard ceiling 24 h, host can revoke/regenerate, and a code is **never reissued**. | Chat apps fetch links before anyone taps (WhatsApp fetches while you type), so single-use links break. Expired Discord codes were re-registered by attackers in 2025 to deliver malware; tombstone, never recycle. |
| D4 | Register after the first game | **Yes, and the guest must be a real `users` row from the first tap.** Upgrade = `UPDATE` the same row (email, password, `guest=false`). Prompt once at game over, skippable, never blocks. | Chess.com and Lichess keep guest games out of accounts, so their guests register *before* playing, which defeats the point. Our stats tables reference users by bare UUID with no foreign keys, so an in-place upgrade carries every game, the rating, XP and achievements with zero migration. Apple 5.1.1(v) also requires in-app deletion for guests. |
| D5 | "Maybe even the web later" | **The web landing page ships in v1 and is the reliable path.** Phoenix renders `GET /j/:code` (HTML + Open Graph). `pidro.online` proxies `/j/*` and `/.well-known/*` to Phoenix. "Play in browser" can wait, but is cheap because the web client exists. | Universal Links fail in Instagram/Messenger/TikTok/Telegram in-app browsers, when pasted into the address bar, and for anyone who once chose "Open in Safari". Every one of those lands on the web page. Previews need server-rendered OG tags; a Vite SPA cannot produce them. |
| D6 | "If not installed, go to the store and drop you in with the same link" | **Android: yes, deterministic** (Play Install Referrer). **iOS: no first-party way exists.** Use a Phoenix-owned, 30-minute probabilistic matcher with hard deletion, and always include the code in the share text with a "Have a code?" screen on first launch. Measure the automatic match rate; do not assume a vendor claim. | Apple offers nothing; SKAdNetwork gives no destination; App Clips are a separate binary with poor Expo support. A self-hosted matcher avoids sending visitor device data to a third party, while Branch/AppsFlyer solve ad attribution we do not need yet at substantial cost. |
| D7 | "It should open the app right away" | **Universal Links + App Links on `pidro.online`**, custom scheme `pidro-mobile://` only as the landing page's fallback button. | Schemes can be squatted by any app; domain-bound links cannot. `pidro.online` is already associated with `LSFK7YF82G.com.oneapps.pidro` (the AASA is live and cached by Apple's CDN for the legacy app), so we add a path, not a domain. |
| D8 | (not asked) Can guests invite? | **Yes.** Guests can play, rejoin, create tables and invite. Registration unlocks: showing up in leaderboards/profile history, a second device, friends (future), ranked (future). | The loop is invite → play → invite. Apple lets us require accounts for inviting, but we would be cutting our own k-factor. |
| D9 | (not asked) Prerequisites | Rate limiting (Hammer), CSPRNG room codes with collision check, `guest` no longer mass-assignable, `.well-known` served by Phoenix. | Completed in phase 0 / PR #19 because guest creation without these controls would be an open account faucet. |

## User flows

### Host
1. Creates a table (existing flow; bots optional). Waiting room now shows **Invite** as the primary action and the four seats.
2. Taps Invite → chooses *Invite partner* / *Invite anyone* (optional: type the friend's name as a label). Server mints an invite bound to the room, with `seat_hint`.
3. Share sheet (`expo-sharing` / `navigator.share`) with prefilled text, plus Copy link, Copy code, QR (for the same-room case).
4. Watches seats fill in real time ("Anna is joining…" the moment the invite is redeemed, before the socket join). Can move a player to another seat, lock the table (no more joins), kick, or regenerate the link.
5. Fourth seat filled → game starts automatically (today's behavior). Invite becomes inactive. After the game, "Play again" mints a new invite for the new room; the old link's landing page says "Marcel's table moved" and points at the new one while the host is still around.

### Invitee
1. Taps the link in WhatsApp / iMessage / SMS / email / Telegram.
2. Resolution (details in the platform matrix):
   - App installed and the OS honors the link → app opens on `/join/7KQ4M2XB`.
   - Otherwise → landing page: "Marcel invited you to a Pidro table · 2 of 4 seats taken". Buttons: **Open app** (scheme / `intent://`), **Get the app** (store). (**Play in browser** is deferred with web join, see answered question 2; desktop shows the store buttons and a QR code.)
   - Not installed → store → first launch → app resolves the pending invite (Install Referrer / the Phoenix deferred matcher / "Have a code?") → `/join/7KQ4M2XB`.
3. `/join/:code` in the app: waits for auth hydration and socket, shows the table preview, then:
   - No session → one field: "What should we call you?" (prefilled from the invite label if any) → `POST /auth/guest` → token stored.
   - Existing session (guest or registered) → skip.
4. `POST /invites/:code/redeem`, optionally with an explicitly chosen seat → server claims a seat → client joins `game:<room>` → waiting room. Without a chosen seat the server tries the invite's hint and falls back to any open seat automatically, reporting `hint_honored: false` so the client can toast "your partner seat was taken". With an explicitly chosen seat the server does not guess: a taken seat answers `409 SEAT_TAKEN` with `next_open`, and the client picks again.
5. Plays. Game over → post-game summary → **"Save this result"** card: display name locked in, email + password (later: Apple/Google). Skip keeps playing as guest; the card returns after the next game and as a banner on the home screen, at most once a day.

### Returning guest
- Same device, token present → straight in, name remembered.
- Token lost (Android reinstall, Safari after 7 idle days) → they are a new guest. Same link still works while the table is open; their old seat, if any, goes through the normal disconnect cascade. Accepted for v1; the fix is conversion, not engineering.

### Edge flows
- Host taps own link → "This is your table" → waiting room.
- Registered user taps a link while seated elsewhere → "Leave your current table and join Marcel?" (today's `ALREADY_IN_ROOM` handling, made explicit).
- Table full / started / closed / expired / revoked → landing page states with a next action ("Ask Marcel for a new link", "Play against bots", "Get the app").
- Rooms live in memory: a backend deploy closes every waiting table. The landing page must handle a valid invite whose room is gone ("Table closed") and the host must be told when they come back.

## Link anatomy

- Canonical: `https://www.pidro.online/j/7KQ4M2XB`. The existing apex-to-`www` 308 means the apex cannot be canonical for Universal Links; both hosts may remain in app entitlements during migration.
- Optional query for attribution only, never for behavior: `?s=wa|im|sms|qr|copy`.
- Share text (English v1, the codebase has no i18n): `Come play Pidro with me 🃏 https://www.pidro.online/j/7KQ4M2XB — code 7KQ4-M2XB`. The code in plain text *is* the iOS fallback.
- Scheme mirror: `pidro-mobile://j/7KQ4M2XB` (dev/preview: `pidro-mobile-dev://`, `pidro-mobile-preview://`). Used only by the landing page's fallback button when the OS did not honor the HTTPS link. Accepted risk: another app installed on the invitee's own device could register the scheme and receive the code. The code is a table-scoped, multi-use, 24-hour, host-revocable invite (not an account credential), the server still decides room, seat and identity, and the alternative (manual code entry for every in-app-browser user) would cut the funnel where it is weakest. Revisit if invites ever carry more than table access.
- Store links: Play `https://play.google.com/store/apps/details?id=com.oneapps.pidro&referrer=invite%3D7KQ4M2XB`; App Store `https://apps.apple.com/app/id1137091987?pt=…&ct=invite` (campaign params for analytics only).

## Landing page (`GET /j/:code`, Phoenix, browser pipeline)

- Server-rendered HTML, no client JS needed for the preview. OG: title "Marcel invited you to Pidro", description "2 of 4 seats taken · tap to join", image 1200×630 under 300 KB, generated once (host name only, no avatar in v1).
- Crawler user agents (`WhatsApp`, `facebookexternalhit`, `TelegramBot`, `Slackbot`, `Twitterbot`, `Discordbot`, `iMessage`/`Applebot`) get the OG-only response; nothing is counted or reserved on any GET.
- Human on iOS: Smart App Banner meta (`apple-itunes-app`, `app-argument` = the link), primary **Open in app** button = `pidro-mobile://j/CODE` wrapped in a "didn't open? Get the app" timeout, secondary App Store button.
- Human on Android: primary button = `intent://j/CODE#Intent;scheme=https;package=com.oneapps.pidro;S.browser_fallback_url=<play store with referrer>;end`, secondary Play button.
- Desktop: store buttons plus a QR of the link for phone handoff. **Play in browser** → `https://play.pidro.online/join/CODE` is deferred with web join (answered question 2, build-plan phase 6).
- States: open (n/4 seats), full/playing (offer spectate later), closed/expired/revoked, table moved (host's new room).
- Also served by Phoenix: `/.well-known/apple-app-site-association` (`application/json`, `details` for prod + dev + preview app ids, `components` path `/j/*`) and `/.well-known/assetlinks.json` (prod + dev + preview packages, Play App Signing fingerprint). `pidro.online` (Next.js on Vercel) adds `rewrites` for `/j/:code` and `/.well-known/:file` to `https://app.pidro.online/...`, and excludes both from its NextAuth middleware matcher. The legacy `/app/*` AASA path stays for the old client.

## Data model (Postgres)

```
invites
  id              uuid pk
  code            text unique            -- 8 chars, Crockford base32, upper-cased on write and lookup
  room_code       text                   -- in-memory room; may be dead
  host_user_id    uuid                   -- who minted it (guest or registered)
  seat_hint       text null              -- north|east|south|west|north_south|east_west
  label           text null              -- "Anna" (optional friend name)
  max_uses        int null               -- null = unlimited while the table is open
  redeem_count    int default 0
  expires_at      timestamptz            -- now() + 24h
  revoked_at      timestamptz null
  superseded_by   uuid null              -- new invite after "play again"
  inserted_at / updated_at

invite_redemptions
  invite_id, user_id, position, platform, source, inserted_at   -- one row per successful claim

invite_events                             -- the marketing funnel
  invite_id, kind, platform, ua_class, user_id null, inserted_at
  kinds: created, shared, landing_viewed, crawler_viewed, open_app_clicked, store_clicked,
         app_opened_via_link, deferred_matched, code_typed, guest_created, seat_claimed,
         game_completed, guest_upgraded, expired, revoked

users (additions)
  display_name    text null              -- what other players see; username stays the unique handle
  token_version   int default 0          -- bumped on upgrade / logout / delete; embedded in Phoenix.Token
  last_seen_at    timestamptz            -- guest reaper input
  install_id      text null              -- client-generated uuid, for rate limits and deferred matching
```

`RoomManager` gets `Room.invite_ids` and a `locked` flag (repurposes the dead `settings.private`). Seat claims stay in the GenServer: it is already the serialization point, so two invitees racing for the hinted seat cannot both win; the loser gets the next open seat and a toast.

## API surface

| Method & path | Auth | Purpose |
|---|---|---|
| `POST /api/v1/rooms/:code/invites` `{seat_hint?, label?}` | host (any seated player in v2) | mint; returns `{code, url, share_text, seat_hint, expires_at}` |
| `DELETE /api/v1/invites/:code` · `POST /api/v1/invites/:code/regenerate` | host | revoke / replace |
| `GET /api/v1/invites/:code` | public, rate-limited | preview: host display name, seats taken, hint, state. Never exposes `room_code` |
| `POST /api/v1/invites/:code/redeem` `{position?}` | guest or registered | validate → claim seat via `RoomManager` → `{room, position, hint_honored}`. Without `position`: try the hint, fall back to any open seat (`hint_honored: false`). With `position`: `409 SEAT_TAKEN` with `next_open` when that seat is taken. `410` for expired/closed/revoked |
| `POST /api/v1/auth/guest` `{display_name, invite_code, install_id, platform}` | public, **requires a valid invite**, rate-limited per IP and install_id | creates `guest: true` row, returns token + user |
| `POST /api/v1/auth/upgrade` `{email, password, username?}` | guest token | same id, `guest=false`, bump `token_version`, new token; 409 `EMAIL_TAKEN` / `USERNAME_TAKEN` |
| `DELETE /api/v1/auth/me` | any | account + data deletion (Apple 5.1.1(v)) per the retention rules in "Abuse, privacy, compliance": the `users` row, `player_profiles` and `player_achievements` are deleted; `game_stats` keeps the bare UUID, which then resolves to nobody |
| `POST /api/v1/invites/deferred` `{platform, install_referrer?, fingerprint}` | any | server-side deferred resolution in Phoenix (phase 4) |
| `POST /api/v1/rooms/:code/seat` `{position}` · `POST …/lock` · `POST …/kick` | seated / host | move seat in the waiting room, lock table, remove a player |
| `GET /j/:code` · `GET /.well-known/*` | public | landing page and association files |

Lobby channel pushes `room_updated` already; add `invite_redeemed` (`{position, display_name}`) on the game channel so the host sees "Anna is joining…" before her socket connects.

## Token and session model

- **v1 (ship with the feature):** keep the 30-day `Phoenix.Token` but sign `%{id, v: token_version}`; `Token.verify/1` compares `v` with the row, so upgrade, logout and delete invalidate old tokens. Guest and registered tokens are otherwise identical. `Authenticate` plug and `UserSocket.connect/3` unchanged apart from the payload.
- **v2:** `sessions` table with rotating opaque refresh tokens (`expo-secure-store` on native, server-set `HttpOnly` cookie on web because Safari wipes JS storage after 7 idle days) plus a 15–60 min `Phoenix.Token` for the socket.
- Guest persistence per platform: iOS Keychain survives reinstall (today), Android does not, web-Safari lasts 7 idle days. State this in the UI copy ("Save your result to keep it on any device").

## Client changes

**Shared (`packages/shared`)**
- `api/invites.ts` (mint, preview, redeem, revoke), `api/auth.ts` (`createGuest`, `upgrade`, `deleteAccount`).
- `stores/auth.ts`: persist `user.guest`, `displayName`; rehydration accepts guest-shaped sessions.
- `stores/pendingInvite.ts` (persisted): `{code, source, receivedAt}`; written by link handlers, consumed once by `/join`.
- `utils/inviteLink.ts`: parse `https://www.pidro.online/j/CODE` (and legacy apex links), `pidro-mobile://j/CODE`, bare codes with/without dash; normalize to upper Crockford; tests next to `gameRoute` tests.

**Mobile (`packages/mobile`)**
- `app.json`: `ios.associatedDomains: ["applinks:pidro.online", "applinks:www.pidro.online"]`, `android.intentFilters` (autoVerify, hosts above, `pathPrefix: "/j"`); per-variant in `app.config.js`; add the missing `preview` EAS profile.
- `app/+native-intent.tsx`: map `/j/:code` (https and scheme) → `/join/:code`; phase 4 feeds the Phoenix deferred-match result through the same pending-invite path on first launch.
- `app/join/[code].tsx`: preview → name entry → redeem → `router.replace(gameRoute(code))`. Handles every landing state and `ALREADY_IN_ROOM`.
- `app/index.tsx` gate: `pendingInvite` wins over the login redirect; unauthenticated + no invite → login as today, plus "Have an invite code?" entry.
- `app/game/[code].tsx`: add the missing auth gate (today a cold deep link stalls).
- Waiting room (`components/game/WaitingTable.tsx`): Invite button, share sheet (`expo-sharing`, `expo-clipboard`), QR, seat move/lock/kick for the host, "joining…" placeholders.
- Post-game: "Save this result" card after `progression_summary`; upgrade form; re-prompt policy.
- Settings: Delete account.
- Phase-3 packages: `expo-sharing`, `expo-clipboard`, `i18n-js`, `expo-localization`, `react-native-qrcode-svg` (or draw with Skia). Phase 4 chooses the minimum device-data and Play Install Referrer packages needed by the self-hosted matcher.

**Web (`packages/web`)**
- Public route `/join/:code` (register it explicitly; the catch-all at `App.tsx:77` swallows unknown paths). Same name → guest → redeem flow. `LobbyPage` join gets the seat parameter it already ignores.
- Waiting room: Copy link / share / QR. OG tags stay on the Phoenix landing page, not here.
- Run the web test suite in CI (it is not today).

## Platform edge-case matrix

| Situation | iOS | Android | Web / desktop |
|---|---|---|---|
| Installed, tapped in Messages / WhatsApp / Mail / Safari | Universal Link opens app (after AASA CDN pickup, ~24 h). Fails silently if the user once chose "Open in Safari" → they land on the page → Open-app button | App Link opens app if `assetlinks.json` verified against the Play App Signing key; on Android 12+ a failed verification silently opens the browser | Landing page with store buttons + QR (Play in browser deferred) |
| Installed, tapped inside Instagram / Messenger / TikTok / Telegram in-app browser | Landing page; Open-app = scheme (works from most WebViews on a real tap) | Landing page; `intent://` opens the app from Chrome-based WebViews | n/a |
| URL pasted into the address bar | Never opens the app; landing page + button | Same | Same |
| Not installed | Landing → App Store. First launch: Phoenix match (probabilistic, IP+UA+screen+locale+time window) or "Have a code?" screen. Measure the automatic match rate rather than assuming a vendor claim | Landing → Play with `referrer` → first launch reads Install Referrer → deterministic | Landing page with store buttons + QR (Play in browser deferred) |
| Chat app fetches the link for a preview | OG card only, no side effects (WhatsApp fetches while typing) | same | same |
| Dev / preview builds | Need their own AASA entries and "Associated Domains Development" toggle; never works in Expo Go | Need their own assetlinks entries; check with `adb shell pm get-app-links com.oneapps.pidro` | – |
| Link arrives before auth hydration / socket | `pendingInvite` store, act in `/join` once `hydrated && socket` | same | same |
| Table gone (deploy, host left, 10-min idle sweep, 24 h) | "Table closed" page/screen with re-invite / play-vs-bots | same | same |
| Guest identity lost | Keychain usually survives reinstall | Lost on reinstall and on backup restore | Safari drops it after 7 idle days |

## Abuse, privacy, compliance

- Guest creation only against a valid invite; Hammer limits: guest create 5/h and 20/day per IP and per `install_id`; invite preview 30/min per IP; redeem 10/min per user; failed code lookups 20/h per IP with backoff. Public `GET /rooms/:code` gets the same treatment.
- Display names: length 2–20, profanity list, no look-alike of the host's name at the same table.
- Guest reaper: hard-delete `guest: true` rows with `last_seen_at` older than 30 days; `game_stats` keep the bare UUID. This is the GDPR retention policy; legal basis is legitimate interest (they joined a game).
- Deletion and anonymization (applies to `DELETE /api/v1/auth/me` and to the reaper): delete the `users` row (username, email, display name, password hash, `install_id`), the user's `player_profiles` and `player_achievements` rows, and any `invite_redemptions` / `invite_events` rows carrying the user id. `game_stats` stores no names, only `player_ids` and per-id results, so the remaining UUID no longer resolves to a person and other players' records stay intact. Opponents' post-game screens show "Deleted player" for an id that no longer resolves.
- Deferred-install matching (phase 4) is limited to what the match needs and is disclosed: the landing page stores a coarse fingerprint (client IP as seen by the proxy, OS family and major version, screen class, locale, timezone) with the invite code for at most 30 minutes, then hard-deletes it; the app sends the same fields once on first launch; a match returns only the invite code; nothing is shared with third parties, nothing is used for advertising or analytics beyond the funnel counter, and the privacy policy names the mechanism. Android prefers the deterministic Play Install Referrer and only falls back to the fingerprint match; "Have a code?" remains the always-available manual path.
- In-app **Delete account** for guests and registered users before App Store submission (5.1.1(v)).
- Later: `@expo/app-integrity` (App Attest / Play Integrity) on guest creation, Cloudflare Turnstile on the web form.
- Never trust anything in the URL beyond the code; the server decides room, seat and identity.
- Codes are tombstoned (`revoked_at`/expired rows stay), never reissued; keyspace is 1.1 × 10¹².

## Analytics (what marketing gets)

Funnel per invite and per source: created → shared → landing_viewed (humans only) → open_app / store → app_opened_via_link / deferred_matched / code_typed → guest_created → seat_claimed → game_completed → guest_upgraded. Surface in `/dev/analytics` (existing LiveView) first; export later. This is also how we learn the real iOS deferred match rate.

## Build plan

Sizes: S ≈ a day, M ≈ 2–3 days, L ≈ a week, for one engineer working with agents. Each phase is a `/ce-plan`.

0. **Prerequisites (M)** — Hammer rate limits on auth, rooms, invites; CSPRNG room codes with collision retry; drop `:guest` from the public `changeset/2` cast; `.well-known` served by Phoenix with `application/json`; `token_version` on users and in `Phoenix.Token`; `display_name`, `install_id`, `last_seen_at` columns.
1. **Invites + guests on the backend (L)** — `invites`, `invite_redemptions`, `invite_events` tables and context; mint / preview / redeem / revoke / regenerate; `POST /auth/guest`, `POST /auth/upgrade`, `DELETE /auth/me`; `RoomManager` seat claim with hint, lock, move, kick; `invite_redeemed` push; guest reaper; tests in `auth_controller_test`, `room_controller_test`, `room_manager_test`, a `room_fixture`.
2. **Landing page + association files (M)** — `GET /j/:code` HTML with OG and crawler branch, Open-app / store buttons, desktop QR and states; AASA + assetlinks for prod/dev/preview; Vercel rewrites + middleware exclusion in `pidro-site2`; Smart App Banner; OG image.
3. **App deep links + join flow (L)** — `associatedDomains`, `intentFilters`, the missing EAS `preview` profile, `+native-intent.tsx`, `pendingInvite` store, `/join/[code]`, name entry, guest session in the auth store, auth gate on `/game/[code]`, waiting-room Invite/share/copy/QR, host seat controls, "joining…" placeholder, and the thin English-first i18n layer; add `/join` to the UI-grammar screenshot list; e2e: invite → guest → full game in `ci-game-e2e.mjs`.
4. **Deferred install (M)** — Phoenix-owned 30-minute fingerprint matching with hard deletion, deterministic Play Install Referrer on Android, "Have a code?" fallback, store links with referrer / campaign params, privacy notice and measured match rate.
5. **Post-game registration (M)** — "Save this result" card, upgrade form, collision handling (email exists → sign in there, guest row abandoned; no merge in v1), re-prompt policy, Delete account in settings.
6. **Web join + measurement + hardening (M)** — `/join/:code` on `play.pidro.online`, web tests in CI, funnel dashboard, App Attest / Play Integrity prototype, Turnstile, AASA/assetlinks check in CI.

Later, not now: host-bound permanent links ("join Marcel wherever he is"), invite via push to friends, spectate from the landing page, Sign in with Apple/Google on the upgrade form (triggers Guideline 4.8 parity), guest merge tool, Classic-account claim on the upgrade screen (blocked on the shelved migration).

## Open questions — answered by the user on 2026-09-02

1. **Host backgrounds the app to paste the link → fix it.** Waiting rooms get their own rule: a disconnected human seat in a `:waiting` room is held (not bot-substituted) and never counts toward the 4-seat auto-start; the room survives at least the idle TTL while an invite is live; the host reclaims the seat on reconnect. Bot substitution stays for `:playing` rooms only.
2. **`play.pidro.online` is the Vite web app.** Web play is out of scope for now; iOS and Android have priority. The Phoenix landing page (needed for iOS/Android) still ships; the web `/join/:code` route and "Play in browser" button are deferred (the landing page shows store buttons only on desktop for now, plus the QR for phone handoff).
3. **Play App Signing is in use and current.** Keep the existing fingerprint; verify with `adb shell pm get-app-links com.oneapps.pidro` on the first dev build.
4. **Deferred matching runs in Phoenix, not Detour.** Detour's default sends every landing-page visitor's IP and device profile to Software Mansion's hosted service and needs an account there. We implement the same technique ourselves: the landing page posts a fingerprint hint, the app posts its fingerprint on first launch, the server matches within a 30-minute window and hard-deletes the fingerprint record afterwards (data minimization, retention and notice are defined in "Abuse, privacy, compliance"). Android additionally reads Play Install Referrer for a deterministic match. "Have a code?" stays as the fallback.
5. **Host only mints invites** in v1.
6. **English only, but an i18n layer from day one.** Add a thin `i18n-js` + `expo-localization` layer in mobile (`src/i18n/`, `en.json`) and route every new invite/guest string through it. Existing strings are not retrofitted in this feature.
7. **"Play again" mints a new invite** and marks the old one `superseded_by`; the old link's landing page forwards to the new table while it is waiting.

## Codebase touchpoints

Backend (`pidro_backend/apps/pidro_server`): `lib/pidro_server/accounts/user.ex:61` (cast), `accounts/token.ex:56-88` (payload), `accounts/auth.ex` (new `create_guest_user/2`, `upgrade_guest/2`, `delete_user/1` exists at 343), `games/room_manager.ex:740-836` (create/join), `:909-912` (host leave closes waiting room), `:2488` (room code), `games/room/positions.ex:76` (`assign/3` already takes seat or team), `games/room/seat.ex:40` (`reserved_for` exists), `games/lifecycle.ex:33-51` (TTLs), `pidro_server_web/router.ex:47-84`, `channels/game_channel.ex:769` (`determine_user_role`), `controllers/api/room_controller.ex:740` (`join/2` parses position), `controllers/api/room_json.ex:123-171`, `lib/pidro_server_web.ex:20` (`static_paths`), `endpoint.ex:29-33,62-65`, `config/deploy.yml:38-42`, `test/support/fixtures.ex`.

Frontend (`pidro_frontend`): `packages/mobile/app.json:6,38,44`, `app.config.js`, `eas.json`, `app/_layout.tsx`, `app/index.tsx:18-22`, `app/game/[code].tsx:145,231`, `src/navigation/gameRoute.ts`, `src/components/game/WaitingTable.tsx`, `src/components/lobby/RoomTeamDisplay.tsx:18` (seat pick exists), `src/utils/storage.ts:58`, `src/hooks/useAuth.ts`, `scripts/verify-ui-grammar.mjs:20-59`, `scripts/ci-game-e2e.mjs`; `packages/shared/src/stores/auth.ts:35-103`, `src/api/auth.ts`, `src/api/lobby.ts:99-110`, `src/types/lobby.ts:7-11,68-77`; `packages/web/src/App.tsx:36-78`, `src/pages/LobbyPage.tsx:156`, `src/components/game/WaitingRoom.tsx:99-108`, `vercel.json`, `index.html`.

Marketing site (`/Users/mf/code/pidro/pidro-site2`): `public/.well-known/apple-app-site-association` (live, `/app/*` only), `public/.well-known/assetlinks.json`, `next.config.js` (add `rewrites`), `middleware.ts` (add matcher exclusion).
