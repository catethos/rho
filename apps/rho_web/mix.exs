defmodule RhoWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho_web,
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
      mod: {RhoWeb.Application, []}
    ]
  end

  defp deps do
    [
      {:rho, in_umbrella: true},
      {:rho_stdlib, in_umbrella: true},
      {:rho_cli, in_umbrella: true},
      {:rho_frameworks, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:bcrypt_elixir, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:mimic, "~> 1.10", only: :test}
    ]
  end
end
