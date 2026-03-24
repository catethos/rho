defmodule RhoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RhoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", RhoWeb do
    pipe_through :browser

    live "/observatory/:session_id", ObservatoryLive, :show
    live "/observatory", ObservatoryLive, :new
    live "/session/:session_id", SessionLive, :show
    live "/", SessionLive, :new
  end
end
