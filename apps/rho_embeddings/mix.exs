defmodule RhoEmbeddings.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho_embeddings,
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
      mod: {RhoEmbeddings.Application, []}
    ]
  end

  defp deps do
    [
      {:rho_python, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
