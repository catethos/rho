defmodule Rho.Stdlib.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Rho.PythonRegistry},
      {DynamicSupervisor, name: Rho.Stdlib.Tools.Python.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Rho.Stdlib.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
