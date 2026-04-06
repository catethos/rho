defmodule Rho.Context do
  @moduledoc """
  Ambient state passed to every plugin/mount callback.

  Identifies the current agent, tape, workspace, depth, and (when
  applicable) the owning user and session so that plugin implementations
  can scope their behaviour — e.g. only expose certain tools at depth 0,
  or only inject prompts for a specific agent.

  Built once at the start of `Rho.Runner.run/3` from caller options.
  """

  @behaviour Access

  @enforce_keys [:agent_name]
  defstruct [
    # purpose: tape reference this agent reads/writes; `nil` when no
    # persistent tape is configured.
    :tape_name,
    # purpose: tape backend module (e.g. `Rho.Tape.Context.Tape`);
    # plugins like subagent/multi_agent use it to spin up child tapes.
    :tape_module,
    # purpose: working directory for filesystem/bash tools. May be a
    # sandbox mount path when sandboxing is enabled.
    :workspace,
    # purpose: logical agent role (`:default`, `:coder`, `:researcher`,
    # …) used by `PluginRegistry` for `{:agent, name}` scope filtering.
    :agent_name,
    # purpose: delegation depth — 0 for primary agents, +1 per nested
    # delegation. Plugins use it to gate tools at nested depths.
    :depth,
    # purpose: `true` for agents running in subagent mode; read by
    # `PluginRegistry.apply_stage/3` to short-circuit transformer
    # dispatch (subagent agents pass every stage through unchanged).
    :subagent,
    # purpose: unique agent process identifier, stable for the life of
    # the agent.
    :agent_id,
    # purpose: session namespace this agent belongs to; ties together
    # cooperating agents and their bus topic.
    :session_id,
    # purpose: `:markdown` | `:xml` — how `Runner` renders prompt
    # sections into the system prompt.
    :prompt_format,
    # purpose: owning user id (when auth is enabled); used by
    # user-scoped plugins like framework_persistence.
    :user_id
  ]

  @type t :: %__MODULE__{
          tape_name: String.t() | nil,
          tape_module: module(),
          workspace: term(),
          agent_name: term(),
          depth: non_neg_integer(),
          subagent: boolean(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          prompt_format: :markdown | :xml | nil,
          user_id: String.t() | nil
        }

  @impl Access
  def fetch(ctx, key), do: Map.fetch(ctx, key)

  @impl Access
  def get_and_update(ctx, key, fun) do
    {current, updated} = fun.(Map.get(ctx, key))
    {current, Map.put(ctx, key, updated)}
  end

  @impl Access
  def pop(ctx, key) do
    {Map.get(ctx, key), Map.put(ctx, key, nil)}
  end
end
