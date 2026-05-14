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
    # purpose: tape backend module (e.g. `Rho.Tape.Projection.JSONL`);
    # multi-agent plugins use it to spin up child tapes.
    :tape_module,
    # purpose: working directory for filesystem/bash tools. May be a
    # sandbox mount path when sandboxing is enabled.
    :workspace,
    # purpose: logical agent role (`:default`, `:coder`, `:researcher`,
    # …) used by `PluginRegistry` for `{:agent, name}` scope filtering.
    :agent_name,
    # purpose: delegation depth — 0 for primary agents, +1 per nested
    # delegation. Plugins and transformers gate on this (e.g.
    # `Rho.Stdlib.Transformers.SubagentNudge` only fires at depth > 0).
    :depth,
    # purpose: unique agent process identifier, stable for the life of
    # the agent.
    :agent_id,
    # purpose: session namespace this agent belongs to; ties together
    # cooperating agents and their bus topic.
    :session_id,
    # purpose: durable conversation metadata for joining tape entries to
    # user-facing conversations and threads.
    :conversation_id,
    :thread_id,
    # purpose: current turn id, when known. Used for trace metadata.
    :turn_id,
    # purpose: `:markdown` | `:xml` — how `Runner` renders prompt
    # sections into the system prompt.
    :prompt_format,
    # purpose: owning user id (when auth is enabled); used by
    # user-scoped plugins like framework_persistence.
    :user_id,
    # purpose: organization id for multi-tenant scoping; used by
    # org-scoped plugins like framework_persistence.
    :organization_id
  ]

  @type t :: %__MODULE__{
          tape_name: String.t() | nil,
          tape_module: module(),
          workspace: term(),
          agent_name: term(),
          depth: non_neg_integer(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          conversation_id: String.t() | nil,
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          prompt_format: :markdown | :xml | nil,
          user_id: String.t() | nil,
          organization_id: String.t() | nil
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
