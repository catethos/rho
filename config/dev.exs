import Config

# Database URL is configured in config/runtime.exs (sourced via dotenvy from .env).

# Enable code reloading on file changes
config :rho_web, RhoWeb.Endpoint,
  code_reloader: true,
  live_reload: [
    patterns: [
      ~r"apps/rho_web/lib/rho_web/.*(ex|heex)$",
      ~r"apps/rho/lib/.*(ex)$",
      ~r"apps/rho_stdlib/lib/.*(ex)$",
      ~r"apps/rho_frameworks/lib/.*(ex)$"
    ]
  ]

config :phoenix, :plug_init_mode, :runtime
