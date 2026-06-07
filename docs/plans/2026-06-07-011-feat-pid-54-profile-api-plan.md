---
title: "feat: Player profile API — one authenticated endpoint, μ/σ-free (PID-54)"
type: feat
status: active
date: 2026-06-07
linear: PID-54
origin: docs/ratings-player-profiles/research/PID-54-profile-api.md
---

# feat: Player profile API (PID-54)

## Overview

PID-54 exposes the profile screen over ONE authenticated REST endpoint. Almost
everything the screen needs is already assembled server-side by
`PidroServer.Profiles.get_profile_for_screen/1` (lifetime stats + win_rate,
Veteran level/XP/title/progress, Heritage display, Playstyle needle + avg bid,
Mastery achievements). It has **no HTTP route today** — it is only called from
tests.

So this ticket is exactly two things:

1. **Wire one endpoint** — `GET /api/v1/profile` → `ProfileController.show`,
   under `:api_authenticated`, serving the caller's own profile
   (`conn.assigns.current_user.id`).
2. **Close the skill-tier gap + the μ/σ leak.** `get_profile_for_screen/1`
   returns the **raw `rating_mu` / `rating_sigma` / `rating_games_count`**
   internals and does **NOT** classify a tier. The endpoint must instead expose
   `%{tier, provisional}` (via `Rating.Tier.classify/1`) and emit **no** μ/σ.

The acceptance bar: one call returns Heritage, Veteran (level + title), Skill
(tier + provisional state), Mastery achievements, Playstyle (meter + avg bid),
and headline lifetime stats; **raw μ/σ are NOT exposed**; documented alongside
the existing API (OpenApiSpex). Read-only.

Per `apps/pidro_server/CLAUDE.md`: thin web layer, derive don't duplicate, a
focused unit-testable seam. The existing `GET /users/me/stats`
(`UserController.stats` → `json(%{data: ...})`) is the precedent for shape,
envelope, and auth.

## Non-Goals (explicit scope cuts)

- **Other-player / by-id profiles.** No `GET /api/v1/users/:id/profile` now.
  The payload is already μ/σ-free, so it is a *trivial, safe* follow-on
  (call `get_profile_for_screen/1` with `params["id"]` and reuse the same
  serializer). But there is **no precedent** in this codebase for reading
  another user's data over the API (both `/users/me/stats` and `/auth/me` are
  own-data only), so it opens net-new privacy questions (is `account_age_days`,
  the achievements catalog, etc. public?) that the acceptance criteria does not
  ask us to answer. Acceptance says "own profile"; the 0.5d estimate and
  "client rendering is a follow-on" both confirm scope. **Decision: own-profile
  only for launch.** Noted as a follow-on, not built.
- **Client rendering.** Web-first UI is a separate, later concern. This ticket
  ships the JSON contract only.
- **Any mutation.** Read-only `GET`. No writes, no new schema, no migration.
- **Changing `get_profile_for_screen/1`'s return shape.** It is consumed by
  existing context tests and is the internal "full" view. We do **not** strip
  μ/σ from it (that risks the other readers and the rating internals it
  legitimately carries internally); instead the controller's serializer
  **projects a public allowlist** from it (see below). This keeps the
  μ/σ-exclusion contract in one small, unit-testable place.

## Route + controller action

**Router** (`apps/pidro_server/lib/pidro_server_web/router.ex`), in the existing
authenticated scope (`scope "/api/v1", PidroServerWeb.API do pipe_through
:api_authenticated`), alongside `get "/users/me/stats"`:

```
get "/profile", ProfileController, :show
```

**Decision: `/api/v1/profile` (not `/users/me/profile`).** It is the singular
"my profile" resource; the `/users/me/...` prefix exists for sub-resources of
the user (stats). `/profile` reads cleaner and a future by-id form is the
natural sibling `/users/:id/profile`. Either is defensible; we pick the shorter
own-resource form and stay decisive.

**Controller** — new `PidroServerWeb.API.ProfileController`
(`apps/pidro_server/lib/pidro_server_web/controllers/api/profile_controller.ex`),
mirroring `UserController` exactly:

- `use PidroServerWeb, :controller` + `use OpenApiSpex.ControllerSpecs`
- `action_fallback PidroServerWeb.API.FallbackController`
- `tags(["Profiles"])`
- one `operation(:show, ...)` (see Docs)
- the action:

```
def show(conn, _params) do
  user_id = conn.assigns.current_user.id
  with {:ok, profile} <- Profiles.get_profile_for_screen(user_id) do
    conn
    |> put_status(:ok)
    |> json(%{data: Profiles.public_profile(profile)})
  end
end
```

