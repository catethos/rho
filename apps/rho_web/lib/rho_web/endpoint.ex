defmodule RhoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rho_web

  # `signing_salt` provides domain separation; combined with runtime
  # `secret_key_base`, it protects session cookies via HKDF. The salt is
  # not a secret on its own — rotate `SECRET_KEY_BASE` to invalidate sessions.
  # `secure: true` in prod prevents the cookie from being sent over plain HTTP.
  @session_options [
    store: :cookie,
    key: "_rho_key",
    signing_salt: "kN3pQr7MvXbT2zY8",
    same_site: "Lax",
    secure: Mix.env() == :prod
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: false
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

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

  # Rewrite `conn.remote_ip` from forwarded headers when deployed behind
  # Fly's edge proxy. Only trusted in prod — in dev/test, a request exposed
  # to the internet could otherwise spoof `Fly-Client-IP` and bypass the
  # per-IP rate limiter. Fly injects exactly one value into `Fly-Client-IP`
  # (the true client), so no forwarded-chain parsing is needed.
  if Mix.env() == :prod do
    plug(RemoteIp, headers: ~w[fly-client-ip])
  end

  plug(Plug.Session, @session_options)
  plug(RhoWeb.Router)
end
