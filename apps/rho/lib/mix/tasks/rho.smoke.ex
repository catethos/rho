defmodule Mix.Tasks.Rho.Smoke do
  @moduledoc """
  Quick smoke test — verifies the core agent path works. ~5 seconds.

  Runs integration tests tagged `:smoke` from the rho app.

      mix rho.smoke
  """

  use Mix.Task

  @shortdoc "Run quick smoke tests (~5s)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("test", [
      "apps/rho/test/integration/",
      "--include",
      "smoke",
      "--exclude",
      "integration"
    ])
  end
end
