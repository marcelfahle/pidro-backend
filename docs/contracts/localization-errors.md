# Additive error localization rollout

The versioned vocabulary is [localization-errors.json](localization-errors.json).
Each `errors` entry names its code, required parameter schemas, English meaning
and source groups; `sources` resolves those groups to routes/events. An empty
`params` schema means `{}`. Codes are stable snake_case strings. Existing
uppercase REST codes and channel reason strings are not removed or renamed.

## Wire format

REST error bodies and channel error reply payloads gain `error_code` and
`error_params` at the **top level**, beside their existing fields. For example:

```json
{
  "errors": [{"code": "ROOM_FULL", "title": "Room full", "detail": "Room already has 4 players"}],
  "error_code": "room_full",
  "error_params": {}
}
```

```json
{
  "status": "error",
  "reason": "seat_requires_games",
  "min_games": 1000,
  "games_played": 37,
  "error_code": "seat_requires_games",
  "error_params": {"min_games": 1000, "games_played": 37}
}
```

Validation preserves the existing `errors` value exactly, including
field names used as legacy `code` values. A parallel `field_errors` array adds
field identity independently of the legacy code:

```json
{
  "errors": [{"code": "password", "title": "Password", "detail": "should be at least 8 character(s)"}],
  "error_code": "validation_failed",
  "error_params": {},
  "field_errors": [{"field": "password", "error_code": "field_too_short", "error_params": {"count": 8}}]
}
```

`field` is the original field name or dotted room-config path, such as
`seats.seat_3`. Several errors can refer to one field; do not pair the two arrays
by index. Ecto codes come from validator metadata, not message text. Custom
validators without metadata and Room.Config errors use `field_invalid`.
`classic_name_reserved` retains the actual `username` or `display_name` field.
Avatar failures keep `errors.avatar: [English message]`, use their avatar code
at the top level, and repeat that code in `field_errors` for field `avatar`.

## Compatibility and safety

- All existing statuses, success responses, English reasons/details/messages,
  retry headers, invite actions/next codes, readiness and seat snapshots remain.
- Known domain atoms and tuple tags map to documented codes. Existing stable
  REST codes map through an allowlist. No arbitrary text is slugified or matched.
- Unknown channel reasons use `action_failed`; unknown REST atoms retain their
  old 422 envelope with `request_failed`. Previously unhandled REST reasons
  still reach the endpoint's error renderer (normally 500), now with
  `request_failed`. No new status semantics are introduced.
- Interpolation parameters contain only selected integers: game counts, field
  length counts and retry seconds. Exception messages, credentials, arbitrary
  changeset options and tuple contents never enter them. Legacy diagnostic text
  is retained for compatibility, not endorsed for UI display.
- Clients must treat codes/params as optional while old servers remain deployed.
  Prefer known structured codes, then known stable legacy codes, then a translated
  context fallback. Never render raw server text as the Swedish fallback.

## Covered paths and intentional gaps

Covered: auth/guest/upgrade/age/recovery, Classic verification/claim/help,
room create/join/watch/host controls, invites, friends/search, profiles/avatar,
HTTP authentication/rate limits, lobby joins, game joins/actions/seats and
ready/rematch replies. The manifest inventories the different legacy envelopes.

Socket authentication still rejects with bare `:error`. Missing public avatars
still return empty 404 bodies. Deferred invite misses remain successful
`data.invite = null`. HTML/admin pages and malformed channel messages that
previously crashed rather than returned an error are not new error protocols.
There are no engine edits, locale storage, localization service or translated
broadcasts: each client chooses its language independently in the same room.

## Rollout and checks

The manifest was pushed before implementation so the frontend can integrate
from backend branch `feat/localized-error-contract`. The paired frontend branch
is [feat/english-swedish-localization](https://github.com/marcelfahle/pidro-frontend/tree/feat/english-swedish-localization).
Both changes remain draft PRs; no migration, deployment or coordinated cutover
is required for these additive fields.

Tests exercise real REST/channel paths and preserve legacy fields and success
shapes, including engine tuple failures, spectator refusals, stale readiness,
seat requirements, field validation, rate-limit timing and unknown/internal
fallbacks. A manifest test checks every published code and parameter schema
against the serializer. Final `mix precommit` and latest-head Backend CI results
are recorded in the PR description.
