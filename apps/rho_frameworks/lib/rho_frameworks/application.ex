defmodule RhoFrameworks.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RhoFrameworks.Repo
    ]

    opts = [strategy: :one_for_one, name: RhoFrameworks.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register identity plugin after Repo is up
    Rho.PluginRegistry.register(RhoFrameworks.IdentityPlugin)

    result
  end
end
