import Config

config :rho_web, RhoWeb.Endpoint, server: false

# Database URL is configured in config/runtime.exs (sourced via dotenvy from .env).
# `ownership_timeout: :infinity` keeps the shared sandbox owner alive for the
# full suite (defaults to 120s, which Neon round-trips blow past).
config :rho_frameworks, RhoFrameworks.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  ownership_timeout: :infinity

# Skip the real fastembed model load in CI / test runs.
config :rho_embeddings,
  backend: RhoEmbeddings.Backend.Fake
