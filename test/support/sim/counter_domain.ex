defmodule Rho.Sim.Test.CounterDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{count: Keyword.get(opts, :start, 0)}}

  def transition(state, _actions, _rolls, _derived, _ctx, rng) do
    {:ok, %{state | count: state.count + 1}, [%{type: :incremented}], rng}
  end

  def metrics(state, _derived, _ctx), do: %{count: state.count}

  def halt?(state, _derived, _ctx), do: state.count >= 10
end
