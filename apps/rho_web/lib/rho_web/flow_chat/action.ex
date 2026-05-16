defmodule RhoWeb.FlowChat.Action do
  @moduledoc """
  A chat-native action for a flow step.

  Actions are intentionally payload-first: LiveView can render them as buttons,
  and typed replies can normalize to the same payload.
  """

  @enforce_keys [:id, :label, :payload]
  defstruct [:id, :label, :payload, :event, :variant]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          payload: map(),
          event: atom() | nil,
          variant: :primary | :secondary | nil
        }
end
