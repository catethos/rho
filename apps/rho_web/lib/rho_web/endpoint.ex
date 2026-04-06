defmodule RhoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rho

  @session_options [
    store: :cookie,
    key: "_rho_key",
    signing_salt: "rho_sign",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # Serve Phoenix client JS from the dep packages
  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/",
    from: {:rho, "priv/static"},
    gzip: false,
    only: ~w(assets css js favicon.ico robots.txt)
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Session, @session_options)
  plug(RhoWeb.Router)
end
