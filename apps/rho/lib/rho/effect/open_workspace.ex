defmodule Rho.Effect.OpenWorkspace do
  @moduledoc """
  Effect: request that a workspace panel be opened in the UI.
  """

  @type t :: %__MODULE__{
          key: atom(),
          surface: atom()
        }

  defstruct key: nil, surface: :overlay
end
