defmodule RhoFrameworks.Scope do
  @moduledoc """
  Business-level execution context for frameworks primitives.

  Carries only the fields that domain logic needs — organization, session,
  and user identity. No agent infrastructure (tape, depth, agent_id,
  prompt_format). Both agent tools and FlowLive construct a `Scope`
  and pass it to the same primitives.
  """

  @enforce_keys [:organization_id, :session_id]
  defstruct [
    :organization_id,
    :session_id,
    :user_id,
    :reason,
    source: nil
  ]

  @type source :: :user | :flow | :agent | nil

  @type t :: %__MODULE__{
          organization_id: String.t(),
          session_id: String.t(),
          user_id: String.t() | nil,
          source: source(),
          reason: String.t() | nil
        }

  @doc """
  Build a Scope from an agent's `Rho.Context`. Sets `source: :agent`
  because contexts are constructed by the agent runner.
  """
  @spec from_context(Rho.Context.t()) :: t()
  def from_context(%Rho.Context{} = ctx) do
    %__MODULE__{
      organization_id: ctx.organization_id,
      session_id: ctx.session_id,
      user_id: ctx.user_id,
      source: :agent
    }
  end
end
