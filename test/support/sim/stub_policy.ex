defmodule Rho.Sim.Test.StubPolicy do
  use Rho.Sim.Policy

  def decide(_actor_id, _observation, _ctx, state) do
    {:ok, :noop, state}
  end
end
