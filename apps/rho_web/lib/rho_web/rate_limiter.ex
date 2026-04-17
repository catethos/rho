defmodule RhoWeb.RateLimiter do
  @moduledoc """
  ETS-backed rate limiter for auth and other abuse-prone endpoints.

  Per-node. If the app is ever horizontally scaled, swap the backend for
  `Hammer.Redis` without touching call sites — the API is the same.

  ## Usage

      case RhoWeb.RateLimiter.hit("login:ip:" <> ip, _window_ms = 60_000, _max = 5) do
        {:allow, _count} -> :ok
        {:deny, retry_after_ms} -> {:error, retry_after_ms}
      end
  """

  use Hammer, backend: :ets
end
