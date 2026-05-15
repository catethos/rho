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
        "rho.arch": :test,
        "rho.quality": :test,
        "rho.slop": :test,
        "rho.slop.strict": :test,
        "rho.smoke": :test,
        "rho.verify": :test
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "rho.quality": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "rho.credence",
        "rho.arch"
      ],
      "rho.slop": ["credo --strict --checks ExSlop --mute-exit-status"],
      "rho.slop.strict": ["credo --strict --checks ExSlop"],
      test: ["test"]
    ]
  end
end
