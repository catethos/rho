defmodule RhoStdlib.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho_stdlib,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Rho.Stdlib.Application, []}
    ]
  end

  defp deps do
    [
      {:rho, in_umbrella: true},
      {:rho_python, in_umbrella: true},
      {:floki, "~> 0.37"},
      {:erlang_python, "~> 2.3"},
      {:xlsxir, "~> 1.6"},
      {:live_render, "~> 0.5"},
      {:nimble_csv, "~> 1.2"},
      {:yaml_elixir, "~> 2.11"},
      {:mimic, "~> 1.10", only: :test}
    ]
  end
end
