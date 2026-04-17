import Config

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

  # ─── Database (SQLite on a Fly volume) ─────────────────────────────────
  # SQLite is a single file. Fly VMs have ephemeral root filesystems, so
  # the DB **must** live on a mounted volume or every deploy wipes users,
  # orgs, libraries, and tokens. Default path matches the fly.toml mount.
  database_path = System.get_env("DATABASE_PATH") || "/data/rho.db"

  config :rho_frameworks, RhoFrameworks.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),

    # WAL journal: readers don't block the writer, the writer doesn't block
    # readers. The default `:delete` mode serializes every reader behind the
    # writer — under any real concurrency you get `SQLITE_BUSY` errors.
    journal_mode: :wal,

    # Safe to relax to `:normal` once WAL is on — fsyncs once per checkpoint
    # instead of on every commit, at no durability cost vs. power-loss.
    synchronous: :normal,

    # If a write lock is held, wait up to 5s before returning SQLITE_BUSY.
    # Web requests are already bounded by plug timeouts; 5s lets short
    # transactions queue gracefully instead of failing under bursts.
    busy_timeout: 5_000,

    # Temp tables / indexes live in RAM, not on the volume. Avoids touching
    # /data for scratch work that doesn't need to survive restarts.
    temp_store: :memory,

    # 64 MiB page cache. Negative = KB. Default is 2 MiB, way too small for
    # a DB that might hit tens of MB of hot pages across lenses/skills/roles.
    cache_size: -64_000

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
    check_origin: ["https://" <> host],

    # `force_ssl` plugs Plug.SSL: 301-redirects plain HTTP → HTTPS and
    # sends a `Strict-Transport-Security` header (HSTS) so the browser
    # refuses to talk over HTTP afterwards. `rewrite_on` tells Plug.SSL to
    # trust Fly's `X-Forwarded-*` headers for determining the original
    # scheme — without this the app sees plain HTTP internally and
    # redirects into a loop.
    force_ssl: [
      rewrite_on: [:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port],
      hsts: true
    ]
end
