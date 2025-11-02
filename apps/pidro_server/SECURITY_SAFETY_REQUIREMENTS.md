# Security and Safety Requirements

## 1. Dev Routes Authentication

### Current State
- **Dev routes** (`/dev/dashboard`, `/dev/mailbox`) are **UNPROTECTED** - only enabled via config flag
- **Admin routes** (`/admin/lobby`, `/admin/games/:code`, `/admin/stats`) are **PROTECTED** with basic auth
- Admin credentials: `admin_username` and `admin_password` from config (default: "admin"/"secret")

### Requirements
✅ **REQUIRED**: Move dev routes behind authentication
- Dev routes should use same `:admin` pipeline with basic auth
- Or disable completely in production (already done via `dev_routes: true` config flag)

```elixir
# Current (INSECURE in dev):
scope "/dev" do
  pipe_through :browser  # NO AUTH!
  live_dashboard "/dashboard"
end

# Recommended:
scope "/dev" do
  pipe_through :admin  # Use basic auth like admin panel
  live_dashboard "/dashboard"
end
```

## 2. Dangerous Operations Requiring Confirmation

### CRITICAL Operations
| Operation | Location | Risk | Recommendation |
|-----------|----------|------|----------------|
| `PidroServer.Release.drop()` | [lib/pidro_server/release.ex:82](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/release.ex#L82) | **CRITICAL** - Deletes entire database | ⚠️ Require environment check + confirmation |
| `reset_for_test()` | [lib/pidro_server/games/room_manager.ex:455](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/room_manager.ex#L455) | **HIGH** - Clears all rooms/games | ⚠️ Should only work in test env |
| `close_room/1` | room_manager.ex | **MEDIUM** - Terminates room + broadcasts | ✓ OK - Part of normal flow |
| `stop_game/1` | [lib/pidro_server/games/game_supervisor.ex](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/games/game_supervisor.ex) | **MEDIUM** - Kills game process | ⚠️ Add confirmation in dev UI |

### Recommended Safeguards

```elixir
# release.ex - Add environment check
def drop do
  unless Mix.env() in [:dev, :test] do
    raise "drop/0 can only be called in dev or test environments"
  end
  
  # Require explicit confirmation
  IO.puts("WARNING: This will delete ALL data!")
  IO.puts("Type 'DELETE ALL DATA' to confirm:")
  
  case IO.gets("") |> String.trim() do
    "DELETE ALL DATA" -> 
      load_app()
      for repo <- repos(), do: repo.__adapter__().storage_down(repo.config())
      :ok
    _ -> 
      {:error, :cancelled}
  end
end

# room_manager.ex - Restrict reset_for_test
def reset_for_test do
  if Mix.env() != :test do
    raise "reset_for_test/0 can only be called in test environment"
  end
  GenServer.call(__MODULE__, :reset_for_test)
end
```

## 3. Resource Limits

### Current Limits
| Resource | Limit | Location | Configurable |
|----------|-------|----------|--------------|
| **Max players per room** | 4 | room_manager.ex:48 | ❌ Hardcoded `@max_players 4` |
| **Max spectators per room** | 10 | room_manager.ex:93 | ❌ Hardcoded default |
| **Room code length** | 4 chars | room_manager.ex:49 | ❌ Hardcoded `@room_code_length 4` |
| **Max concurrent games** | Unlimited | N/A | ❌ No limit |
| **Max concurrent bots** | Unlimited | N/A | ❌ No limit |
| **Token expiration** | 30 days | [lib/pidro_server/accounts/token.ex:87](file:///Users/marcelfahle/code/pidro/_PIDRO2/code-ralph/pidro_backend/apps/pidro_server/lib/pidro_server/accounts/token.ex#L87) | ❌ Hardcoded `@token_age_secs` |
| **DB connection pool** | 10 | config/dev.exs:11, runtime.exs:36 | ✅ ENV var `POOL_SIZE` |

### Missing Limits (REQUIRED)
- ❌ **Max rooms per user** - Users can create unlimited rooms
- ❌ **Max concurrent games** - No system-wide game limit
- ❌ **Max active connections** - No WebSocket connection limit
- ❌ **Max bot instances** - Bot spawning is unlimited
- ❌ **Room timeout** - Idle rooms never expire (memory leak risk)

### Recommended Configuration

```elixir
# config/runtime.exs
config :pidro_server,
  # Room limits
  max_rooms_per_user: String.to_integer(System.get_env("MAX_ROOMS_PER_USER") || "3"),
  max_concurrent_games: String.to_integer(System.get_env("MAX_GAMES") || "100"),
  max_spectators_per_room: String.to_integer(System.get_env("MAX_SPECTATORS") || "10"),
  
  # Connection limits
  max_connections_per_user: String.to_integer(System.get_env("MAX_CONNECTIONS") || "5"),
  
  # Bot limits
  max_bots_per_game: String.to_integer(System.get_env("MAX_BOTS_PER_GAME") || "3"),
  max_total_bots: String.to_integer(System.get_env("MAX_TOTAL_BOTS") || "50"),
  
  # Timeouts
  idle_room_timeout_minutes: String.to_integer(System.get_env("IDLE_ROOM_TIMEOUT") || "30"),
  disconnected_player_timeout_minutes: String.to_integer(System.get_env("DISCONNECT_TIMEOUT") || "5")
```

## 4. Rate Limiting

### Current State
❌ **NO RATE LIMITING IMPLEMENTED**

### Critical Endpoints Needing Rate Limits
| Endpoint | Risk | Recommended Limit |
|----------|------|-------------------|
| `POST /api/v1/auth/register` | Account spam | 5 per hour per IP |
| `POST /api/v1/auth/login` | Brute force | 10 per minute per IP |
| `POST /api/v1/rooms` | Room spam | 10 per minute per user |
| `POST /api/v1/rooms/:code/join` | Join spam | 20 per minute per user |
| WebSocket `game_channel` | Action spam | 100 per minute per user |

### Recommended Implementation

```elixir
# Add dependency to mix.exs
{:hammer, "~> 6.2"}

# Create rate limit plug
defmodule PidroServerWeb.Plugs.RateLimit do
  import Plug.Conn
  
  def call(conn, opts) do
    limit = Keyword.get(opts, :limit, 60)
    scale = Keyword.get(opts, :scale, 60_000) # 1 minute
    key = get_rate_limit_key(conn)
    
    case Hammer.check_rate(key, scale, limit) do
      {:allow, _count} -> conn
      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "Rate limit exceeded"})
        |> halt()
    end
  end
  
  defp get_rate_limit_key(conn) do
    user_id = conn.assigns[:current_user][:id] || get_client_ip(conn)
    action = Phoenix.Controller.action_name(conn)
    "rate_limit:#{action}:#{user_id}"
  end
end

# Apply in router
pipeline :api_rate_limited do
  plug :api_authenticated
  plug PidroServerWeb.Plugs.RateLimit, limit: 60, scale: 60_000
end
```

## 5. Dev UI Safety Guardrails

### Admin Panel (`/admin/*`)
**Current Features:**
- `/admin/lobby` - View all active rooms
- `/admin/games/:code` - Monitor specific game state
- `/admin/stats` - System statistics

**Missing Controls (REQUIRED):**
- ❌ No ability to terminate games
- ❌ No ability to kick players
- ❌ No ability to clear stuck rooms
- ❌ No audit logging of admin actions
- ❌ No confirmation dialogs for destructive actions

### Recommended Dev UI Guardrails

```elixir
# Add to admin LiveView
defmodule PidroServerWeb.Admin.GameControlLive do
  use PidroServerWeb, :live_view
  
  def handle_event("terminate_game", %{"code" => code, "confirm" => "true"}, socket) do
    # Log admin action
    Logger.warning("Admin #{socket.assigns.admin_user} terminated game #{code}")
    
    # Broadcast warning to players
    PidroServerWeb.Endpoint.broadcast("room:#{code}", "admin_action", %{
      action: "game_terminated",
      reason: "Admin intervention"
    })
    
    # Terminate with grace period
    GameSupervisor.stop_game(code)
    
    {:noreply, put_flash(socket, :info, "Game #{code} terminated")}
  end
  
  # Prevent accidental termination
  def handle_event("terminate_game", %{"code" => code}, socket) do
    {:noreply, assign(socket, :confirm_terminate, code)}
  end
end
```

### Required Safety Features

1. **Confirmation Dialogs**
   - All destructive actions require 2-step confirmation
   - Display affected users/games before confirming
   - Add cooldown period (3 seconds) before confirm button activates

2. **Audit Logging**
   ```elixir
   defmodule PidroServer.AdminAudit do
     def log_action(admin_user, action, target, metadata \\ %{}) do
       Logger.warning("[ADMIN] #{admin_user} performed #{action} on #{target}",
         metadata: Map.merge(metadata, %{
           admin_user: admin_user,
           action: action,
           target: target,
           timestamp: DateTime.utc_now()
         })
       )
     end
   end
   ```

3. **Rate Limits for Admin Actions**
   - Max 10 game terminations per hour
   - Max 50 player kicks per hour
   - Throttle room cleanup to prevent system overload

4. **Read-Only Mode Toggle**
   - Environment variable `ADMIN_READ_ONLY=true` disables destructive actions
   - Production should default to read-only
   - Actions show "Read-only mode" message instead of executing

5. **Action Notifications**
   - Notify affected users via WebSocket before admin action
   - 30-second grace period for games before termination
   - Broadcast system-wide alerts for major actions

## Summary Checklist

### Authentication ✅
- [x] Admin routes have basic auth
- [ ] Dev routes need authentication (or disabled in prod)
- [ ] Admin credentials should be strong (not "admin"/"secret")
- [ ] Consider replacing basic auth with proper session auth

### Dangerous Operations ⚠️
- [ ] `Release.drop()` needs environment check + confirmation
- [ ] `reset_for_test()` should only work in test env
- [ ] Admin UI needs confirmation dialogs for all destructive actions
- [ ] Add audit logging for all admin actions

### Resource Limits ❌
- [ ] Implement max rooms per user
- [ ] Implement max concurrent games system-wide
- [ ] Implement max bot instances
- [ ] Add room timeout/cleanup for idle rooms
- [ ] Make limits configurable via environment variables

### Rate Limiting ❌
- [ ] Add rate limiting library (Hammer recommended)
- [ ] Rate limit auth endpoints (registration, login)
- [ ] Rate limit room creation/joining
- [ ] Rate limit WebSocket game actions
- [ ] Rate limit admin actions

### Dev UI Safety ✓/❌
- [x] Admin panel has basic auth
- [ ] Add confirmation dialogs for destructive actions
- [ ] Add audit logging
- [ ] Add read-only mode for production
- [ ] Add grace periods before destructive actions
- [ ] Add user notifications before admin intervention
- [ ] Rate limit admin actions to prevent abuse

## Priority Recommendations

**P0 (Immediate):**
1. Move dev routes behind authentication or disable in prod
2. Add environment checks to `Release.drop()` and `reset_for_test()`
3. Change default admin credentials from "admin"/"secret"

**P1 (Before Production):**
4. Implement rate limiting on auth endpoints
5. Add max rooms per user limit
6. Add max concurrent games limit
7. Implement room timeout/cleanup

**P2 (Post-Launch):**
8. Add comprehensive admin audit logging
9. Implement bot spawning limits
10. Add connection limits per user
11. Build proper admin UI with confirmation dialogs
