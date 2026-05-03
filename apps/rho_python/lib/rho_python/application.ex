defmodule RhoPython.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [RhoPython.Server]
    Supervisor.start_link(children, strategy: :one_for_one, name: RhoPython.Supervisor)
  end
end
