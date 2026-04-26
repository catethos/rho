defmodule Mix.Tasks.Rho.Verify do
  @moduledoc """
  Full integration test suite — verifies session lifecycle, multi-turn,
  tools, RunSpec config, and event emission. ~15 seconds.

  Runs all integration tests from the rho app.

      mix rho.verify
  """

  use Mix.Task

  @shortdoc "Run full integration tests (~15s)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("test", ["apps/rho/test/integration/"])
  end
end
