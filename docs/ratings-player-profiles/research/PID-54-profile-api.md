---
date: 2026-06-07
ticket: PID-54
status: complete
---

# PID-54 — Player profile API (research, as-is)

## Summary

Everything PID-54 needs to expose is already assembled server-side by
`PidroServer.Profiles.get_profile_for_screen/1` — lifetime stats, win_rate, Veteran
level/XP/title/progress, Heritage display, Playstyle meter + avg bid, and the Mastery
achievements list. **No REST endpoint exposes it yet** — `get_profile_for_screen/1` is
only called from tests today (no controller, no router route). So PID-54 is two things:
(1) add ONE authenticated endpoint that serves this map, and (2) close the **skill-tier
gap** — `get_profile_for_screen/1` currently returns the **raw `rating_mu` / `rating_sigma`
/ `rating_games_count`** internals and does **NOT** call `Rating.Tier.classify/1`. PID-54
must add the tier+provisional classification and STOP emitting μ/σ in the client payload.
The `Rating.Tier.classify/1` profile-map overload already exists for exactly this call site.

The existing API surface is small and consistent: routes live under `/api/v1` in
`router.ex`, authenticated routes go through the `:api_authenticated` pipeline (the
`Authenticate` Bearer-token plug → `conn.assigns.current_user`), responses are wrapped in a
`%{data: ...}` envelope with snake_case keys, rendered either via `json/2` (UserController)
or a `*JSON` view module (AuthController/RoomController). Docs are OpenApiSpex `operation/2`
+ `Schemas` modules surfaced at `/api/openapi` and `/api/swagger`.

---

## API surface + conventions

### Router — `apps/pidro_server/lib/pidro_server_web/router.ex`

Two API pipelines (lines 17–25):

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug OpenApiSpex.Plug.PutApiSpec, module: PidroServerWeb.ApiSpec
end

pipeline :api_authenticated do
  plug :accepts, ["json"]
  plug PidroServerWeb.Plugs.Authenticate
end
```

The **authenticated** API scope (lines 56–80) — this is where a new profile route belongs:

```elixir
# API v1 authenticated routes
scope "/api/v1", PidroServerWeb.API do
  pipe_through :api_authenticated

  get "/auth/me", AuthController, :me
  get "/rooms/:code/state", RoomController, :state
  get "/users/me/stats", UserController, :stats
  get "/lobby", RoomController, :lobby
  post "/rooms", RoomController, :create
  # ... room/spectator routes
end
```

The closest precedent for a profile endpoint is `get "/users/me/stats"` →
`UserController.stats` (the authenticated, "own data" pattern). A profile route would
naturally be e.g. `get "/users/me/profile"` (own) and/or `get "/users/:id/profile"` (other).

OpenAPI doc routes live in a separate `/api` scope (lines 35–40): `/api/openapi`
(`RenderSpec`) and `/api/swagger` (`SwaggerUI`).

### Controllers — `apps/pidro_server/lib/pidro_server_web/controllers/api/`

`auth_controller.ex`, `user_controller.ex`, `room_controller.ex` (+ `room_json.ex`,
`user_json.ex`), `fallback_controller.ex`. All use `use PidroServerWeb, :controller` +
`use OpenApiSpex.ControllerSpecs`, declare `action_fallback PidroServerWeb.API.FallbackController`,
a `tags([...])`, and an `operation(:action, ...)` spec per action.

**Representative GET action** — `UserController.stats/2`
(`user_controller.ex:91–98`) is the best template (authenticated, own-data, plain `json/2`):

```elixir
def stats(conn, _params) do
  user_id = conn.assigns.current_user.id
  stats = Stats.get_user_stats(user_id)

  conn
  |> put_status(:ok)
  |> json(%{data: stats})
