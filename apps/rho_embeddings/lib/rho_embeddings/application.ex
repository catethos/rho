defmodule RhoEmbeddings.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [RhoEmbeddings.Server]
    Supervisor.start_link(children, strategy: :one_for_one, name: RhoEmbeddings.Supervisor)
  end
end
