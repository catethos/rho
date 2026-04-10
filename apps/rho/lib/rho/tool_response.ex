defmodule Rho.ToolResponse do
  @moduledoc """
  Rich tool result that separates content from UI effects.

  Tools return a `%Rho.ToolResponse{}` when they need to produce
  both textual output (sent back to the LLM) and side-effects
  (routed to the UI layer).

  ## Fields

    * `text` — text result returned to the LLM (required)
    * `data` — optional structured data (not sent to LLM, available for effects)
    * `effects` — list of effect structs dispatched after the tool completes
  """

  @type t :: %__MODULE__{
          text: String.t() | nil,
          data: term(),
          effects: [struct()]
        }

  defstruct text: nil, data: nil, effects: []
end
