defmodule Rho.MountRegistry do
  @moduledoc """
  Mount registration and dispatch.

  The GenServer manages mount registration (write serialization).
  Collection and dispatch reads from ETS in the caller's process — no bottleneck.

  ## Scoping

  Mounts can be registered with a scope:

    * `:global` (default) — active for all agents
    * `{:agent, name}` — active only when `context[:agent_name]` matches `name`
  """
  use GenServer
  require Logger

  alias Rho.MountInstance

  @table :rho_mount_instances

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
  Register a mount module with optional configuration.

  Later registrations have higher priority.

  ## Options

    * `:scope` — `:global` (default) or `{:agent, agent_name}`
    * `:opts` — keyword list passed to mount callbacks as `mount_opts`
  """
  def register(mount_module, opts \\ []) do
    GenServer.call(__MODULE__, {:register, mount_module, opts})
  end

  @doc "Clears all registered mounts. Useful for testing."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def handle_call({:register, mount_module, opts}, _from, %{next_priority: p} = state) do
    Code.ensure_loaded!(mount_module)
    scope = Keyword.get(opts, :scope, :global)
    mount_opts = Keyword.get(opts, :opts, [])

    instance = %MountInstance{
      module: mount_module,
      opts: mount_opts,
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

  @doc "Return ordered list of MountInstance structs matching context (highest priority first)."
  def active_mounts(context) do
    agent_name = Map.get(context, :agent_name)

    all_entries()
    |> Enum.filter(fn %MountInstance{scope: scope} ->
      case scope do
        :global -> true
        {:agent, name} -> agent_name == name
      end
    end)
  end

  # --- Affordance collection ---

  @doc "Collect tools from all active mounts."
  def collect_tools(context) do
    active_mounts(context)
    |> Enum.flat_map(fn %MountInstance{module: mod, opts: opts} ->
      safe_call(mod, :tools, [opts, context], [])
    end)
  end

  @doc "Collect prompt sections from all active mounts."
  def collect_prompt_sections(context) do
    active_mounts(context)
    |> Enum.flat_map(fn %MountInstance{module: mod, opts: opts} ->
      safe_call(mod, :prompt_sections, [opts, context], [])
    end)
  end

  @doc "Collect bindings from all active mounts."
  def collect_bindings(context) do
    active_mounts(context)
    |> Enum.flat_map(fn %MountInstance{module: mod, opts: opts} ->
      safe_call(mod, :bindings, [opts, context], [])
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

  Raw strings returned by mounts are auto-wrapped. Bindings are converted
  into a single metadata section.
  """
  def collect_prompt_material(context) do
    alias Rho.Mount.PromptSection

    mounts = active_mounts(context)

    raw_sections =
      Enum.flat_map(mounts, fn %MountInstance{module: mod, opts: opts} ->
        safe_call(mod, :prompt_sections, [opts, context], [])
      end)

    raw_bindings =
      Enum.flat_map(mounts, fn %MountInstance{module: mod, opts: opts} ->
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

  defp normalize_section(%Rho.Mount.PromptSection{} = s), do: s
  defp normalize_section(text) when is_binary(text), do: Rho.Mount.PromptSection.from_string(text)

  # --- Hook dispatch ---

  @doc """
  Call `before_llm/3` in priority order, threading the projection through.
  Returns the final projection.
  """
  def dispatch_before_llm(projection, context) do
    active_mounts(context)
    |> Enum.reduce(projection, fn %MountInstance{module: mod, opts: opts}, proj ->
      case safe_call(mod, :before_llm, [proj, opts, context], {:ok, proj}) do
        {:ok, p} -> p
        {:replace, p} -> p
      end
    end)
  end

  @doc """
  Call `before_tool/3` in priority order. Short-circuits on `{:deny, reason}`.
  Returns `:ok` or `{:deny, reason}`.
  """
  def dispatch_before_tool(call, context) do
    active_mounts(context)
    |> Enum.reduce_while(:ok, fn %MountInstance{module: mod, opts: opts}, _acc ->
      case safe_call(mod, :before_tool, [call, opts, context], :ok) do
        :ok -> {:cont, :ok}
        {:deny, _reason} = deny -> {:halt, deny}
      end
    end)
  end

  @doc """
  Call `after_tool/4` in priority order. Short-circuits on `{:replace, new_result}`.
  Returns the effective result string.
  """
  def dispatch_after_tool(call, result, context) do
    active_mounts(context)
    |> Enum.reduce_while(result, fn %MountInstance{module: mod, opts: opts}, current_result ->
      case safe_call(
             mod,
             :after_tool,
             [call, current_result, opts, context],
             {:ok, current_result}
           ) do
        {:ok, r} -> {:cont, r}
        {:replace, new_result} -> {:halt, new_result}
      end
    end)
  end

  @doc """
  Call `after_step/4` in priority order. Collects injections.
  Returns `:ok` or `{:inject, messages}`.
  """
  def dispatch_after_step(step, max_steps, context) do
    active_mounts(context)
    |> Enum.reduce(:ok, fn %MountInstance{module: mod, opts: opts}, acc ->
      case safe_call(mod, :after_step, [step, max_steps, opts, context], :ok) do
        :ok ->
          acc

        {:inject, msg} when is_binary(msg) ->
          prev =
            case acc do
              {:inject, list} -> list
              _ -> []
            end

          {:inject, prev ++ [msg]}

        {:inject, msgs} when is_list(msgs) ->
          prev =
            case acc do
              {:inject, list} -> list
              _ -> []
            end

          {:inject, prev ++ msgs}
      end
    end)
  end

  # --- Private ---

  defp all_entries do
    :ets.tab2list(@table) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
  end

  defp safe_call(mod, callback, args, default) do
    if function_exported?(mod, callback, length(args)) do
      try do
        apply(mod, callback, args)
      rescue
        e ->
          Logger.warning(
            "Mount #{inspect(mod)}.#{callback}/#{length(args)} crashed: #{inspect(e)}"
          )

          default
      end
    else
      default
    end
  end
end
