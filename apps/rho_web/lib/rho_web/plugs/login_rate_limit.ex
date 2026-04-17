defmodule RhoWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Throttles POST `/users/log_in` to slow down credential stuffing and
  password-spraying attacks.

  Two independent buckets are checked:

    * **Per-email** — 5 attempts per 5 minutes. Protects a single account
      from being brute-forced, even if the attacker rotates IPs.
    * **Per-IP** — 20 attempts per 5 minutes. Protects against a single
      host sweeping many emails.

  Either bucket denying the request blocks it. The response is an HTTP 429
  with a `retry-after` header and a flash for the login form.

  > ### Behind a proxy
  >
  > `conn.remote_ip` is the TCP peer. If this app is deployed behind
  > a trusted proxy (nginx, Fly.io edge, Cloudflare), add `RemoteIp`
  > to the endpoint before this plug so the real client IP is used.
  """

  import Plug.Conn
  import Phoenix.Controller
  use Phoenix.VerifiedRoutes, endpoint: RhoWeb.Endpoint, router: RhoWeb.Router

  alias RhoWeb.RateLimiter

  @window_ms :timer.minutes(5)
  @max_per_email 5
  @max_per_ip 20

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = ip_string(conn)
    email = conn.params |> get_in(["user", "email"]) |> normalize_email()

    with {:allow, _} <- RateLimiter.hit("login:ip:" <> ip, @window_ms, @max_per_ip),
         {:allow, _} <- RateLimiter.hit("login:email:" <> email, @window_ms, @max_per_email) do
      conn
    else
      {:deny, retry_after_ms} -> deny(conn, retry_after_ms)
    end
  end

  defp deny(conn, retry_after_ms) do
    seconds = div(retry_after_ms, 1000) + 1

    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_flash(:error, "Too many login attempts. Please try again in #{seconds} seconds.")
    |> put_status(429)
    |> redirect(to: ~p"/users/log_in")
    |> halt()
  end

  defp ip_string(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Cap length defensively — user-supplied string goes into an ETS key, so an
  # attacker posting megabyte-long "emails" could bloat the rate-limiter table.
  # The User schema enforces max: 160 on real registrations anyway.
  defp normalize_email(email) when is_binary(email) do
    email |> String.slice(0, 160) |> String.trim() |> String.downcase()
  end

  defp normalize_email(_), do: ""
end