end
```

So `stats` returns a **bare context map wrapped in `%{data: ...}`** via `json/2` — no view
module. The alternative render style is a `*JSON` view: `AuthController.me/2`
(`auth_controller.ex:270–276`) does `conn |> put_view(UserJSON) |> render(:show, %{user: user})`,
and `UserJSON.show/1` (`user_json.ex:24–30`) returns `%{data: %{user: user(user)}}`.

### Envelope + casing

- **Success envelope:** `%{data: <payload>}` — universal (`user_json.ex`,
  `UserController.stats`, `RoomController`). For PID-54, `json(%{data: profile_map})` is the
  zero-friction match to `stats`.
- **Error envelope:** `%{errors: [%{code, title, detail}, ...]}` — see
  `fallback_controller.ex` (changeset traversal → 422; `:not_found` → 404; `:invalid_credentials`
  / 401-style cases). Unauthorized from the plug renders `ErrorJSON "401.json"`.
- **Key casing:** **snake_case** everywhere (`games_played`, `win_rate`,
  `total_duration_seconds`, `inserted_at`). `get_profile_for_screen/1` already returns
  snake_case atom keys, which Jason serializes as snake_case strings. No camelCase transform
  exists. (Matches PID-52 research.)
- Timestamps are serialized as ISO8601 strings explicitly where a view touches them
  (`user_json.ex:58` `DateTime.to_iso8601/1`); `get_profile_for_screen` returns raw
  `DateTime` for `first_seen_at` (Jason encodes it ISO8601 by default).

---

## Auth + whose profile

- **Pipeline:** `:api_authenticated` → `plug PidroServerWeb.Plugs.Authenticate`
  (`apps/pidro_server/lib/pidro_server_web/plugs/authenticate.ex`).
- **Mechanism:** extracts `Authorization: Bearer <token>` (only the exact `["Bearer", token]`
  split is accepted), `Token.verify/1` → user_id, `Auth.get_user/1` → user, then
  `assign(conn, :current_user, user)` (lines 94–107). On any failure: `put_status(:unauthorized)`
  → `ErrorJSON "401.json"` → `halt()`.
- **Current user in controllers:** `conn.assigns.current_user` (a `%User{}`).
  `UserController.stats` uses `conn.assigns.current_user.id`; `AuthController.me` uses
  `conn.assigns[:current_user]`.
- **Whose-profile available today:** Only the authenticated user's own id is naturally
  available (`conn.assigns.current_user.id`). The **"own data" pattern is the established one**
  — `/users/me/stats` and `/auth/me` both serve only the caller; there is **no existing
  "view another player's profile by id" endpoint**. `get_profile_for_screen/1` takes any
  `user_id`, so a public `/users/:id/profile` is mechanically trivial, but no current route
  or controller exposes another user's data, so PID-54 introducing one would be net-new
  (no precedent for authorization rules on other-user reads). The minimal acceptance ("own
  profile") is served by `conn.assigns.current_user.id`.

---

## `get_profile_for_screen/1` current fields (full list) + skill-tier gap

`PidroServer.Profiles.get_profile_for_screen/1` —
`apps/pidro_server/lib/pidro_server/profiles/profiles.ex:184–235`. Lazily creates the row,
loads achievements, derives playstyle, returns `{:ok, map}`. The full return map (lines
199–233):

```elixir
{:ok,
 %{
   user_id: profile.user_id,
   games_played: profile.games_played,
   wins: profile.wins,
   losses: profile.losses,
   win_rate: win_rate(profile.wins, profile.games_played),
   rating_mu: profile.rating_mu,                 # <-- RAW μ (internal — must NOT ship)
   rating_sigma: profile.rating_sigma,           # <-- RAW σ (internal — must NOT ship)
   rating_games_count: profile.rating_games_count,
   veteran_level: Progression.level_for_xp(profile.veteran_xp),
   veteran_xp: profile.veteran_xp,
   veteran_title: Progression.title_for_level(Progression.level_for_xp(profile.veteran_xp)),
   veteran_progress: Progression.level_progress(profile.veteran_xp),
   playstyle_bidding_wins: profile.playstyle_bidding_wins,
   playstyle_bidding_attempts: profile.playstyle_bidding_attempts,
   bidding_win_rate: if(rate == :insufficient, do: nil, else: rate),
   aggression_needle: needle,
   aggression_label: Playstyle.label(needle),
   aggression_insufficient: rate == :insufficient,
   avg_winning_bid:
     Playstyle.avg_winning_bid(profile.avg_winning_bid_sum, profile.avg_winning_bid_count),
   heritage_flags: profile.heritage_flags,
   heritage: Heritage.display(profile.heritage_flags),
   first_seen_at: first_seen_at,
   account_age_days: account_age_days(first_seen_at),
   achievements: screen_achievements(earned),
   achievements_catalog: screen_catalog(earned_keys)
 }}
