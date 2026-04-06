import Config

config :rho_frameworks, RhoFrameworks.Repo,
  database: Path.expand("../apps/rho_frameworks/priv/rho_dev.db", __DIR__),
  pool_size: 5
