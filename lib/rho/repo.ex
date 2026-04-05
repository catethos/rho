defmodule Rho.Repo do
  use Ecto.Repo,
    otp_app: :rho,
    adapter: Ecto.Adapters.SQLite3
end
