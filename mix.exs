defmodule Rho.MixProject do
  use Mix.Project

  def project do
    [
      app: :rho,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Rho.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.6"},
      {:jido_signal, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 1.1"},
      {:yaml_elixir, "~> 2.11"},
      {:mimic, "~> 1.10", only: :test},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:floki, "~> 0.37"},
      {:pythonx, "~> 0.4"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.2"},
      {:live_render, "~> 0.5"},
      {:nimble_options, "~> 1.0"}
    ]
  end
end
