defmodule Rho.Config do
  @moduledoc """
  Core configuration accessors for the Rho runtime.

  Functions in this module discover CLI modules at runtime via
  `Code.ensure_loaded?/1` — no application env callbacks needed.
  The full config file loader (.rho.exs) lives in `Rho.CLI.Config`.
  """

  # These modules live in sibling umbrella apps and are discovered
  # at runtime via Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, [Rho.CLI.Config, Rho.CLI.CommandParser, Rho.Stdlib]}

  @doc """
  Returns the configured tape-context projection module.

  Defaults to `Rho.Tape.Context.Tape`.
  """
  def tape_module do
    mod = Application.get_env(:rho, :tape_module, Rho.Tape.Context.Tape)
    Code.ensure_loaded!(mod)
    mod
  end

  @doc """
  Returns the agent config for the given agent name.

  Discovers `Rho.CLI.Config` at runtime. Falls back to a minimal
  default config when the CLI app is not loaded.
  """
  def agent_config(name \\ :default) do
    if cli_config_available?() do
      Rho.CLI.Config.agent(name)
    else
      default_agent_config()
    end
  end

  @doc """
  Returns whether sandbox mode is enabled.
  """
  def sandbox_enabled? do
    if cli_config_available?() do
      Rho.CLI.Config.sandbox_enabled?()
    else
      false
    end
  end

  @doc """
  Parses a direct command string into `{tool_name, args}`.
  """
  def parse_command(command) do
    if Code.ensure_loaded?(Rho.CLI.CommandParser) and
         function_exported?(Rho.CLI.CommandParser, :parse, 1) do
      Rho.CLI.CommandParser.parse(command)
    else
      {"unknown", %{"error" => "no command parser configured"}}
    end
  end

  @doc """
  Derives capabilities from a list of plugin entries.
  """
  def capabilities_from_plugins(plugins) do
    if Code.ensure_loaded?(Rho.Stdlib) and
         function_exported?(Rho.Stdlib, :capabilities_from_plugins, 1) do
      Rho.Stdlib.capabilities_from_plugins(plugins)
    else
      []
    end
  end

  @doc """
  Returns the list of configured agent names.
  """
  def agent_names do
    if cli_config_available?() do
      Rho.CLI.Config.agent_names()
    else
      [:default]
    end
  end

  defp cli_config_available? do
    Code.ensure_loaded?(Rho.CLI.Config) and
      function_exported?(Rho.CLI.Config, :agent, 1)
  end

  defp default_agent_config do
    %{
      model: "openrouter:anthropic/claude-sonnet",
      system_prompt: "You are a helpful assistant.",
      plugins: [],
      max_steps: 50,
      max_tokens: 4096,
      provider: nil,
      turn_strategy: Rho.TurnStrategy.Direct,
      turn_strategy_opts: [],
      description: nil,
      skills: [],
      prompt_format: :markdown,
      avatar: nil
    }
  end
end
