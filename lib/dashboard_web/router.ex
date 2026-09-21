defmodule DashboardWeb.Router do
  use DashboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DashboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # JSON endpoints called from the page itself: they carry the session so the
  # CSRF token the page holds is checked.
  pipeline :page_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/", DashboardWeb do
    pipe_through :browser

    get "/", DashboardController, :index
  end

  scope "/", DashboardWeb do
    pipe_through :page_api

    post "/refresh", DashboardController, :refresh
  end

  scope "/", DashboardWeb do
    pipe_through :api

    get "/api/status", DashboardController, :status
    get "/data.json", DashboardController, :data
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:dashboard, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DashboardWeb.Telemetry
    end
  end
end
