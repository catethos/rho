defmodule RhoFrameworks.Flow do
  @moduledoc """
  Behaviour for step-by-step wizard flows.

  Each flow defines a sequence of steps that execute composable primitives
  in a deterministic order. FlowLive drives the UI; this behaviour defines
  the shape.
  """

  @type step_type :: :form | :action | :table_review | :fan_out | :select

  @type step_def :: %{
          id: atom(),
          label: String.t(),
          type: step_type(),
          run: {module(), atom(), list()} | nil,
          config: map()
        }

  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback steps() :: [step_def()]
end
