defmodule Rho.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.2.0",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases(),
      cli: cli(),
      releases: releases()
    ]
  end

  defp releases do
    [
      rho_web: [
        include_executables_for: [:unix],
        applications: [
          rho: :permanent,
          rho_stdlib: :permanent,
          rho_baml: :permanent,
          rho_python: :permanent,
          rho_embeddings: :permanent,
          rho_frameworks: :permanent,
          rho_web: :permanent
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "rho.credence": :test,
        "rho.smoke": :test,
        "rho.verify": :test
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["test"]
    ]
  end
end
