defmodule RhoWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RhoWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(RhoWeb.Plugs.APIAuth)
  end

  scope "/api", RhoWeb do
    pipe_through(:api)

    forward("/", ObservatoryAPI)
  end

  scope "/", RhoWeb do
    pipe_through(:browser)

    live("/spreadsheet/:session_id", SpreadsheetLive, :show)
    live("/spreadsheet", SpreadsheetLive, :new)
    live("/observatory/:session_id", ObservatoryLive, :show)
    live("/observatory", ObservatoryLive, :new)
    live("/session/:session_id", SessionLive, :show)
    live("/", SessionLive, :new)
  end
end
