defmodule RhoFrameworks.Release do
  @moduledoc """
  Release tasks invoked from the deployed Erlang release (no Mix available).

  Call from the host:
      /app/bin/rho_web eval 'RhoFrameworks.Release.migrate()'
  """

  @app :rho_frameworks

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