It threads the `{:error, _}` case to the existing `FallbackController` (the
`with` falls through), but in practice `get_profile_for_screen/1` creates the
row lazily and returns `{:ok, _}` for any authenticated user.

## Where assembly lives + the explicit allowlist

**Decision: a `Profiles.public_profile/1` context function** (in
`apps/pidro_server/lib/pidro_server/profiles/profiles.ex`), NOT a Phoenix JSON
view.

Justification: the μ/σ-exclusion is a **business/security contract**, not a
rendering concern, and it must be unit-testable without spinning up a conn.
Putting it in the context lets the profiles context test assert the contract
directly (and lets a future by-id endpoint reuse it). The controller stays a
two-liner (`json(%{data: public_profile(profile)})`), matching `UserController`'s
"bare map in a `%{data: ...}` envelope" style. `UserJSON` exists for the
`AuthController` case where the user struct needs field-by-field serialization;
here the input is already a plain map, so a view adds indirection without value.

`public_profile/1` takes the `get_profile_for_screen/1` map and **explicitly
constructs** the public response by listing each field — it does NOT
`Map.drop/2` from the full map (a drop-list silently leaks any field added
later; an allowlist fails closed). It computes the tier from the raw fields,
then **never references** μ/σ again:

```
def public_profile(%{} = screen) do
  %{tier: tier, provisional: provisional} = Rating.Tier.classify(screen)

  %{
    user_id: screen.user_id,

    # Headline lifetime stats
    games_played: screen.games_played,
    wins: screen.wins,
    losses: screen.losses,
    win_rate: screen.win_rate,
    first_seen_at: screen.first_seen_at,
    account_age_days: screen.account_age_days,

    # Skill — tier + state ONLY (μ/σ derived away here, never emitted)
    skill: %{tier: tier, provisional: provisional},

    # Veteran
    veteran: %{
      level: screen.veteran_level,
      xp: screen.veteran_xp,
      title: screen.veteran_title,
      progress: screen.veteran_progress
    },

    # Heritage (already a display list)
    heritage: screen.heritage,

    # Playstyle (display view; raw counters NOT carried)
    playstyle: %{
      bidding_win_rate: screen.bidding_win_rate,
      aggression_needle: screen.aggression_needle,
      aggression_label: screen.aggression_label,
      aggression_insufficient: screen.aggression_insufficient,
      avg_winning_bid: screen.avg_winning_bid
    },

    # Mastery
    achievements: screen.achievements,
    achievements_catalog: screen.achievements_catalog
  }
end
```

**Explicitly DROPPED internals (present in `get_profile_for_screen/1`, absent
from the response):**

| Dropped field | Why |
|---|---|
| `rating_mu` | Raw skill internal. Acceptance: NOT exposed. |
| `rating_sigma` | Raw skill internal. Acceptance: NOT exposed. |
| `rating_games_count` | Raw rating internal (consumed only to classify the tier). |
| `playstyle_bidding_wins` | Raw accumulator; the derived `playstyle` view replaces it. |
| `playstyle_bidding_attempts` | Raw accumulator. |
| `heritage_flags` | Raw stored flag map; `heritage` (display list) is the public view. |

The tier inputs (`rating_mu`/`rating_sigma`/`rating_games_count`) flow ONLY into
`Rating.Tier.classify/1` and are then dropped — this is the whole point of the
allowlist.

### Tier injection

`Rating.Tier.classify/1` has a map overload (`tier.ex:94`) that reads exactly
`:rating_mu` / `:rating_sigma` / `:rating_games_count` — the same atom keys
`get_profile_for_screen/1` returns. So `Rating.Tier.classify(screen)` works
directly on the map with no adapter. It returns `%{tier:, provisional:}` where
`tier ∈ :provisional | :bronze | :silver | :gold | :platinum | :master`. A
fresh / never-rated user (count 0) classifies as `%{tier: :provisional,
provisional: true}` by the provisional gate (`games_count < 10`), which is the
correct default. We add `alias PidroServer.Rating.Tier` (or reference
`Rating.Tier`) in `profiles.ex` — `Rating` is already aliased.

## Public payload — worked example JSON

Snake_case keys, `%{data: ...}` envelope (matches `UserController.stats`).
`first_seen_at` is a `DateTime` → Jason encodes ISO8601. `veteran.progress` is
`{into, span}` (encodes as a 2-element JSON array) or `"max"` at the cap.
`playstyle.bidding_win_rate` / `avg_winning_bid` are `null` when insufficient
data.

