defmodule RhoFrameworks.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho_frameworks,
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
      mod: {RhoFrameworks.Application, []}
    ]
  end

  defp deps do
    [
      {:rho, in_umbrella: true},
      {:rho_stdlib, in_umbrella: true},
      {:rho_baml, in_umbrella: true},
      {:rho_embeddings, in_umbrella: true},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:pgvector, "~> 0.3.1"},
      {:phoenix_ecto, "~> 4.6"},
      {:bcrypt_elixir, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"},
      {:mimic, "~> 1.10", only: :test}
    ]
  end
end
