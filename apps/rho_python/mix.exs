defmodule RhoPython.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho_python,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RhoPython.Application, []}
    ]
  end

  defp deps do
    [
      {:pythonx, "~> 0.4"},
      {:erlang_python, "~> 2.3"}
    ]
  end
end
