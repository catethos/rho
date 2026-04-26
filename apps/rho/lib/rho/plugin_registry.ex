defmodule Rho.PluginRegistry do
  @moduledoc """
  Plugin registration and capability collection.

  The GenServer manages plugin registration (write serialization).
  Collection reads from ETS in the caller's process — no bottleneck.

  Transformer stage dispatch has moved to `Rho.TransformerRegistry`.
  `apply_stage/3` is kept as a delegate for backward compatibility.

  ## Scoping

  Plugins can be registered with a scope:

    * `:global` (default) — active for all agents
    * `{:agent, name}` — active only when `context[:agent_name]` matches `name`
  """
  use GenServer
  require Logger

  alias Rho.PluginInstance

  @table :rho_plugin_instances

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :protected, read_concurrency: true])
    {:ok, %{next_priority: 0}}
  end

  # --- Registration ---

  @doc """
  Register a plugin module with optional configuration.

  Later registrations have higher priority.

  ## Options

    * `:scope` — `:global` (default) or `{:agent, agent_name}`
    * `:opts` — keyword list passed to plugin callbacks as `plugin_opts`
  """
  def register(plugin_module, opts \\ []) do
    GenServer.call(__MODULE__, {:register, plugin_module, opts})
  end

  @doc "Clears all registered plugins. Useful for testing."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def handle_call({:register, plugin_module, opts}, _from, %{next_priority: p} = state) do
    Code.ensure_loaded!(plugin_module)
    scope = Keyword.get(opts, :scope, :global)
    plugin_opts = Keyword.get(opts, :opts, [])

    instance = %PluginInstance{
      module: plugin_module,
      opts: plugin_opts,
      scope: scope,
      priority: p
    }

    :ets.insert(@table, {p, instance})
    {:reply, :ok, %{state | next_priority: p + 1}}
  end

  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{next_priority: 0}}
  end

  # --- Query ---

  @doc "Return ordered list of PluginInstance structs matching context (highest priority first)."
  def active_plugins(context) do
    agent_name = Map.get(context, :agent_name)

    all_entries()
    |> Enum.filter(fn %PluginInstance{scope: scope} ->
      case scope do
        :global -> true
        {:agent, name} -> agent_name == name
      end
    end)
  end

  # --- Affordance collection ---

  @doc "Collect tools from all active plugins."
  def collect_tools(context) do
    active_plugins(context)
    |> Enum.flat_map(fn %PluginInstance{module: mod, opts: opts} ->
      safe_call(mod, :tools, [opts, context], [])
    end)
  end

  @doc "Collect prompt sections from all active plugins."
  def collect_prompt_sections(context) do
    active_plugins(context)
    |> Enum.flat_map(fn %PluginInstance{module: mod, opts: opts} ->
      safe_call(mod, :prompt_sections, [opts, context], [])
    end)
  end

  @doc "Collect bindings from all active plugins."
  def collect_bindings(context) do
    active_plugins(context)
    |> Enum.flat_map(fn %PluginInstance{module: mod, opts: opts} ->
      safe_call(mod, :bindings, [opts, context], [])
    end)
  end

  @doc """
  Dispatch an inbound signal to active plugins. Returns the first
  non-`:ignore` result, or `:ignore` if no plugin matches.

  See `Rho.Plugin` for return-shape semantics.
  """
  def dispatch_signal(signal, context) do
    Enum.reduce_while(active_plugins(context), :ignore, fn
      %PluginInstance{module: mod, opts: opts}, _acc ->
        case safe_call(mod, :handle_signal, [signal, opts, context], :ignore) do
          :ignore -> {:cont, :ignore}
          result -> {:halt, result}
        end
    end)
  end

  @doc "Render binding metadata as prompt sections."
  def render_binding_metadata(bindings) do
    Enum.map(bindings, fn b ->
      "Available: `#{b.name}` (#{b.kind}, #{b.size} chars) — #{b.summary}. Access via #{b.access}."
    end)
  end

  @doc """
  Collect all prompt material (sections + bindings) as `[%PromptSection{}]`.

  Raw strings returned by plugins are auto-wrapped. Bindings are converted
  into a single metadata section.
  """
  def collect_prompt_material(context) do
    alias Rho.PromptSection

    plugins = active_plugins(context)

    raw_sections =
      Enum.flat_map(plugins, fn %PluginInstance{module: mod, opts: opts} ->
        safe_call(mod, :prompt_sections, [opts, context], [])
      end)

    raw_bindings =
      Enum.flat_map(plugins, fn %PluginInstance{module: mod, opts: opts} ->
        safe_call(mod, :bindings, [opts, context], [])
      end)

    sections = Enum.map(raw_sections, &normalize_section/1)

    binding_section =
      case PromptSection.from_bindings(raw_bindings) do
        nil -> []
        section -> [section]
      end

    sections ++ binding_section
  end

  defp normalize_section(%Rho.PromptSection{} = s), do: s
  defp normalize_section(text) when is_binary(text), do: Rho.PromptSection.from_string(text)

  # --- Transformer stages (delegated to TransformerRegistry) ---

  @doc "Delegates to `Rho.TransformerRegistry.apply_stage/3`."
  defdelegate apply_stage(stage, data, context), to: Rho.TransformerRegistry

  # --- Private ---

  defp all_entries do
    :ets.tab2list(@table) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
  end

  defp safe_call(mod, callback, args, default) do
    with {:module, _} <- Code.ensure_loaded(mod),
         true <- function_exported?(mod, callback, length(args)) do
      try do
        apply(mod, callback, args)
      rescue
        e ->
          Logger.warning(
            "Plugin #{inspect(mod)}.#{callback}/#{length(args)} crashed: #{inspect(e)}"
          )

          default
      end
    else
      _ -> default
    end
  end
end
