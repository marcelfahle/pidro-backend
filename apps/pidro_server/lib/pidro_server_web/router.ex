defmodule PidroServerWeb.Router do
  use PidroServerWeb, :router
  import Plug.BasicAuth

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
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug PidroServerWeb.Plugs.Authenticate
  end

  pipeline :admin do
    plug :browser
    plug :admin_basic_auth
  end

  scope "/", PidroServerWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Admin panel routes (protected with basic auth)
  scope "/admin", PidroServerWeb do
    pipe_through :admin

    live "/lobby", LobbyLive
    live "/games/:code", GameMonitorLive
    live "/stats", StatsLive
  end

  # API v1 routes
  scope "/api/v1", PidroServerWeb.Api do
    pipe_through :api

    # Auth routes without authentication
    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login

    # Room routes without authentication
    get "/rooms", RoomController, :index
    get "/rooms/:code", RoomController, :show
    get "/rooms/:code/state", RoomController, :state
  end

  # API v1 authenticated routes
  scope "/api/v1", PidroServerWeb.Api do
    pipe_through :api_authenticated

    get "/auth/me", AuthController, :me

    # Room routes with authentication
    post "/rooms", RoomController, :create
    post "/rooms/:code/join", RoomController, :join
    delete "/rooms/:code/leave", RoomController, :leave
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
  end

  # Private functions

  defp admin_basic_auth(conn, _opts) do
    username = Application.get_env(:pidro_server, :admin_username, "admin")
    password = Application.get_env(:pidro_server, :admin_password, "secret")

    basic_auth(conn, username: username, password: password)
  end
end
