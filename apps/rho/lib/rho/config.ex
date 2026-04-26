defmodule Rho.Config do
  @moduledoc """
  Core configuration accessors for the Rho runtime.

  The `.rho.exs` loader lives in `Rho.AgentConfig`. The remaining
  shims here discover `Rho.CLI.CommandParser` (about to be deleted)
  and `Rho.Stdlib` (sibling umbrella app) at runtime.
  """

  # These modules live in sibling umbrella apps and are discovered
  # at runtime via Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, [Rho.CLI.CommandParser, Rho.Stdlib]}

  @doc """
  Returns the configured tape projection module.

  Defaults to `Rho.Tape.Projection.JSONL`.
  """
  def tape_module do
    mod = Application.get_env(:rho, :tape_module, Rho.Tape.Projection.JSONL)
    Code.ensure_loaded!(mod)
    mod
  end

  @doc """
  Returns the agent config for the given agent name.
  """
  defdelegate agent_config(name \\ :default), to: Rho.AgentConfig, as: :agent

  @doc """
  Returns whether sandbox mode is enabled.
  """
  defdelegate sandbox_enabled?, to: Rho.AgentConfig

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
  defdelegate agent_names, to: Rho.AgentConfig
end
