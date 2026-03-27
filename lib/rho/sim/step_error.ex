defmodule Rho.Sim.StepError do
  defstruct [:step, :phase, :actor, :module, :reason, :stacktrace]

  # step: which step the error occurred at
  # phase: :init | :intervention | :derive | :sample | :observe | :decide |
  #        :resolve | :transition | :metrics | :halt
end
