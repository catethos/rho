import Config

# Increase Finch connection pool for subagent concurrency.
# ReqLLM default is size: 1, count: 8 — bump count to handle parallel LLM streams.
config :req_llm,
  # Increase receive timeout to handle slow LLM providers (e.g., OpenRouter + MiniMax)
  # that may pause >30s between text generation and tool call generation.
  stream_receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [protocols: [:http1], size: 1, count: 25, conn_max_idle_time: 30_000]
    }
  ]

# Phoenix endpoint configuration
config :rho, RhoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  url: [host: "localhost"],
  check_origin: ["//localhost"],
  server: true,
  secret_key_base: "rho_dev_secret_key_base_at_least_64_bytes_long_for_cookie_signing_purposes!!",
  render_errors: [formats: [html: RhoWeb.ErrorHTML], layout: false],
  pubsub_server: Rho.PubSub,
  live_view: [signing_salt: "rho_lv_salt"]

config :phoenix, :json_library, Jason

config :rho, Rho.SkillStore.Repo,
  database: Path.expand("priv/skill_store.db"),
  pool_size: 5

config :rho, ecto_repos: [Rho.SkillStore.Repo]
