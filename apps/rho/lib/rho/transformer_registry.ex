defmodule Rho.TransformerRegistry do
  @moduledoc """
  Transformer registration and stage dispatch.

  Separate from PluginRegistry (which handles capability contribution).
  A module may implement both Rho.Plugin and Rho.Transformer, but
  registers separately for each role.
  """
  use GenServer
  require Logger

  alias Rho.TransformerInstance

  @table :rho_transformer_instances

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
  Register a transformer module with optional configuration.

  Later registrations have higher priority.

  ## Options

    * `:scope` — `:global` (default) or `{:agent, agent_name}`
    * `:opts` — keyword list passed to transformer callbacks
  """
  def register(transformer_module, opts \\ []) do
    GenServer.call(__MODULE__, {:register, transformer_module, opts})
  end

  @doc "Clears all registered transformers. Useful for testing."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def handle_call({:register, transformer_module, opts}, _from, %{next_priority: p} = state) do
    Code.ensure_loaded!(transformer_module)
    scope = Keyword.get(opts, :scope, :global)
    transformer_opts = Keyword.get(opts, :opts, [])

    instance = %TransformerInstance{
      module: transformer_module,
      opts: transformer_opts,
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

  @doc "Return ordered list of TransformerInstance structs matching context (highest priority first)."
  def active_transformers(context) do
    agent_name = Map.get(context, :agent_name)

    all_entries()
    |> Enum.filter(fn %TransformerInstance{scope: scope} ->
      case scope do
        :global -> true
        {:agent, name} -> agent_name == name
      end
    end)
  end

  # --- Stage dispatch ---

  @doc """
  Apply a transformer stage across all active transformers.

  Return value depends on the stage (see `Rho.Transformer`):

    * `:prompt_out`, `:response_in`, `:tool_result_in` —
      `{:cont, data} | {:halt, reason}`
    * `:tool_args_out` —
      `{:cont, data} | {:deny, reason} | {:halt, reason}`
    * `:post_step` —
      `{:cont, nil} | {:inject, [msg]} | {:halt, reason}`
    * `:tape_write` — `{:cont, data}` (halt disallowed)
  """
  @spec apply_stage(Rho.Transformer.stage(), term(), map()) :: term()
  def apply_stage(stage, data, context) do
    if is_map(context) and Map.get(context, :subagent) == true do
      subagent_passthrough(stage, data)
    else
      do_apply_stage(stage, data, context)
    end
  end

  defp subagent_passthrough(:post_step, _data), do: {:cont, nil}
  defp subagent_passthrough(_stage, data), do: {:cont, data}

  defp do_apply_stage(:tape_write, data, context) do
    Enum.reduce(active_transformers(context), {:cont, data}, fn
      %TransformerInstance{module: mod, opts: opts}, {:cont, current} = acc ->
        case safe_transform(mod, :tape_write, current, opts, context, {:cont, current}) do
          {:cont, _} = next ->
            next

          {:halt, reason} ->
            Logger.warning(
              "Transformer #{inspect(mod)} returned :halt at :tape_write (not allowed): #{inspect(reason)}"
            )

            acc

          other ->
            Logger.warning(
              "Transformer #{inspect(mod)} returned invalid :tape_write result: #{inspect(other)}"
            )

            acc
        end
    end)
  end

  defp do_apply_stage(:post_step, data, context) do
    Enum.reduce_while(active_transformers(context), {:cont, nil, []}, fn
      %TransformerInstance{module: mod, opts: opts}, {:cont, _, acc_msgs} = _acc ->
        case safe_transform(mod, :post_step, data, opts, context, {:cont, nil}) do
          {:cont, _anything} ->
            {:cont, {:cont, nil, acc_msgs}}

          {:inject, msg} when is_binary(msg) ->
            {:cont, {:cont, nil, acc_msgs ++ [msg]}}

          {:inject, msgs} when is_list(msgs) ->
            {:cont, {:cont, nil, acc_msgs ++ msgs}}

          {:halt, _reason} = halt ->
            {:halt, halt}

          other ->
            Logger.warning(
              "Transformer #{inspect(mod)} returned invalid :post_step result: #{inspect(other)}"
            )

            {:cont, {:cont, nil, acc_msgs}}
        end
    end)
    |> case do
      {:cont, nil, []} -> {:cont, nil}
      {:cont, nil, msgs} -> {:inject, msgs}
      {:halt, _} = halt -> halt
    end
  end

  defp do_apply_stage(:tool_args_out, data, context) do
    Enum.reduce_while(active_transformers(context), {:cont, data}, fn
      %TransformerInstance{module: mod, opts: opts}, {:cont, current} ->
        case safe_transform(mod, :tool_args_out, current, opts, context, {:cont, current}) do
          {:cont, _new} = next ->
            {:cont, next}

          {:deny, _reason} = deny ->
            {:halt, deny}

          {:halt, _reason} = halt ->
            {:halt, halt}

          other ->
            Logger.warning(
              "Transformer #{inspect(mod)} returned invalid :tool_args_out result: #{inspect(other)}"
            )

            {:cont, {:cont, current}}
        end
    end)
  end

  defp do_apply_stage(stage, data, context)
       when stage in [:prompt_out, :response_in, :tool_result_in] do
    Enum.reduce_while(active_transformers(context), {:cont, data}, fn
      %TransformerInstance{module: mod, opts: opts}, {:cont, current} ->
        case safe_transform(mod, stage, current, opts, context, {:cont, current}) do
          {:cont, _new} = next ->
            {:cont, next}

          {:halt, _reason} = halt ->
            {:halt, halt}

          other ->
            Logger.warning(
              "Transformer #{inspect(mod)} returned invalid #{inspect(stage)} result: #{inspect(other)}"
            )

            {:cont, {:cont, current}}
        end
    end)
  end

  # --- Private ---

  defp all_entries do
    :ets.tab2list(@table) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
  end

  defp safe_transform(mod, stage, data, _opts, context, default) do
    with {:module, _} <- Code.ensure_loaded(mod),
         true <- function_exported?(mod, :transform, 3) do
      try do
        apply(mod, :transform, [stage, data, context])
      rescue
        e ->
          Logger.warning(
            "Transformer #{inspect(mod)}.transform/3 (#{inspect(stage)}) crashed: #{inspect(e)}"
          )

          default
      end
    else
      _ -> default
    end
  end
end
