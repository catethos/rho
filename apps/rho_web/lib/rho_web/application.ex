defmodule RhoWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Rho.PubSub},
      RhoWeb.FinchTelemetry,
      RhoWeb.Observatory,
      RhoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RhoWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
