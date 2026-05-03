import Config

# Compile-time prod settings. All runtime values (DATABASE_URL,
# SECRET_KEY_BASE, PHX_HOST, ...) live in config/runtime.exs.
#
# `force_ssl` MUST be set here, not in runtime.exs — Phoenix freezes a
# handful of endpoint keys at compile time and aborts boot if runtime
# values don't match (`validate_compile_env`).

config :rho_web, RhoWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port],
    hsts: true
  ]

config :phoenix, :plug_init_mode, :runtime

config :logger, level: :info
