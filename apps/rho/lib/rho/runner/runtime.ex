defmodule Rho.Runner.Runtime do
  @moduledoc """
  Immutable run configuration for one agent loop invocation.

  Bundles everything that stays constant across loop iterations: the LLM model,
  tool definitions, system prompt, emit callback, tape config, and lifecycle
  hooks.
  """

  alias Rho.Context

  @enforce_keys [
    :model,
    :turn_strategy,
    :emit,
    :gen_opts,
    :tool_defs,
    :req_tools,
    :tool_map,
    :system_prompt_stable,
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
    :system_prompt_stable,
    :depth,
    :tape,
    :context,
    :lifecycle,
    system_prompt_volatile: "",
    lite: false
  ]

  @type t :: %__MODULE__{
          model: term(),
          turn_strategy: module(),
          emit: (map() -> :ok),
          gen_opts: keyword(),
          tool_defs: [map()],
          req_tools: [ReqLLM.Tool.t()],
          tool_map: %{String.t() => map()},
          system_prompt_stable: String.t(),
          system_prompt_volatile: String.t(),
          depth: non_neg_integer(),
          tape: Rho.Runner.TapeConfig.t(),
          context: Context.t(),
          lifecycle: any()
        }
end
