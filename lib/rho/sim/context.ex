defmodule Rho.Sim.Context do
  @type t :: %__MODULE__{}

  @enforce_keys [:run_id, :step, :max_steps, :seed]
  defstruct [:run_id, :step, :max_steps, :seed, params: %{}]
end
