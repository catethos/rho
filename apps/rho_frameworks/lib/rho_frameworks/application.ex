defmodule RhoFrameworks.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RhoFrameworks.Repo,
      RhoFrameworks.Accounts.TokenSweeper,
      RhoFrameworks.Roles.EmbeddingCache
    ]

    opts = [strategy: :one_for_one, name: RhoFrameworks.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
