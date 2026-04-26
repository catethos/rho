defmodule Rho.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho,
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
      mod: {Rho.Application, []}
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:dotenvy, "~> 1.1"},
      {:rho_baml, in_umbrella: true},
      {:mimic, "~> 1.10", only: :test},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
