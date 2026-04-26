defmodule RhoWeb.LiveEvents do
  @moduledoc """
  Thin delegation to `Rho.Events`.

  Retained for backward-compatibility with existing rho_web callers.
  New code should use `Rho.Events` directly.
  """

  defdelegate subscribe(session_id), to: Rho.Events
  defdelegate unsubscribe(session_id), to: Rho.Events
  defdelegate broadcast(session_id, event), to: Rho.Events
  defdelegate normalize(emit_event, session_id, agent_id), to: Rho.Events
  defdelegate event(kind, session_id), to: Rho.Events
  defdelegate event(kind, session_id, agent_id), to: Rho.Events
  defdelegate event(kind, session_id, agent_id, data), to: Rho.Events
end
