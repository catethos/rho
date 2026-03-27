defmodule Rho.Sim.Accumulator do
  @opaque t :: %__MODULE__{}

  defstruct [
    trace: [],          # [{step, trace_entry}] — prepend order, reverse on read
    step_metrics: []    # [{step, metrics_map}] — prepend order, reverse on read
  ]

  @doc "Returns trace in chronological order."
  def trace(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc "Returns step metrics in chronological order."
  def step_metrics(%__MODULE__{step_metrics: m}), do: Enum.reverse(m)
end
