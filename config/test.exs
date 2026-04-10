import Config

config :rho_web, RhoWeb.Endpoint, server: false

config :rho_frameworks, RhoFrameworks.Repo,
  database: Path.expand("../apps/rho_frameworks/priv/rho_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5
