---
title: Invite links, deep linking and guest play — landscape research
date: 2026-09-02
status: research (feeds docs/brainstorms/2026-09-02-invite-links-and-guest-play-requirements.md)
scope: Expo SDK 56 mobile app + Vite/React web client + Elixir/Phoenix backend
---

# Invite links, deep linking and guest play — what the world knows in 2026

Companion to the requirements doc. This file holds the *facts* (with sources and dates) so
the requirements doc can stay opinionated and short. Anything marked **unverified** was
repeated by several secondary sources but could not be traced to a primary one.

## 1. Facts about our own setup (verified 2026-09-02, pre-phase-0 baseline)

> Baseline note: the statements below describe the repository **before** phase 0 (PR #19). Phase 0 added Hammer rate limiting on auth and room routes, CSPRNG room codes with collision retry, a trusted-proxy plug, versioned tokens, and removed `guest` from the public changeset. Items marked *(changed in phase 0)* no longer hold on `main`.

- `https://www.pidro.online/.well-known/apple-app-site-association` is live, served by the
  marketing site (`/Users/mf/code/pidro/pidro-site2`, Next.js on Vercel, file in
  `public/.well-known/`). Content: `appID "LSFK7YF82G.com.oneapps.pidro"`, paths `["/app/*"]`.
  Content-type is `application/octet-stream`, and Apple accepted it anyway: Apple's CDN
  (`app-site-association.cdn-apple.com/a/v1/pidro.online` and `/www.pidro.online`) returns
  the same file for both apex and www. The apex `pidro.online` 308-redirects to `www`.
- `https://www.pidro.online/.well-known/assetlinks.json` is live for package
  `com.oneapps.pidro` with one SHA-256 cert fingerprint (dated Dec 2024, so it belongs to the
  legacy Unity app's signing key; with Play App Signing the *app signing* key survives the
  Expo rebuild, the *upload* key does not — verify in Play Console → App integrity).
- The new Expo app ships under the **same** identifiers as the legacy app:
  `ios.bundleIdentifier` / `android.package` = `com.oneapps.pidro`, App Store id
  `1137091987` (`packages/mobile/app.json:38,44`, `eas.json:27`). Dev/preview variants use
  `com.marcelfahle.pidro3.dev` / `.preview` (`app.config.js`).
- `app.pidro.online` (Phoenix) returns 404 for `/.well-known/*`: `static_paths/0` only
  allows `assets fonts images favicon.ico robots.txt` (`lib/pidro_server_web.ex:20`).
- `play.pidro.online` (`packages/web/vercel.json`) rewrites *every* path to `index.html`,
  so it would serve HTML for `.well-known` files if they were added naively.
- Production domains from `pidro_backend/config/deploy.yml`: API `app.pidro.online`, web
  `play.pidro.online`, CORS `https://play.pidro.online,https://app.pidro.online`.
- The backend already has `users.guest` (boolean, default false) and nullable
  `email`/`password_hash` since the first migration
  (`priv/repo/migrations/20251102091113_create_users.exs`). Nothing creates a guest today.
- Every stats/profile/achievement table references users by bare UUID with **no foreign
  key** (`game_stats.player_ids`, `player_profiles.user_id`, `player_achievements.user_id`).
  Upgrading a guest row in place carries all history with zero data migration.
- Rooms live only in `RoomManager` memory (single GenServer). A deploy loses every room.
  Room codes were 4 chars `A-Z0-9` from `Enum.random/1` with **no collision check**
  (`room_manager.ex:2488`), and `GET /api/v1/rooms/:code` was public and unthrottled
  *(changed in phase 0: CSPRNG codes with collision retry, per-IP throttle on the lookup)*.
- There was **no rate limiting** of any kind in the backend, and `guest` was mass-assignable
  through `User.changeset/2` on the public register endpoint (`accounts/user.ex:61`)
  *(changed in phase 0: Hammer limits on auth and room routes; `guest` is set only by the
  internal `guest_changeset/2`)*.
- Client: `expo-linking` is installed but never imported; no `associatedDomains`, no
  `intentFilters`, no `+native-intent.tsx`, no share/copy/QR UI, no OG tags in
  `packages/web/index.html`, no i18n layer, `packages/web` tests do not run in CI.

## 2. Universal Links (iOS) and App Links (Android)

**Setup**
- AASA at `/.well-known/apple-app-site-association`, HTTPS, no redirects, `application/json`,
  < 128 KB. Since iOS 14 devices fetch it through Apple's CDN; propagation of changes is
  commonly reported as ~24 h with weekly re-checks on installed devices (**unverified**
  timing, not in Apple docs). Debug on device: Console.app, filter `swcd`. Dev bypass:
  Settings → Developer → "Associated Domains Development".
  Sources: https://www.airbridge.io/en/blog/universal-links-setup-guide-ios ,
  https://developer.apple.com/forums/thread/816498
- `assetlinks.json` at `/.well-known/assetlinks.json`, HTTP 200, `application/json`, **no
  redirect** (Android's verifier does not follow them). Fingerprint must be the *Play App
  Signing* key, not the upload key. Android 12+ removed the chooser dialog: a failed
  verification silently opens the browser. Inspect with `adb shell pm get-app-links`.
  Sources: https://warplink.app/blog/android-app-links-autoverify-failed ,
  https://medium.com/@lanltn/about-verify-app-links-on-android-12-and-higher-e53e9bb2f7bb
- Expo: `ios.associatedDomains: ["applinks:host"]`, `android.intentFilters` with
  `autoVerify: true`; needs a dev client / EAS build, never works in Expo Go.
  https://docs.expo.dev/linking/android-app-links/

**Failure modes that will hit us**
- A URL pasted or typed into Safari's address bar never opens the app (by design). A JS
  `location.href` redirect does not count as a user tap either.
  https://developer.apple.com/forums/thread/659322
- A link to the same domain from a page on that domain does not trigger the handoff.
- A user who once tapped "Open in Safari" has Universal Links disabled for that domain
  until they long-press a link and choose "Open in app". No Settings toggle.
- In-app browsers: system components (SFSafariViewController on iOS, Custom Tabs on
  Android — X/Twitter, most mail apps) generally honor the links; bespoke WebViews
  (Instagram, TikTok, Facebook, Snapchat, Pinterest, Telegram's in-app browser) generally
  do not. WhatsApp and Messenger are inconsistent (**unverified** per-version matrix).
  https://linkrunner.io/blog/universal-links-app-links-break-in-app-browsers
- Workarounds: an intermediary landing page with a real "Open app" button (a user tap
  inside a WebView often re-enables the handoff); Android `intent://…#Intent;scheme=…;
  package=…;S.browser_fallback_url=…;end` for Chrome
  (https://developer.chrome.com/docs/android/intents); custom scheme as last resort
  (throws a dialog if the app is missing).
- Smart App Banner (`<meta name="apple-itunes-app">`) still works in Safari in 2026, only
  in Safari itself, not in in-app browsers.
  https://developer.apple.com/documentation/webkit/promoting-apps-with-smart-app-banners

## 3. Deferred deep linking (install first, land in the table after)

- Firebase Dynamic Links shut down 2025-08-25; Google points to Adjust, Airbridge,
  AppsFlyer, Bitly, Branch, Kochava, Singular, or plain Universal/App Links if you don't
  need deferral. https://firebase.google.com/support/dynamic-links-faq
- **Apple has no first-party deferred deep link.** SKAdNetwork gives aggregated ad
  attribution only, never a destination URL. App Clips are a separate <10 MB binary with
  their own associated-domain experience and do not surface from a generic WhatsApp link;
  Expo/React Native support for App Clips is poor. https://developer.apple.com/forums/thread/772811
- **Android Play Install Referrer** is deterministic and free: put
  `&referrer=invite%3DCODE` on the Play Store link, read it on first launch.
  https://developer.android.com/google/play/installreferrer
- iOS options: (a) pasteboard hand-off — write the code when the user taps "Get the app",
  read it on first launch; iOS 16+ shows a paste-permission prompt, so match rates drop;
  (b) probabilistic matching on IP + UA + screen + locale + timezone within a time window,
  legally gray under ATT/DPLA, ~60–80 % match (vendor claims); (c) ask the user to type or
  paste the code (deterministic, one extra screen).
  https://www.branch.io/resources/blog/everything-you-need-to-know-about-ios-16-and-pasteboard-opt-ins/
- Vendors 2026 (third-party-reported pricing, verify before buying): Branch (free to ~10k
  MAU, then ~$500+/mo; community-maintained Expo plugin `@config-plugins/react-native-branch`
  v13.0.2), AppsFlyer OneLink, Adjust, Kochava (free to ~10k conversions/mo), Airbridge
  (~$40/mo entry). All are ad-attribution products first.
- **Detour** (Software Mansion, MIT): `@swmansion/react-native-detour` v2.3.1 (npm, first
  published 2025-09-24, updated 2026-08-07). Deterministic on Android via Install Referrer
  `click_id`; probabilistic on iOS with optional clipboard; ships a
  `createDetourNativeIntentHandler` for expo-router's `+native-intent.tsx` with
  `linkProcessingMode: 'deferred-only'`; hosted dashboard at godetour.dev (free to start) or
  self-hosted. Peer deps: async-storage, expo-application, expo-clipboard, expo-constants,
  expo-device, expo-localization, react-native-device-info.
  https://github.com/software-mansion-labs/react-native-detour ,
  https://detour.swmansion.com/docs/Fundamentals/introduction

## 4. Expo specifics (SDK 53–56)

- `app/+native-intent.tsx` exports `redirectSystemPath({ path, initial })`; runs outside
  React (no auth/store access), native only; must never throw; return `false` to disable
  router auto-handling. https://docs.expo.dev/router/advanced/native-intent/
- `expo-linking`: `getInitialURL()` / `getLinkingURL()`, `addEventListener('url')`,
  `useLinkingURL()` (replaces deprecated `useURL`). The cold-start race (link arrives before
  auth hydration and socket) is not handled by Expo — stash the intent, act when ready.
- `@expo/app-integrity` (App Attest + Play Integrity behind one API) is at 57.0.1 on npm,
  still marked alpha in Expo's docs; server-side verification is yours to write.
  https://docs.expo.dev/versions/latest/sdk/app-integrity/
- Known rough edge: EAS Build not always honoring intent-filter config as expected
  (https://github.com/expo/expo/issues/15486). Test on a real device with a dev build.

## 5. Link-preview crawlers

- WhatsApp fetches the URL **while the user is still typing**, before Send; UA `WhatsApp`
  or `facebookexternalhit`; no JavaScript; ~10 s timeout.
  https://opengraphplus.com/consumers/whatsapp/crawling
- Telegram (`TelegramBot`), iMessage, Slack (`Slackbot`), Facebook, Discord and X all
  pre-fetch server-side. Consequence: a GET on the invite URL must be idempotent and must
  never consume, count, or reserve anything. Only an explicit in-app join is a redemption.
- OG card: `og:title`, `og:description`, `og:image` 1200×630 (1.91:1). WhatsApp reportedly
  drops images over ~300 KB (**unverified**, widely repeated). Tags must be in the raw
  server-rendered HTML — a Vite SPA cannot produce per-invite previews.

## 6. Invite-token design and security

- Opaque, DB-backed codes beat signed/stateless tokens for invites: revocable, countable,
  regenerable. Keep `Phoenix.Token` for the short-lived session hand-off.
  https://dockyard.com/blog/2020/01/14/tips-for-tokens
- Entropy: 8 chars of Crockford Base32 (`0-9 A-Z` minus `I L O U`, case-insensitive)
  = 40 bits ≈ 1.1 × 10¹² codes. Fine against online guessing **only** with per-IP and
  per-code rate limits (OWASP wants ≥ 64 bits only for unthrottled session ids).
  https://www.ietf.org/archive/id/draft-crockford-davis-base32-for-humans-00.html
- Real-world code lengths: Discord 7–8 (10 for permanent), Google Meet 10, Jackbox 4,
  Among Us 6, Kahoot 6–10 digits. Discord default expiry 7 days; Slack 30 days / 400 uses;
  Zoom instant ids die with the meeting.
- **Never recycle codes.** Check Point Research (June 2025) documented malware delivered
  through *expired Discord invite codes* re-registered by attackers; 1,300+ victims.
  https://research.checkpoint.com/2025/from-trust-to-threat-hijacked-discord-invites-used-for-multi-stage-malware-delivery/
- Seat races: serialize the claim (our `RoomManager` GenServer already does) and give the
  loser the next open seat with a clear message.
- Custom URL schemes can be squatted by any app; Universal/App Links are domain-bound.
  Never trust seat/room ids from the URL beyond a lookup key.

## 7. Guest identity and abuse

- Apple Guideline 5.1.1(v) (current text): apps without significant account-based
  features must work without login; "inviting friends to use the app" is explicitly *not*
  core functionality; any app with account creation must offer in-app account deletion —
  and Apple's forums confirm this includes guest/anonymous sessions.
  https://developer.apple.com/app-store/review/guidelines/ ,
  https://developer.apple.com/forums/thread/693997
- Guideline 4.8 only triggers if a third-party social login is offered as primary; since
  Jan 2024 any privacy-equivalent alternative (not only Sign in with Apple) satisfies it.
- Google Play has no guest-play rule, only account-deletion parity and Families policy.
- Firebase/Supabase pattern: a guest is a *real* user row with a stable id; upgrading
  attaches credentials to the same id; the unhandled edge case in both SDKs is "credential
  already belongs to another account" — you must design merge-or-choose yourself.
  https://firebase.blog/posts/2023/07/best-practices-for-anonymous-authentication/
- Cautionary tales: Chess.com and Lichess keep guest games out of the account → guests
  who care register *before* playing, defeating the point. Among Us removed guest accounts
  in 2022 for moderation reasons. Duolingo moved sign-up behind the first lesson and
  reports +20 % DAU. Board Game Arena pays referrers when the invitee *finishes a first
  game*, the same "first success" event we want.
- Mitigations: only mint guests against a valid invite; Hammer (ETS) rate limits keyed on
  IP and device; display-name filter; TTL reaper (30 days) for never-upgraded guests, which
  doubles as the GDPR retention policy; Cloudflare Turnstile on the web form later;
  App Attest / Play Integrity later via `@expo/app-integrity`.
  https://github.com/ExHammer/hammer

## 8. Identity persistence per platform

- iOS Keychain (`expo-secure-store`) survives uninstall/reinstall today (since iOS 10.3);
  no Apple statement of intent to change (**unverified** going forward).
- Android Keystore-encrypted prefs do not survive reinstall or Auto Backup restore — exclude
  them from backup rules or they restore as garbage.
- Safari deletes all script-writable storage (localStorage, IndexedDB, JS cookies) after
  7 days without interaction; server-set `HttpOnly` cookies are exempt. Home-screen PWAs
  are exempt. https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/
- So: iOS guests are sticky, Android and web guests can silently become "new". Treat loss
  of an unconverted guest as low-stakes; the fix is conversion, not engineering.

## 9. Prior art for seat vs table invites

- Table link + pick-a-seat: Board Game Arena (invitees can join without an account; host
  must explicitly restrict access or strangers wander in — the top complaint), Trickster
  Cards ("Join" games with seat picking; seat = partner), CardzMania (guest play, click an
  empty chair, bots fill the rest), Tabletopia, Jackbox / Kahoot / Skribbl (room codes,
  no seats).
- Seat-bound: only Bridge Base Online (host types a named partner into a reserved seat).
- No public data on invite acceptance rates or k-factor for card games (**none found**).
