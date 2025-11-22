# Pidro Server - Deployment Guide

**Version**: 1.0.0
**Last Updated**: 2025-11-02
**Target**: Production deployment with Mix releases

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Configuration](#environment-configuration)
3. [Building a Release](#building-a-release)
4. [Deployment Options](#deployment-options)
5. [Database Setup](#database-setup)
6. [Running the Server](#running-the-server)
7. [Health Checks & Monitoring](#health-checks--monitoring)
8. [Troubleshooting](#troubleshooting)
9. [Scaling & Performance](#scaling--performance)

---

## Prerequisites

### Required Software

- **Elixir**: 1.15 or higher
- **Erlang/OTP**: 26 or higher
- **PostgreSQL**: 14 or higher
- **Node.js**: 18 or higher (for asset compilation)

### Production Server Requirements

- **CPU**: Minimum 2 cores (recommended 4+ for production)
- **RAM**: Minimum 2GB (recommended 4GB+)
- **Disk**: 1GB+ for application and logs
- **Network**: Stable internet connection for WebSocket support

---

## Environment Configuration

### Required Environment Variables

Create a `.env.prod` file or set these in your deployment environment:

```bash
# Database
DATABASE_URL="postgresql://username:password@localhost/pidro_prod"
POOL_SIZE=10

# Server
PHX_HOST="your-domain.com"
PORT=4000
SECRET_KEY_BASE="generate_with_mix_phx_gen_secret"

# Admin Panel (optional but recommended)
ADMIN_USERNAME="admin"
ADMIN_PASSWORD="generate_secure_password"

# Release
RELEASE_NODE="pidro_server@127.0.0.1"
```

### Generating Secrets

```bash
# Generate SECRET_KEY_BASE (64 bytes)
mix phx.gen.secret

# Generate a secure admin password
openssl rand -base64 32
```

---

## Building a Release

### Step 1: Prepare Assets

From the pidro_server directory:

```bash
# Install dependencies
mix deps.get --only prod

# Compile application
MIX_ENV=prod mix compile

# Prepare and compile assets
MIX_ENV=prod mix assets.deploy
```

### Step 2: Build the Release

From the **umbrella root** directory (pidro_backend):

```bash
# Build the release
MIX_ENV=prod mix release pidro_server

# The release will be created in:
# _build/prod/rel/pidro_server/
```

### Step 3: Verify the Release

```bash
# Check the release was built successfully
ls -la _build/prod/rel/pidro_server/

# You should see:
# - bin/        (executable scripts)
# - lib/        (compiled BEAM files)
# - releases/   (release metadata)
```

---

## Deployment Options

### Option 1: Local/VPS Deployment

**Deploy to a Linux server (Ubuntu/Debian)**

1. **Copy the release to your server:**

```bash
# From your local machine
scp -r _build/prod/rel/pidro_server user@your-server:/opt/
```

2. **Set up environment variables on the server:**

```bash
# Create /opt/pidro_server/.env
cat > /opt/pidro_server/.env << 'EOF'
DATABASE_URL=postgresql://...
PHX_HOST=your-domain.com
PORT=4000
SECRET_KEY_BASE=your_secret_here
POOL_SIZE=10
EOF
```

3. **Create a systemd service:**

```bash
sudo nano /etc/systemd/system/pidro_server.service
```

```ini
[Unit]
Description=Pidro Server
After=network.target postgresql.service

[Service]
Type=forking
User=pidro
Group=pidro
WorkingDirectory=/opt/pidro_server
EnvironmentFile=/opt/pidro_server/.env
Environment="MIX_ENV=prod"
ExecStart=/opt/pidro_server/bin/pidro_server start
ExecStop=/opt/pidro_server/bin/pidro_server stop
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/pidro_server/stdout.log
StandardError=append:/var/log/pidro_server/stderr.log

[Install]
WantedBy=multi-user.target
```

4. **Enable and start the service:**

```bash
sudo systemctl enable pidro_server
sudo systemctl start pidro_server
sudo systemctl status pidro_server
```

### Option 2: Docker Deployment

**Create a Dockerfile:**

```dockerfile
# Build stage
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4 AS build

# Install build dependencies
RUN apk add --no-cache git nodejs npm postgresql-client

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV=prod

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config
COPY apps/pidro_engine/mix.exs apps/pidro_engine/
COPY apps/pidro_server/mix.exs apps/pidro_server/

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY apps apps

# Compile assets
WORKDIR /app/apps/pidro_server
RUN mix assets.deploy

# Build release
WORKDIR /app
RUN mix release pidro_server

# Runtime stage
FROM alpine:3.18.4 AS app

# Install runtime dependencies
RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

# Copy built release from build stage
COPY --from=build /app/_build/prod/rel/pidro_server ./

# Create non-root user
RUN addgroup -g 1000 pidro && \
    adduser -D -u 1000 -G pidro pidro && \
    chown -R pidro:pidro /app

USER pidro

ENV HOME=/app

EXPOSE 4000

CMD ["/app/bin/pidro_server", "start"]
```

**Create docker-compose.yml:**

```yaml
version: '3.8'

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: pidro
      POSTGRES_PASSWORD: pidro_password
      POSTGRES_DB: pidro_prod
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pidro"]
      interval: 10s
      timeout: 5s
      retries: 5

  pidro_server:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://pidro:pidro_password@db/pidro_prod
      PHX_HOST: localhost
      PORT: 4000
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      POOL_SIZE: 10
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
    ports:
      - "4000:4000"
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

volumes:
  postgres_data:
```

**Deploy with Docker:**

```bash
# Build and start
docker-compose up -d

# Run migrations
docker-compose exec pidro_server bin/pidro_server eval "PidroServer.Release.migrate()"

# View logs
docker-compose logs -f pidro_server
```

### Option 3: Fly.io Deployment

**Create fly.toml:**

```toml
app = "pidro-server"
primary_region = "sjc"

[build]

[env]
  PHX_HOST = "pidro-server.fly.dev"
  PORT = "8080"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1

[[services]]
  protocol = "tcp"
  internal_port = 8080

  [[services.ports]]
    port = 80
    handlers = ["http"]

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]

  [services.concurrency]
    type = "connections"
    hard_limit = 1000
    soft_limit = 1000

[[vm]]
  size = "shared-cpu-1x"
  memory = "1gb"
```

**Deploy to Fly.io:**

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Login
fly auth login

# Launch app (creates Postgres database)
fly launch

# Deploy
fly deploy

# Run migrations
fly ssh console -C "/app/bin/pidro_server eval 'PidroServer.Release.migrate()'"

# Open in browser
fly open
```

---

## Database Setup

### Running Migrations

**Using Mix release:**

```bash
# Add a migration task to lib/pidro_server/release.ex
defmodule PidroServer.Release do
  @app :pidro_server

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

**Run migrations:**

```bash
# On your production server
/opt/pidro_server/bin/pidro_server eval "PidroServer.Release.migrate()"
```

### Database Backup

```bash
# Backup
pg_dump -U pidro pidro_prod > backup_$(date +%Y%m%d_%H%M%S).sql

# Restore
psql -U pidro pidro_prod < backup_20250102_120000.sql
```

---

## Running the Server

### Starting the Server

```bash
# Start in foreground (useful for debugging)
./bin/pidro_server start

# Start as daemon
./bin/pidro_server daemon

# Start with IEx console (for debugging)
./bin/pidro_server start_iex
```

### Stopping the Server

```bash
# Graceful stop
./bin/pidro_server stop

# Force stop (if graceful fails)
./bin/pidro_server pid | xargs kill -9
```

### Checking Status

```bash
# Check if running
./bin/pidro_server pid

# Connect to running instance (remote console)
./bin/pidro_server remote
```

---

## Health Checks & Monitoring

### Health Check Endpoint

The server doesn't have a dedicated health endpoint yet. You can check:

```bash
# Check HTTP endpoint
curl http://localhost:4000/

# Check WebSocket (using wscat)
wscat -c ws://localhost:4000/socket
```

### Monitoring Metrics

Access the LiveDashboard at:

```
https://your-domain.com/dev/dashboard
```

**Important**: Secure the dashboard in production! Add authentication:

```elixir
# In router.ex
import Phoenix.LiveDashboard.Router

scope "/admin" do
  pipe_through [:browser, :admin_auth]

  live_dashboard "/dashboard", metrics: PidroServerWeb.Telemetry
end
```

### Log Files

```bash
# Systemd logs
journalctl -u pidro_server -f

# Or if using custom log directory
tail -f /var/log/pidro_server/stdout.log
tail -f /var/log/pidro_server/stderr.log
```

---

## Troubleshooting

### Common Issues

#### 1. Server won't start

```bash
# Check logs
journalctl -u pidro_server -n 100

# Common causes:
# - Database not accessible (check DATABASE_URL)
# - Port already in use (check PORT setting)
# - Missing SECRET_KEY_BASE
```

#### 2. Database connection errors

```bash
# Test database connection
psql $DATABASE_URL

# Check pool size
# Increase POOL_SIZE if you see "connection timeout" errors
```

#### 3. WebSocket connections failing

```bash
# Check firewall allows WebSocket connections
sudo ufw status

# Ensure reverse proxy is configured for WebSocket
# For nginx:
location /socket {
    proxy_pass http://localhost:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

#### 4. Assets not loading

```bash
# Rebuild assets
MIX_ENV=prod mix assets.deploy

# Check static file serving in production config
# config/prod.exs should have:
config :pidro_server, PidroServerWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"
```

### Debug Mode

```bash
# Enable debug logging
export LOG_LEVEL=debug
./bin/pidro_server start_iex

# Or in config/runtime.exs:
config :logger, level: :debug
```

---

## Scaling & Performance

### Horizontal Scaling

For multiple servers, you'll need:

1. **Load balancer** (nginx, HAProxy, or cloud LB)
2. **Shared database** (managed PostgreSQL)
3. **Distributed Elixir** (optional for clustering)

**Basic nginx load balancer:**

```nginx
upstream pidro_servers {
    least_conn;
    server server1.example.com:4000;
    server server2.example.com:4000;
    server server3.example.com:4000;
}

server {
    listen 80;
    server_name pidro.example.com;

    location / {
        proxy_pass http://pidro_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### Vertical Scaling

Adjust these environment variables:

```bash
# Increase database pool
POOL_SIZE=20

# Adjust Erlang scheduler threads (default: # of CPU cores)
# Set in vm.args or RELEASE_DISTRIBUTION
+S 4:4

# Increase max processes (default 1M)
+P 2000000
```

### Performance Tuning

**Database optimization:**

```sql
-- Add indexes for common queries
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_game_stats_completed ON game_stats(completed_at DESC);
```

**Connection limits:**

```elixir
# config/runtime.exs
config :pidro_server, PidroServer.Repo,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  queue_target: 50,
  queue_interval: 1000
```

---

## CORS Configuration

For mobile clients (React Native/Expo), add CORS support:

**Add corsica dependency** (optional, Phoenix has built-in support):

```elixir
# In endpoint.ex
defmodule PidroServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pidro_server

  # Add before router
  plug Corsica,
    origins: ["*"],  # Or specific domains: ["https://app.example.com"]
    allow_headers: ["Authorization", "Content-Type"],
    allow_methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  # ... rest of plugs
end
```

**Or use CORSPlug:**

```elixir
# mix.exs
{:cors_plug, "~> 3.0"}

# endpoint.ex
plug CORSPlug, origin: ["*"]
```

---

## Security Checklist

- [ ] Change default admin credentials
- [ ] Use strong SECRET_KEY_BASE (64+ characters)
- [ ] Enable HTTPS in production
- [ ] Set secure cookie flags
- [ ] Limit database access to app server IPs
- [ ] Enable firewall (only ports 80, 443, 22 open)
- [ ] Regular security updates (Elixir, Erlang, dependencies)
- [ ] Enable rate limiting for API endpoints
- [ ] Rotate secrets periodically
- [ ] Use environment variables (never commit secrets)

---

## Production Checklist

### Pre-deployment

- [ ] All tests passing (`mix test`)
- [ ] No Credo warnings (`mix credo --strict`)
- [ ] No Dialyzer errors (`mix dialyzer`)
- [ ] Assets compiled (`mix assets.deploy`)
- [ ] Database migrations tested
- [ ] Environment variables configured
- [ ] Secrets generated and secured

### Post-deployment

- [ ] Database migrations run successfully
- [ ] Health checks passing
- [ ] WebSocket connections working
- [ ] Admin panel accessible
- [ ] Logs being collected
- [ ] Monitoring configured
- [ ] Backups scheduled
- [ ] SSL certificate valid

---

## Support & Resources

- **Documentation**: See README.md and specs/pidro_server_specification.md
- **Phoenix Deployment Guide**: https://hexdocs.pm/phoenix/deployment.html
- **Fly.io Elixir Guide**: https://fly.io/docs/elixir/
- **Docker Hub**: https://hub.docker.com/r/hexpm/elixir

---

**Last Updated**: 2025-11-02
**Maintainer**: Pidro Development Team