```

Field-by-field:

| Field | Source | Notes |
|---|---|---|
| `user_id` | `profile.user_id` | |
| `games_played` / `wins` / `losses` | stored counters (PID-44) | lifetime |
| `win_rate` | `win_rate/2` derived | `0.0` when no games |
| `rating_mu` | **raw stored μ** | **INTERNAL — leaks today** |
| `rating_sigma` | **raw stored σ** | **INTERNAL — leaks today** |
| `rating_games_count` | stored count | rated-game count |
| `veteran_level` | recomputed from XP | canonical, not the cache |
| `veteran_xp` | stored | |
| `veteran_title` | `Progression.title_for_level/1` | |
| `veteran_progress` | `Progression.level_progress/1` | |
| `playstyle_bidding_wins` / `_attempts` | raw counters | internal-ish raw counters |
| `bidding_win_rate` | derived; `nil` if insufficient | |
| `aggression_needle` | `Playstyle.needle(rate)` | the meter |
| `aggression_label` | `Playstyle.label(needle)` | |
| `aggression_insufficient` | `rate == :insufficient` | |
| `avg_winning_bid` | `Playstyle.avg_winning_bid/2` | |
| `heritage_flags` | raw stored map | |
| `heritage` | `Heritage.display/1` | display view |
| `first_seen_at` | `User.inserted_at` | `DateTime` |
| `account_age_days` | derived | |
| `achievements` | `screen_achievements/1` | earned, joined to Catalog (key/name/description/tier/awarded_at) |
| `achievements_catalog` | `screen_catalog/1` | active catalog + `earned` flag |

### Skill-tier gap (the core PID-54 work)

`get_profile_for_screen/1` does **NOT** call `Rating.Tier.classify/1` — there is no `tier`
or `provisional` key in the return map. A grep for `Tier` / `classify` in `profiles.ex`
returns nothing. Instead it emits the **raw `rating_mu`/`rating_sigma`/`rating_games_count`**.
So PID-54 must:

1. Call `Rating.Tier.classify(profile)` (the map overload, see below) to get
   `%{tier:, provisional:}`.
2. Add `tier` + `provisional` to the client payload.
3. **Remove** `rating_mu` and `rating_sigma` from the client-facing map (and likely
   `rating_games_count`, an internal). Acceptance: "raw rating internals (μ/σ) NOT exposed
   (only tier + state)."

Whether to change `get_profile_for_screen/1` itself or build a separate client-facing
serializer that drops μ/σ is an open design choice (see Open Questions).

---

## `Rating.Tier` API — `apps/pidro_server/lib/pidro_server/rating/tier.ex`

Pure module, no DB. Returns `%{tier: tier(), provisional: boolean()}` where `tier` is
`:provisional | :bronze | :silver | :gold | :platinum | :master`.

- **`classify(mu, sigma, games_count)`** (lines 66–73): if `provisional?(sigma, games_count)`
  returns `%{tier: :provisional, provisional: true}`; else `%{tier: band_for(Rating.ordinal({mu, sigma})), provisional: false}`.
  Band is read off `Rating.ordinal/1` (`mu - 3*sigma`), so uncertainty is priced in.
- **`classify(profile_map)`** — the PID-54 overload (lines 94–100):

```elixir
def classify(%{
      rating_mu: mu,
      rating_sigma: sigma,
      rating_games_count: games_count
    }) do
  classify(mu, sigma, games_count)
end
```

  Confirmed: the overload reads exactly `:rating_mu` / `:rating_sigma` /
  `:rating_games_count` — the same atom keys `get_profile_for_screen/1` returns, so
  `Rating.Tier.classify(profile_view)` works directly on the map already built.
- **Provisional gate** (lines 110–113): `games_count < provisional_min_games (10) OR sigma >=
  provisional_max_sigma (6.0)`. Clears only when BOTH satisfied.
- Thresholds are config-tunable via `config :pidro_server, PidroServer.Rating.Tier`;
  `defaults/0` (lines 105–106) exposes them. Defaults: min_games 10, max_sigma 6.0, band
  cutoffs bronze 0 / silver 10 / gold 18 / platinum 26 / master 34.

---

## μ/σ leak check

Grep for `rating_mu` / `rating_sigma` across `lib/` (excluding the schema and the rating
math):

- **`profiles/profiles.ex:207–208`** — `get_profile_for_screen/1` returns `rating_mu` and
  `rating_sigma` in its map. **This is the one client-facing leak PID-54 must close.** Today
  no controller renders this map, so nothing reaches a client yet — but the moment PID-54
  wires an endpoint over this exact map, μ/σ would leak unless removed.
- `profiles/player_profile.ex:31–32,56–57` — Ecto schema field defs + changeset cast list
  (storage, server-side only; correct).
- `profiles/post_game_summary.ex` — uses μ/σ only as **inputs** to compute a tier move; its
  output is a tier/state summary, not raw μ/σ (PID-52, server-internal builder). Not a
  client serializer leak per se, but worth confirming its emitted shape stays tier-only.
- `rating/tier.ex` — only doc/spec references to the keys (the consumer, not a leak).

No `*JSON` view or controller currently serializes μ/σ. The only at-risk path is the
profile-screen map. **Conclusion: μ/σ are NOT leaked to any client today (no endpoint
exists); the profile-screen map carries them, so PID-54 must strip them before serving.**

---

## Controller test + API doc conventions

### Controller tests

Dir: `apps/pidro_server/test/pidro_server_web/controllers/api/` — currently only
`room_controller_test.exs` (no `user_controller_test.exs` or `auth_controller_test.exs`
present). The ConnCase pattern (`room_controller_test.exs`):

```elixir
use PidroServerWeb.ConnCase, async: false