```json
{
  "data": {
    "user_id": "b1f0c2e4-1111-2222-3333-444455556666",
    "games_played": 42,
    "wins": 25,
    "losses": 17,
    "win_rate": 0.595,
    "first_seen_at": "2025-11-02T08:14:00Z",
    "account_age_days": 217,
    "skill": { "tier": "gold", "provisional": false },
    "veteran": {
      "level": 7,
      "xp": 1480,
      "title": "Seasoned",
      "progress": [120, 210]
    },
    "heritage": [
      { "key": "played_pidro_one", "label": "Pidro 1 Veteran", "value": true },
      { "key": "founding_member", "label": "Founding Member", "value": true }
    ],
    "playstyle": {
      "bidding_win_rate": 0.61,
      "aggression_needle": 0.72,
      "aggression_label": "Aggressive",
      "aggression_insufficient": false,
      "avg_winning_bid": 9.4
    },
    "achievements": [
      {
        "key": "first_win",
        "name": "First Win",
        "description": "Win your first game",
        "tier": 1,
        "awarded_at": "2025-11-05T19:30:00Z"
      }
    ],
    "achievements_catalog": [
      { "key": "first_win", "name": "First Win", "description": "Win your first game", "tier": 1, "earned": true },
      { "key": "ten_wins",  "name": "Ten Wins",  "description": "Win ten games",       "tier": 2, "earned": false }
    ]
  }
}
```

Fresh / never-played user (sane defaults): `games_played/wins/losses` `0`,
`win_rate` `0.0`, `skill` `{tier: "provisional", provisional: true}`, `veteran`
`{level: 1, xp: 0, title: <level-1 title>, progress: [0, <span>]}`, `heritage`
`[]`, `playstyle.bidding_win_rate`/`avg_winning_bid` `null`,
`aggression_insufficient` `true`, `aggression_needle` `0.5`, `achievements`
`[]`, `achievements_catalog` all `earned: false`.

## Docs — "alongside the existing API" (OpenApiSpex)

The API is documented via OpenApiSpex (`/api/openapi` spec, `/api/swagger` UI);
`ApiSpec` auto-discovers routes from each action's `operation/2`. Three edits:

1. **`operation(:show, ...)` on `ProfileController`** — copy the `:stats`
   operation block shape (`user_controller.ex:32`): `summary`, `description`
   (list the sections returned + that μ/σ are intentionally NOT exposed —
   tier + state only), `security: [%{"bearer" => []}]`, `responses:` with
   `ok: {"...", "application/json", ProfileSchemas.PlayerProfileResponse}` and
   `unauthorized: {"...", "application/json", ErrorSchemas.unauthorized_error()}`.

2. **New schema `ProfileSchemas.PlayerProfileResponse`** in
   `apps/pidro_server/lib/pidro_server_web/schemas/profile_schemas.ex` — copy the
   `UserSchemas.UserStatsResponse` shape (a `data`-wrapped object with typed
   snake_case properties + an `example`). Model the nested objects (`skill`,
   `veteran`, `playstyle`) and arrays (`heritage`, `achievements`,
   `achievements_catalog`). Key details:
   - `skill.tier`: `type: :string`, `enum: ["provisional","bronze","silver",
     "gold","platinum","master"]`; `skill.provisional`: boolean.
   - `veteran.progress`: document as `oneOf` array `[integer, integer]` or the
     string `"max"` (or simplest: `nullable`/`type: :array` with a note) — keep
     it honest to the `{into, span} | :max` shape.
   - `bidding_win_rate` / `avg_winning_bid`: `nullable: true`.
   - **No `rating_mu` / `rating_sigma` / `rating_games_count` properties** — the
     schema itself documents the exclusion.
   - `example`: the worked JSON above.
   New file → place `defmodule ProfileSchemas do ... PlayerProfileResponse ...`
   matching the `UserSchemas`/`RoomSchemas` module layout.

3. **`mix.exs` `groups_for_modules`** — add
   `PidroServerWeb.API.ProfileController` to the `"Web Controllers"` list
   (`mix.exs:38`) so it appears under "Web Controllers" in `mix docs`.

No standalone `.md` API doc exists (prose lives in `operation`/schemas), so this
fully satisfies "documented alongside the existing API."

## Tests

### Controller test — `test/pidro_server_web/controllers/api/profile_controller_test.exs`

`use PidroServerWeb.ConnCase, async: false`; auth via
`put_req_header("authorization", "Bearer #{Token.generate(user)}")` with
`AccountsFixtures.user_fixture/0` and `PidroServer.Accounts.Token`; verified
routes `~p"/api/v1/profile"`; assert through `json_response(conn, status)` then
the `"data"` envelope (string keys).

1. **Authed 200 returns all sections.** A user (lazily-created profile) →
   `data = json_response(conn, 200)["data"]`. Assert presence of `"games_played"`,
   `"wins"`, `"losses"`, `"win_rate"`, `"first_seen_at"`, `"account_age_days"`,
   `"skill"`, `"veteran"`, `"heritage"`, `"playstyle"`, `"achievements"`,
   `"achievements_catalog"`. Assert nested keys exist (`data["skill"]["tier"]`,
   `data["veteran"]["level"]`, `data["playstyle"]["avg_winning_bid"]` present as
   a key).
