import Config

# Finch connection pool sized for subagent fan-out.
# Each concurrent LLM stream occupies one HTTP/1 connection (size: 1 per pool),
# so `count` is the effective concurrency ceiling. Primary agent + per-category
# LiteWorkers spawned by tools like `save_and_generate` all stream in parallel;
# count must exceed max expected fan-out or checkouts queue and time out
# (see Rho.TurnStrategy.Shared.retryable?/1 for the pool-exhaustion retry path).
config :req_llm,
  custom_providers: [ReqLLM.Providers.FireworksAI],
  # Increase receive timeout to handle slow LLM providers (e.g., OpenRouter + MiniMax)
  # that may pause >30s between text generation and tool call generation.
  stream_receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [
        protocols: [:http1],
        size: 1,
        count: 256,
        conn_max_idle_time: 120_000,
        start_pool_metrics?: true
      ]
    }
  ]

config :phoenix, :json_library, Jason

# Core rho app config
config :rho,
  tape_module: Rho.Tape.Projection.JSONL

# Phoenix endpoint configuration
config :rho_web, RhoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  url: [host: "localhost"],
  check_origin: false,
  server: true,
  secret_key_base: "rho_dev_secret_key_base_at_least_64_bytes_long_for_cookie_signing_purposes!!",
  render_errors: [formats: [html: RhoWeb.ErrorHTML], layout: false],
  pubsub_server: Rho.PubSub,
  live_view: [signing_salt: "Rv8nBqK2dYhF6mP3"]

# Ecto / SQLite
config :rho_frameworks, ecto_repos: [RhoFrameworks.Repo]

config :rho_frameworks, RhoFrameworks.Repo,
  database: Path.expand("../apps/rho_frameworks/priv/rho.db", __DIR__),
  pool_size: 5

import_config "#{config_env()}.exs"