# authenticated request:
user = AccountsFixtures.user_fixture()
conn =
  conn
  |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
  |> get(~p"/api/v1/...")

# assert JSON:
json_response(conn, 200) |> get_in(["data", "rooms"])
# or: json_response(conn, 201)["data"]["code"]
```

Key conventions: `ConnCase` provides `conn`; auth via
`put_req_header("authorization", "Bearer #{Token.generate(user)}")` with
`PidroServer.Accounts.Token` + `PidroServer.AccountsFixtures`; verified routes (`~p"/api/v1/..."`);
assertions via `json_response(conn, status)` then indexing the `"data"` envelope with string
keys. A PID-54 controller test would assert the `"data"` map includes `"tier"`/`"provisional"`
and `refute Map.has_key?(data, "rating_mu")` / `"rating_sigma"`.

There is also unit-level coverage of `get_profile_for_screen/1` in
`apps/pidro_server/test/pidro_server/profiles/profiles_test.exs` (lines 64+) and
`legacy_import_test.exs` (line 213+) — the place to assert the new tier field at the context
layer.

### API docs ("documented alongside the existing API")

The API is documented via **OpenApiSpex**, surfaced at `/api/openapi` (spec) and
`/api/swagger` (UI):

- **Spec module:** `apps/pidro_server/lib/pidro_server_web/api_spec.ex`
  (`PidroServerWeb.ApiSpec`) — `paths: Paths.from_router(Router)` auto-discovers routes from
  the per-action `operation/2` specs; `securitySchemes` defines `"bearer_auth"`.
- **Per-action docs:** each controller declares `operation(:action, summary:, description:,
  security:, responses:)` (e.g. `user_controller.ex:32–62` for `:stats`). PID-54 adds an
  `operation(:profile, ...)` to the new controller.
- **Schemas:** `apps/pidro_server/lib/pidro_server_web/schemas/` — `user_schemas.ex`,
  `room_schemas.ex`, `error_schemas.ex`. The pattern to copy is
  `UserSchemas.UserStatsResponse` (`user_schemas.ex:262–368`): a `data`-wrapped object with
  typed snake_case properties + an `example`. PID-54 would add a `PlayerProfileResponse`
  schema here (tier as a string enum, provisional boolean, the veteran/heritage/playstyle/
  achievements sub-objects — and notably NO `rating_mu`/`rating_sigma`).
- **ExDoc grouping:** `apps/pidro_server/mix.exs:37–43` `groups_for_modules` lists
  `"Web Controllers"` (AuthController, RoomController, UserController, FallbackController). A
  new profile controller should be added to that list to appear under "Web Controllers" in
  `mix docs`.

No standalone Markdown API doc file exists (the prose lives in the `ApiSpec` `info.description`
+ controller moduledocs/`operation` blocks). So "alongside the existing API" = add
`operation/2` + a `Schemas` module + the `groups_for_modules` entry, not a new `.md`.

---

## Open Questions

1. **Mutate `get_profile_for_screen/1` or add a serializer?** The cleanest "μ/σ never leaks"
   guarantee is to stop returning `rating_mu`/`rating_sigma` from `get_profile_for_screen/1`
   and instead return `tier`/`provisional` (everything downstream is a screen view anyway).
   But `post_game_summary.ex` and tests read the raw fields elsewhere — confirm no other
   consumer depends on `get_profile_for_screen` returning raw μ/σ before removing them
   (current grep shows only tests call it). Alternative: keep the context map internal and
   add a thin client serializer/view that projects tier+provisional and omits μ/σ.
2. **Own-only vs by-id?** Acceptance says "the authenticated user's own profile." Is a
   public `/users/:id/profile` (view another player) in scope for PID-54? No existing
   endpoint exposes another user's data, so authorization/privacy rules (e.g. hide email,
   hide `account_age`?) would be net-new. The ticket's "web/mobile clients" wording leans
   own-profile; confirm.
3. **Route shape:** `/api/v1/users/me/profile` (mirrors `/users/me/stats`) vs
   `/api/v1/profile`. Recommend the former for consistency.
4. **Which raw counters to keep?** Besides μ/σ, the map exposes `rating_games_count`,
   `playstyle_bidding_wins/attempts` (raw). Decide whether these stay (harmless counts) or
   are dropped to keep the payload purely "display" — the ticket only forbids μ/σ.
5. **`achievements_catalog` size:** the payload includes the full active catalog with
   `earned` flags — confirm clients want the locked-achievements view in the same call or a
   trimmed earned-only list.
</content>
</invoke>
