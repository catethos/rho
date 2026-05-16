defmodule RhoWeb.FlowChat.Message do
  @moduledoc """
  Internal representation of a flow event projected into chat.

  These messages are not user-authored chat messages. They preserve flow/node
  provenance so the UI can render workflow prompts, choices, artifacts, and
  errors without pretending they came from the user.
  """

  alias RhoWeb.FlowChat.Action

  @enforce_keys [:kind, :flow_id, :node_id, :title, :body]
  defstruct [
    :kind,
    :flow_id,
    :node_id,
    :title,
    :body,
    actions: [],
    artifact: nil,
    fields: [],
    meta: %{}
  ]

  @type kind ::
          :flow_prompt
          | :flow_choice
          | :flow_artifact
          | :flow_decision
          | :flow_step_completed
          | :flow_error

  @type t :: %__MODULE__{
          kind: kind(),
          flow_id: String.t(),
          node_id: atom() | :done,
          title: String.t(),
          body: String.t(),
          actions: [Action.t()],
          artifact: map() | nil,
          fields: [map()],
          meta: map()
        }
end
