defmodule PidroServerWeb.Router do
  use PidroServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PidroServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :invite_page do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {PidroServerWeb.Layouts, :invite}
    plug :put_secure_browser_headers
    plug PidroServerWeb.Plugs.RateLimit
  end

  # Credential-free URL-encoded beacon sent directly to Phoenix immediately
  # before a matching mobile store navigation. Deliberately has no session or
  # CSRF state; the controller applies exact browser-origin validation.
  pipeline :deferred_capture do
    plug :put_secure_browser_headers
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :dev_access do
    plug PidroServerWeb.Plugs.DevAccess
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PidroServerWeb.ApiSpec
    plug PidroServerWeb.Plugs.RateLimit
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug PidroServerWeb.Plugs.Authenticate
    # After Authenticate so :user policies see conn.assigns.current_user
    plug PidroServerWeb.Plugs.RateLimit
  end

  scope "/", PidroServerWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/up", HealthController, :up
  end

  scope "/", PidroServerWeb do
    pipe_through :invite_page

    get "/j/:code", InvitePageController, :show, private: %{rate_limit: [:invite_page]}
  end

  scope "/", PidroServerWeb do
    pipe_through :deferred_capture

    post "/j/:code/deferred", DeferredInviteCaptureController, :create,
      private: %{rate_limit: [:invite_capture, :invite_capture_code]}
  end

  # OpenAPI documentation routes
  scope "/api" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, spec: PidroServerWeb.ApiSpec
    get "/swagger", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  # API v1 routes
  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api

    # Auth routes without authentication. `private: %{rate_limit: [...]}` names
    # the PidroServerWeb.Plugs.RateLimit policies applied to the route.
    post "/auth/register", AuthController, :register, private: %{rate_limit: [:register]}
    post "/auth/login", AuthController, :login, private: %{rate_limit: [:login]}

    post "/auth/password-reset", AuthController, :request_password_reset,
      private: %{rate_limit: [:password_reset, :password_reset_identifier]}

    post "/auth/password-reset/confirm", AuthController, :reset_password,
      private: %{rate_limit: [:password_reset_confirm]}

    # Guest creation needs a valid invite (KD6); limited per address, per day
    # and per install id (R12).
    post "/auth/guest", AuthController, :guest,
      private: %{rate_limit: [:guest_create, :guest_create_daily, :guest_create_install]}

    # Room routes without authentication
    get "/rooms", RoomController, :index
    get "/rooms/:code", RoomController, :show, private: %{rate_limit: [:room_lookup]}

    # Invite preview for landing pages; never exposes the room code (KD2)
    get "/invites/:code", InviteController, :show, private: %{rate_limit: [:invite_preview]}
  end

  # API v1 authenticated routes
  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api_authenticated

    get "/auth/me", AuthController, :me
    delete "/auth/me", AuthController, :delete_me
    post "/auth/upgrade", AuthController, :upgrade, private: %{rate_limit: [:auth_upgrade]}

    # Game state route (authenticated to prevent hand exposure)
    get "/rooms/:code/state", RoomController, :state

    # User routes with authentication
    get "/users/me/stats", UserController, :stats

    # Player profile route with authentication (own profile)
    get "/profile", ProfileController, :show

    # Lobby route with authentication (needs user_id for rejoinable rooms)
    get "/lobby", RoomController, :lobby

    # Room routes with authentication
    post "/rooms", RoomController, :create, private: %{rate_limit: [:room_create]}
    post "/rooms/:code/join", RoomController, :join, private: %{rate_limit: [:room_join]}
    delete "/rooms/:code/leave", RoomController, :leave
    post "/rooms/:code/open-seat", RoomController, :open_seat
    post "/rooms/:code/close-seat", RoomController, :close_seat

    # Host controls for waiting rooms (R23)
    post "/rooms/:code/seat", RoomController, :seat
    post "/rooms/:code/lock", RoomController, :lock
    post "/rooms/:code/kick", RoomController, :kick

    # Invite routes (R1, R5, R6, R7); the mint bucket also covers regenerate
    post "/rooms/:code/invites", RoomController, :create_invite,
      private: %{rate_limit: [:invite_mint]}

    post "/invites/:code/redeem", InviteController, :redeem,
      private: %{rate_limit: [:invite_redeem]}

    delete "/invites/:code", InviteController, :delete

    post "/invites/:code/regenerate", InviteController, :regenerate,
      private: %{rate_limit: [:invite_mint]}

    # Spectator routes with authentication
    post "/rooms/:code/watch", RoomController, :watch
    delete "/rooms/:code/unwatch", RoomController, :unwatch
  end

  scope "/dev", PidroServerWeb.Dev do
    pipe_through [:browser, :dev_access]

    get "/emails/export.csv", EmailExportController, :index

    live_session :dev, root_layout: {PidroServerWeb.Layouts, :dev_root} do
      live "/games", GameListLive
      live "/games/:code", GameDetailLive
      live "/users", UserListLive
      live "/users/:id", UserDetailLive
      live "/emails", EmailMigrationLive
      live "/analytics", AnalyticsLive
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pidro_server, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PidroServerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Domain-association files for iOS universal links and Android app links.
  # No `accepts` plug on purpose: Apple's CDN and Google's verifier must get JSON
  # for any Accept header, and the controller sets the content type itself.
  pipeline :well_known do
  end

  scope "/", PidroServerWeb do
    pipe_through :well_known

    get "/.well-known/apple-app-site-association",
        WellKnownController,
        :apple_app_site_association

    get "/.well-known/assetlinks.json", WellKnownController, :assetlinks

    # Legacy root path Apple still probes before the well-known one.
    get "/apple-app-site-association", WellKnownController, :apple_app_site_association
  end
end
