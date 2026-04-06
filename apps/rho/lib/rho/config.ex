defmodule Rho.Config do
  @moduledoc """
  Core configuration accessors for the Rho runtime.

  This module provides only the runtime-relevant config queries.
  The full config file loader (.rho.exs) lives in `Rho.CLI.Config`.
  """

  @doc """
  Returns the configured tape-context projection module.

  Defaults to `Rho.Tape.Context.Tape`. Accepts both `:tape_module`
  (canonical) and `:tape_module` (legacy alias).
  """
  def tape_module do
    mod =
      Application.get_env(:rho, :tape_module) ||
        Application.get_env(:rho, :tape_module, Rho.Tape.Context.Tape)

    Code.ensure_loaded!(mod)
    mod
  end

  @doc "Legacy alias for `tape_module/0`."
  def memory_module, do: tape_module()

  @doc """
  Returns the agent config for the given agent name.

  Delegates to the `:agent_config_loader` callback set via
  `Application.put_env(:rho, :agent_config_loader, {Mod, :fun})`.
  Falls back to a minimal default config when no loader is configured.
  """
  def agent_config(name \\ :default) do
    case Application.get_env(:rho, :agent_config_loader) do
      {mod, fun} -> apply(mod, fun, [name])
      nil -> default_agent_config()
    end
  end

  @doc """
  Returns whether sandbox mode is enabled.

  Delegates to `:sandbox_enabled_fn` or returns false.
  """
  def sandbox_enabled? do
    case Application.get_env(:rho, :sandbox_enabled_fn) do
      {mod, fun} -> apply(mod, fun, [])
      nil -> false
    end
  end

  @doc """
  Parses a direct command string into `{tool_name, args}`.

  Delegates to `:command_parser_fn` or returns an error.
  """
  def parse_command(command) do
    case Application.get_env(:rho, :command_parser_fn) do
      {mod, fun} -> apply(mod, fun, [command])
      nil -> {"unknown", %{"error" => "no command parser configured"}}
    end
  end

  @doc """
  Derives capabilities from a list of plugin entries.

  Delegates to `:capabilities_fn` or returns [].
  """
  def capabilities_from_plugins(plugins) do
    case Application.get_env(:rho, :capabilities_fn) do
      {mod, fun} -> apply(mod, fun, [plugins])
      nil -> []
    end
  end

  @doc """
  Returns the list of configured agent names.

  Delegates to `:agent_names_fn` or returns `[:default]`.
  """
  def agent_names do
    case Application.get_env(:rho, :agent_names_fn) do
      {mod, fun} -> apply(mod, fun, [])
      nil -> [:default]
    end
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
