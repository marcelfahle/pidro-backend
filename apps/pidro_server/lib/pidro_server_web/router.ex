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

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PidroServerWeb.ApiSpec
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug PidroServerWeb.Plugs.Authenticate
  end

  scope "/", PidroServerWeb do
    pipe_through :browser

    get "/", PageController, :home
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

    # Auth routes without authentication
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login

    # Room routes without authentication
    get "/rooms", RoomController, :index
    get "/rooms/:code", RoomController, :show
  end

  # API v1 authenticated routes
  scope "/api/v1", PidroServerWeb.API do
    pipe_through :api_authenticated

    get "/auth/me", AuthController, :me

    # Game state route (authenticated to prevent hand exposure)
    get "/rooms/:code/state", RoomController, :state

    # User routes with authentication
    get "/users/me/stats", UserController, :stats

    # Lobby route with authentication (needs user_id for rejoinable rooms)
    get "/lobby", RoomController, :lobby

    # Room routes with authentication
    post "/rooms", RoomController, :create
    post "/rooms/:code/join", RoomController, :join
    delete "/rooms/:code/leave", RoomController, :leave
    post "/rooms/:code/open-seat", RoomController, :open_seat
    post "/rooms/:code/close-seat", RoomController, :close_seat

    # Spectator routes with authentication
    post "/rooms/:code/watch", RoomController, :watch
    delete "/rooms/:code/unwatch", RoomController, :unwatch
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pidro_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PidroServerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/dev", PidroServerWeb.Dev do
      pipe_through :browser

      live_session :dev, root_layout: {PidroServerWeb.Layouts, :dev_root} do
        live "/games", GameListLive
        live "/games/:code", GameDetailLive
        live "/analytics", AnalyticsLive
      end
    end
  end
end
