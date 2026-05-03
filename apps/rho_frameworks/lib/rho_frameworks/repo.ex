defmodule RhoFrameworks.Repo do
  use Ecto.Repo,
    otp_app: :rho_frameworks,
    adapter: Ecto.Adapters.Postgres
end