2. **μ/σ ABSENT (the security contract).**
   `refute Map.has_key?(data, "rating_mu")`,
   `refute Map.has_key?(data, "rating_sigma")`,
   `refute Map.has_key?(data, "rating_games_count")`. Also
   `refute Map.has_key?(data["skill"], "rating_mu")` etc., and
   `refute Map.has_key?(data, "heritage_flags")` /
   `refute Map.has_key?(data, "playstyle_bidding_wins")`.
3. **Tier + provisional present.** `assert data["skill"]["tier"]` is a string in
   the enum; `assert is_boolean(data["skill"]["provisional"])`.
4. **Unauthed → 401.** `get(conn, ~p"/api/v1/profile")` with no auth header →
   `json_response(conn, 401)` (the `Authenticate` plug halts).
5. **Fresh / never-played user → sane defaults / provisional.** New user, no
   games: `data["games_played"] == 0`, `data["win_rate"] == 0.0`,
   `data["skill"] == %{"tier" => "provisional", "provisional" => true}`,
   `data["heritage"] == []`, `data["playstyle"]["bidding_win_rate"] == nil`,
   `data["playstyle"]["aggression_insufficient"] == true`,
   `data["achievements"] == []`.
6. **Migrated user shows veteran + heritage.** Build a user, call
   `Profiles.import_legacy_progression(user, legacy)` (a `LegacyProgression`
   with XP + `founding_member`), then hit the endpoint. Assert
   `data["veteran"]["level"] > 1` (or `xp` matches), `data["veteran"]["title"]`
   present, and `data["heritage"]` includes the `"played_pidro_one"` /
   `"founding_member"` badges. Skill still `provisional` (migration seeds no
   rating).

### Unit test — `test/pidro_server/profiles/profiles_test.exs` (extend)

`Profiles.public_profile/1`:
- **μ/σ exclusion is structural.** Build a screen map (or call
  `get_profile_for_screen/1`) and assert
  `refute Map.has_key?(public_profile(screen), :rating_mu)` /
  `:rating_sigma` / `:rating_games_count` / `:heritage_flags` /
  `:playstyle_bidding_wins` / `:playstyle_bidding_attempts`.
- **Tier injection.** A screen map with rated, non-provisional μ/σ (e.g.
  `rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50`) →
  `public_profile(...).skill == %{tier: :gold, provisional: false}`. A
  count-0 map → `%{tier: :provisional, provisional: true}`.
- **Field mapping.** `veteran`, `playstyle`, `heritage`, `achievements`,
  headline stats are carried through unchanged from the screen map.

## Ordered checklist

1. Add `Profiles.public_profile/1` to `profiles.ex` (explicit allowlist; tier
   via `Rating.Tier.classify/1`; drops μ/σ + raw counters + heritage_flags).
2. Add the profiles unit tests for `public_profile/1` (μ/σ exclusion + tier).
3. Create `PidroServerWeb.API.ProfileController` with `show/2`,
   `action_fallback`, `tags`, and the `operation(:show, ...)` spec.
4. Create `PidroServerWeb.Schemas.ProfileSchemas.PlayerProfileResponse`.
5. Add the route `get "/profile", ProfileController, :show` to the
   `:api_authenticated` scope in `router.ex`.
6. Register `PidroServerWeb.API.ProfileController` in `mix.exs`
   `groups_for_modules` → `"Web Controllers"`.
7. Write `profile_controller_test.exs` (200 all-sections, μ/σ absent, tier
   present, 401, fresh-user defaults, migrated-user veteran+heritage).
8. `mix precommit` (format, compile, test, dialyzer, credo). Spot-check
   `/api/swagger` shows the Profiles endpoint.

## Files to create / modify

**Create:**
- `apps/pidro_server/lib/pidro_server_web/controllers/api/profile_controller.ex`
- `apps/pidro_server/lib/pidro_server_web/schemas/profile_schemas.ex`
- `apps/pidro_server/test/pidro_server_web/controllers/api/profile_controller_test.exs`

**Modify:**
- `apps/pidro_server/lib/pidro_server/profiles/profiles.ex` — add
  `public_profile/1` (+ `Rating.Tier` reference).
- `apps/pidro_server/lib/pidro_server_web/router.ex` — add the route.
- `apps/pidro_server/mix.exs` — `groups_for_modules` entry.
- `apps/pidro_server/test/pidro_server/profiles/profiles_test.exs` — add
  `public_profile/1` unit tests.
</content>
</invoke>
