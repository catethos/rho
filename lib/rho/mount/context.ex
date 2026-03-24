defmodule Rho.Mount.Context do
  @moduledoc """
  Ambient state passed to every mount callback.

  Identifies the current agent, model, tape, workspace, and depth so that
  mount implementations can scope their behavior (e.g., only provide
  certain tools at depth 0, or only inject prompts for a specific agent).

  Built once at the start of `AgentLoop.run/3` from the caller's options.
  """

  @behaviour Access

  @enforce_keys [:model, :agent_name]
  defstruct [
    :model,
    :tape_name,
    :memory_mod,
    :input_messages,
    :opts,
    :workspace,
    :agent_name,
    :depth,
    :subagent,
    :agent_id,
    :session_id,
    :prompt_format
  ]

  @type t :: %__MODULE__{
          model: term(),
          tape_name: String.t() | nil,
          memory_mod: module(),
          input_messages: [map()],
          opts: keyword(),
          workspace: term(),
          agent_name: term(),
          depth: non_neg_integer(),
          subagent: boolean(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          prompt_format: :markdown | :xml | nil
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
