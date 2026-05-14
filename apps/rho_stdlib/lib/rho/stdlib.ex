defmodule Rho.Stdlib do
  @moduledoc """
  Standard library of tools and plugins for Rho.

  Provides built-in tools (bash, filesystem, web, python, sandbox)
  and plugins (multi-agent, step budget, skills, etc.).
  """

  @plugin_modules %{
    bash: Rho.Stdlib.Tools.Bash,
    fs_read: Rho.Stdlib.Tools.FsRead,
    fs_write: Rho.Stdlib.Tools.FsWrite,
    fs_edit: Rho.Stdlib.Tools.FsEdit,
    web_fetch: Rho.Stdlib.Tools.WebFetch,
    web_search: Rho.Stdlib.Tools.WebSearch,
    python: Rho.Stdlib.Tools.Python,
    skills: Rho.Stdlib.Skill.Plugin,
    multi_agent: Rho.Stdlib.Plugins.MultiAgent,
    sandbox: Rho.Stdlib.Tools.Sandbox,
    step_budget: Rho.Stdlib.Plugins.StepBudget,
    live_render: Rho.Stdlib.Plugins.LiveRender,
    py_agent: Rho.Stdlib.Plugins.PyAgent,
    data_table: Rho.Stdlib.Plugins.DataTable,
    doc_ingest: Rho.Stdlib.Plugins.DocIngest,
    tape: Rho.Stdlib.Plugins.Tape,
    journal: Rho.Stdlib.Plugins.Tape,
    uploads: Rho.Stdlib.Plugins.Uploads,
    debug_tape: Rho.Stdlib.Plugins.DebugTape,
    control: Rho.Stdlib.Plugins.Control
  }

  @doc "Returns the map of plugin shorthand atoms to their modules."
  def plugin_modules, do: @plugin_modules

  @reverse_plugin_modules Map.new(@plugin_modules, fn {k, v} -> {v, k} end)

  @doc """
  Resolves a plugin entry to `{module, opts}`.

  Accepts:
  - An atom shorthand: `:bash` -> `{Rho.Stdlib.Tools.Bash, []}`
  - A tuple with options: `{:python, max_iterations: 20}` -> `{Rho.Stdlib.Tools.Python, [max_iterations: 20]}`
  - A raw module: `MyProject.ReviewPolicy` -> `{MyProject.ReviewPolicy, []}`
  """
  def resolve_plugin(entry) when is_atom(entry) do
    case Map.fetch(@plugin_modules, entry) do
      {:ok, mod} -> {mod, []}
      :error -> {entry, []}
    end
  end

  def resolve_plugin({name, opts}) when is_atom(name) and is_list(opts) do
    case Map.fetch(@plugin_modules, name) do
      {:ok, mod} -> {mod, opts}
      :error -> {name, opts}
    end
  end

  @doc "Derives capability atoms from a list of plugin config entries."
  def capabilities_from_plugins(plugins) do
    Enum.map(plugins, fn entry ->
      {mod, _opts} = resolve_plugin(entry)
      Map.get(@reverse_plugin_modules, mod, mod)
    end)
  end
end
