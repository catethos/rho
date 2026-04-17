defmodule RhoFrameworks.Runtime do
  @moduledoc """
  Neutral execution context for composable primitives.

  Carries only the fields that business logic needs — no agent infra
  (tape, depth, prompt_format, subagent). Both agent tools and FlowLive
  construct a `Runtime` and pass it to the same primitives.
  """

  @enforce_keys [:mode, :organization_id, :session_id]
  defstruct [
    :mode,
    :organization_id,
    :session_id,
    :user_id,
    :execution_id,
    :parent_agent_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          mode: :agent | :flow,
          organization_id: String.t(),
          session_id: String.t(),
          user_id: String.t() | nil,
          execution_id: String.t() | nil,
          parent_agent_id: String.t() | nil,
          metadata: map()
        }

  @doc "Build a Runtime from an agent's `Rho.Context`."
  @spec from_rho_context(Rho.Context.t()) :: t()
  def from_rho_context(%Rho.Context{} = ctx) do
    %__MODULE__{
      mode: :agent,
      organization_id: ctx.organization_id,
      session_id: ctx.session_id,
      user_id: ctx.user_id,
      execution_id: ctx.agent_id,
      parent_agent_id: ctx.agent_id
    }
  end

  @doc "Build a Runtime for flow (deterministic pipeline) execution."
  @spec new_flow(keyword()) :: t()
  def new_flow(attrs) when is_list(attrs) do
    struct!(__MODULE__, Keyword.merge([mode: :flow], attrs))
  end

  @doc """
  Returns the parent identifier for LiteWorker fan-out.

  In agent mode this is the `parent_agent_id`; in flow mode it returns
  a synthetic `"flow:<execution_id>"` so that LiteWorker completions
  route to the correct listener.
  """
  @spec lite_parent_id(t()) :: String.t()
  def lite_parent_id(%__MODULE__{mode: :agent, parent_agent_id: id}) when is_binary(id), do: id

  def lite_parent_id(%__MODULE__{mode: :flow, execution_id: id}) when is_binary(id),
    do: "flow:#{id}"
end
