import Config

# Source .env so dev/test pick up NEON_URL without manual export. In prod
# the orchestrator sets env vars directly; .env may not exist there.
#
# Test env additionally sources `.env.test` (after `.env`, so its keys win).
# That's where `DATABASE_URL` is overridden to point at a local Postgres —
# Neon's per-query RTT is ~30–50ms, which makes the suite painfully slow.
#
# Paths are resolved against this file's location (umbrella root) so they
# work whether mix is run from the umbrella root or a subapp dir.
if config_env() in [:dev, :test] do
  umbrella_root = Path.expand("..", __DIR__)

  candidates =
    cond do
      explicit = System.get_env("DOTENV_FILE") -> [explicit]
      config_env() == :test -> [".env", ".env.test"]
      true -> [".env"]
    end

  # Dotenvy's default side-effect writes to a process dictionary, but the
  # rest of this file reads via `System.get_env/1`. Push file values into
  # System env, but only when not already set there — shell exports keep
  # precedence over `.env` files.
  put_into_system = fn vars ->
    Enum.each(vars, fn {k, v} ->
      if System.get_env(k) == nil, do: System.put_env(k, v)
    end)
  end

  case candidates
       |> Enum.map(&Path.join(umbrella_root, &1))
       |> Enum.filter(&File.exists?/1) do
    [] -> :ok
    files -> Dotenvy.source!(files, side_effect: put_into_system)
  end
end

# ─── Database (Postgres + pgvector, Neon-hosted) ─────────────────────────
# `prepare: :unnamed` is required when using Neon's pooled (PgBouncer
# transaction-pooling) endpoint — named prepared statements get dropped
# between transactions. Harmless on direct/session-pooled endpoints, so
# it's safe as a default.
db_url =
  System.get_env("DATABASE_URL") ||
    System.get_env("NEON_URL") ||
    if config_env() == :prod do
      raise """
      environment variable DATABASE_URL (or NEON_URL) is missing.
      Set it to a Neon Postgres connection string.
      """
    else
      nil
    end

if db_url do
  ssl_opts =
    if System.get_env("DB_SSL", "true") == "true" do
      [verify: :verify_none]
    else
      false
    end

  config :rho_frameworks, RhoFrameworks.Repo,
    url: db_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    prepare: :unnamed,
    parameters: [application_name: "rho_frameworks"],
    ssl: ssl_opts
end

# ─── Embeddings ──────────────────────────────────────────────────────────
# `RHO_EMBEDDINGS_ENABLED=false` skips the model load; embed_many/1 calls
# return `{:error, :disabled}`. Useful in CI, lightweight deploys, or
# hosts that don't ship the fastembed wheels.
config :rho_embeddings,
  enabled: System.get_env("RHO_EMBEDDINGS_ENABLED", "true") in ["true", "1"],
  model:
    System.get_env(
      "RHO_EMBEDDINGS_MODEL",
      "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    )

if config_env() == :prod do
  # ─── Secrets ───────────────────────────────────────────────────────────
  # SECRET_KEY_BASE is the master key for every symmetric crypto operation
  # Phoenix performs: session cookie signing, LiveView payload signing,
  # `Phoenix.Token` signing/encryption, CSRF tokens. If leaked, an attacker
  # can forge sessions for any user. Generate per-deploy with
  # `mix phx.gen.secret` and set as a Fly secret.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # ─── Endpoint (URL, HTTPS enforcement, origin checks) ──────────────────
  # PHX_HOST is used by verified routes and URL helpers; without it every
  # generated absolute URL points at "localhost".
  host =
    System.get_env("PHX_HOST") ||
      raise "environment variable PHX_HOST is missing (e.g. rho.fly.dev)"

  port = String.to_integer(System.get_env("PORT") || "8080")

  config :rho_web, RhoWeb.Endpoint,
    # `url:` affects generated links. Scheme is https because the request
    # reaches users via Fly's TLS edge; the app itself speaks plain HTTP
    # internally on `http:`.
    url: [host: host, port: 443, scheme: "https"],

    # Fly's internal network is IPv6-only on the proxy→app hop. Binding to
    # `::` covers both families; the fly.toml `internal_port` must match.
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true,

    # `check_origin` guards LiveView websocket CSRF — the WS handshake is
    # rejected if `Origin` doesn't match. Without this, a phishing site
    # could open a LiveView against your app using a victim's cookie.
    check_origin: ["https://" <> host]

  # `force_ssl` is set at compile time in config/prod.exs because Phoenix
  # validates that key against compile-time state and aborts boot otherwise.
end
