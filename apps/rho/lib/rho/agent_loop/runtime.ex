defmodule Rho.AgentLoop.Runtime do
  @moduledoc """
  Immutable run configuration for one agent loop invocation.

  A Runtime bundles everything that stays constant across loop iterations:
  the LLM model, tool definitions, system prompt, emit callback, tape
  config, and lifecycle hooks. It is built once at the start of
  `AgentLoop.run/3` and threaded through every function in the loop,
  including the turn strategy.

  The turn strategy receives the Runtime as its `context` parameter, so it
  can access the model, emit callback, and lifecycle hooks without knowing
  where they came from.
  """

  alias Rho.AgentLoop.Tape
  alias Rho.Context

  @enforce_keys [
    :model,
    :turn_strategy,
    :emit,
    :gen_opts,
    :tool_defs,
    :req_tools,
    :tool_map,
    :system_prompt,
    :subagent,
    :depth,
    :tape,
    :context
  ]
  defstruct [
    :model,
    :turn_strategy,
    :emit,
    :gen_opts,
    :tool_defs,
    :req_tools,
    :tool_map,
    :system_prompt,
    :subagent,
    :depth,
    :tape,
    :context,
    # Deprecated — Runner calls PluginRegistry.apply_stage/3 directly.
    # Kept for backward compatibility with test harnesses that set it
    # to a `%Rho.Lifecycle{}` (now removed) or any other term.
    :lifecycle
  ]

  @type t :: %__MODULE__{
          model: term(),
          turn_strategy: module(),
          emit: (map() -> :ok),
          gen_opts: keyword(),
          tool_defs: [map()],
          req_tools: [ReqLLM.Tool.t()],
          tool_map: %{String.t() => map()},
          system_prompt: String.t(),
          subagent: boolean(),
          depth: non_neg_integer(),
          tape: Tape.t(),
          context: Context.t(),
          lifecycle: any()
        }
end
