defmodule Rho.AgentLoop.Runtime do
  @moduledoc """
  Immutable run configuration for one agent loop invocation.

  A Runtime bundles everything that stays constant across loop iterations:
  the LLM model, tool definitions, system prompt, emit callback, tape
  config, and lifecycle hooks. It is built once at the start of
  `AgentLoop.run/3` and threaded through every function in the loop,
  including the reasoner.

  The reasoner receives the Runtime as its `context` parameter, so it can
  access the model, emit callback, and lifecycle hooks without knowing
  where they came from.
  """

  alias Rho.AgentLoop.Tape
  alias Rho.Lifecycle
  alias Rho.Mount.Context

  @enforce_keys [:model, :reasoner, :emit, :gen_opts, :tool_defs, :req_tools, :tool_map,
                  :system_prompt, :subagent, :depth, :tape, :mount_context, :lifecycle]
  defstruct [
    :model,
    :reasoner,
    :emit,
    :gen_opts,
    :tool_defs,
    :req_tools,
    :tool_map,
    :system_prompt,
    :subagent,
    :depth,
    :tape,
    :mount_context,
    :lifecycle
  ]

  @type t :: %__MODULE__{
          model: term(),
          reasoner: module(),
          emit: (map() -> :ok),
          gen_opts: keyword(),
          tool_defs: [map()],
          req_tools: [ReqLLM.Tool.t()],
          tool_map: %{String.t() => map()},
          system_prompt: String.t(),
          subagent: boolean(),
          depth: non_neg_integer(),
          tape: Tape.t(),
          mount_context: Context.t(),
          lifecycle: Lifecycle.t()
        }
end
