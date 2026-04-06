import Config

config :rho_frameworks, RhoFrameworks.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1
