defmodule Rho.Events.Event do
  @moduledoc """
  Canonical event struct for the PubSub event transport.

  Replaces dotted-string signal topics with atom-based `kind` fields.
  All session-scoped events flow through this struct.

  ## Fields

    * `:kind` — event type as an atom (e.g. `:text_delta`, `:tool_start`,
      `:agent_started`). Corresponds 1:1 with the Runner emit `:type` for
      turn-level events, and to lifecycle/task atoms for non-turn events.

    * `:session_id` — session this event belongs to.

    * `:agent_id` — agent that produced the event (nil for session-level events).

    * `:timestamp` — monotonic millisecond timestamp from `System.monotonic_time/1`.

    * `:data` — event payload map. Shape varies by kind (see below).

  ## Turn-level event kinds (from Worker.emit)

  These map 1:1 from the Runner emit `%{type: atom}`:

    * `:text_delta` — `%{text: String.t(), turn_id: String.t()}`
    * `:llm_text` — `%{text: String.t(), turn_id: String.t()}`
    * `:tool_start` — `%{name: String.t(), args: map(), call_id: String.t(), turn_id: String.t()}`
    * `:tool_result` — `%{name: String.t(), output: String.t(), status: atom(), call_id: String.t(), effects: list(), turn_id: String.t()}`
    * `:step_start` — `%{step: integer(), max_steps: integer(), turn_id: String.t()}`
    * `:llm_usage` — `%{usage: map(), turn_id: String.t()}`
    * `:turn_started` — `%{turn_id: String.t()}`
    * `:turn_finished` — `%{result: term(), turn_id: String.t()}`
    * `:turn_cancelled` — `%{turn_id: String.t()}`
    * `:before_llm` — `%{projection: map(), turn_id: String.t()}`
    * `:compact` — `%{tape_name: String.t(), turn_id: String.t()}`
    * `:error` — `%{reason: term(), turn_id: String.t()}`
    * `:structured_partial` — `%{parsed: term(), text: String.t(), turn_id: String.t()}`
    * `:ui_spec_delta` — `%{message_id: String.t(), title: String.t(), spec: map(), turn_id: String.t()}`
    * `:ui_spec` — `%{message_id: String.t(), title: String.t(), spec: map(), turn_id: String.t()}`
    * `:subagent_progress` — `%{step: integer(), max_steps: integer(), turn_id: String.t()}`
    * `:subagent_tool` — `%{name: String.t(), turn_id: String.t()}`
    * `:subagent_error` — `%{reason: term(), turn_id: String.t()}`

  ## Lifecycle event kinds (from Worker lifecycle)

    * `:agent_started` — `%{role: atom(), capabilities: list(), depth: integer(), model: String.t()}`
    * `:agent_stopped` — `%{}`

  ## Task event kinds (from multi-agent delegation)

    * `:task_requested` — `%{task: String.t(), role: atom(), worker_agent_id: String.t()}`
    * `:task_completed` — `%{result: String.t(), status: atom(), worker_agent_id: String.t()}`
    * `:task_progress` — `%{step: integer(), max_steps: integer()}`

  ## Effect event kinds (from EffectDispatcher)

    * `:data_table` — `%{event: atom(), view_key: atom(), mode_label: String.t(), table_name: String.t()}`
    * `:workspace_open` — `%{key: atom(), surface: atom()}`

  ## Inter-agent messaging

    * `:message_sent` — `%{from: String.t(), to: String.t(), message: String.t()}`
  """

  @type t :: %__MODULE__{
          kind: atom(),
          session_id: String.t(),
          agent_id: String.t() | nil,
          timestamp: integer(),
          data: map()
        }

  @enforce_keys [:kind, :session_id]
  defstruct [:kind, :session_id, :agent_id, :timestamp, data: %{}]
end
