defmodule RhoWeb.LiveEventsBroadcaster do
  @moduledoc """
  Application-level event broadcaster that bridges `Rho.Agent.Worker`
  (in `apps/rho/`) to `RhoWeb.LiveEvents` (in `apps/rho_web/`).

  Worker can't depend on rho_web directly. Instead, it reads
  `Application.get_env(:rho, :event_broadcaster)` and calls the two
  functions below. This module is that configured broadcaster.

  ## Functions

    * `broadcast_emit/3` — for Runner emit events (text_delta, tool_start, etc.)
    * `broadcast_event/4` — for lifecycle/task events (agent_started, agent_stopped, etc.)
  """

  alias RhoWeb.LiveEvents

  @doc """
  Broadcast a Runner emit event via LiveEvents.

  The `emit_event` map has `%{type: atom(), ...}` — same shape as what
  `Worker.build_emit` produces before `publish_emit_signal`.
  """
  @spec broadcast_emit(map(), String.t(), String.t()) :: :ok
  def broadcast_emit(%{type: _} = emit_event, session_id, agent_id) do
    event = LiveEvents.normalize(emit_event, session_id, agent_id)
    LiveEvents.broadcast(session_id, event)
    :ok
  end

  @doc """
  Broadcast a lifecycle or task event via LiveEvents.

  Used for events that don't originate from the Runner emit closure
  (agent_started, agent_stopped, task_completed).
  """
  @spec broadcast_event(atom(), String.t(), String.t() | nil, map()) :: :ok
  def broadcast_event(kind, session_id, agent_id, data) do
    event = LiveEvents.event(kind, session_id, agent_id, data)
    LiveEvents.broadcast(session_id, event)
    :ok
  end
end
