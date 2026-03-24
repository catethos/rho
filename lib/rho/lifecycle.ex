defmodule Rho.Lifecycle do
  @moduledoc """
  The four mount lifecycle hooks captured as a struct of plain functions.

  Mounts can define hooks that run at specific points in the agent loop:

  * `before_llm` — modify the messages/tools before each LLM call
  * `before_tool` — allow or deny a tool call before execution
  * `after_tool` — inspect or replace a tool's result after execution
  * `after_step` — inject user-role messages after a step completes

  A Lifecycle struct wraps these as closures so that consumers (AgentLoop,
  Reasoner.Direct) call plain functions without knowing they come from
  MountRegistry. This decouples hook dispatch from hook consumption.

  Use `from_mount_registry/1` to build from registered mounts, or
  `noop/0` for testing and mount-free agents.
  """

  alias Rho.Mount.Context

  @type tool_call :: %{name: String.t(), args: map(), call_id: String.t()}

  @type t :: %__MODULE__{
          before_llm: (map() -> map()),
          before_tool: (tool_call() -> :ok | {:deny, String.t()}),
          after_tool: (tool_call(), String.t() -> String.t()),
          after_step: (pos_integer(), pos_integer() -> [String.t()])
        }

  defstruct [:before_llm, :before_tool, :after_tool, :after_step]

  @doc "Build lifecycle hooks backed by MountRegistry dispatch."
  @spec from_mount_registry(Context.t()) :: t()
  def from_mount_registry(%Context{} = ctx) do
    %__MODULE__{
      before_llm: fn projection ->
        Rho.MountRegistry.dispatch_before_llm(projection, ctx)
      end,
      before_tool: fn call ->
        Rho.MountRegistry.dispatch_before_tool(call, ctx)
      end,
      after_tool: fn call, result ->
        Rho.MountRegistry.dispatch_after_tool(call, result, ctx)
      end,
      after_step: fn step, max_steps ->
        case Rho.MountRegistry.dispatch_after_step(step, max_steps, ctx) do
          :ok -> []
          {:inject, messages} -> List.wrap(messages)
        end
      end
    }
  end

  @doc "No-op lifecycle for testing or mount-free agents."
  @spec noop() :: t()
  def noop do
    %__MODULE__{
      before_llm: fn projection -> projection end,
      before_tool: fn _call -> :ok end,
      after_tool: fn _call, result -> result end,
      after_step: fn _step, _max -> [] end
    }
  end
end
