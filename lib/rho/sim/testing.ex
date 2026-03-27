defmodule Rho.Sim.Testing do
  @moduledoc """
  Test helpers for Rho.Sim — context factory, determinism assertions, and
  single-step convenience wrappers.
  """

  import ExUnit.Assertions

  alias Rho.Sim.{Engine, Accumulator, Context}

  @doc """
  Build a `%Rho.Sim.Context{}` with sensible defaults.

  Default values:
    - run_id: "test_run"
    - step: 0
    - max_steps: 100
    - seed: 42
    - params: %{}

  Any field can be overridden via keyword list.
  """
  @spec build_context(keyword()) :: Context.t()
  def build_context(overrides \\ []) do
    %Context{
      run_id: Keyword.get(overrides, :run_id, "test_run"),
      step: Keyword.get(overrides, :step, 0),
      max_steps: Keyword.get(overrides, :max_steps, 100),
      seed: Keyword.get(overrides, :seed, 42),
      params: Keyword.get(overrides, :params, %{})
    }
  end

  @doc """
  Assert that two runs with the same seed produce identical `step_metrics`.

  Runs `Engine.run/2` twice with the same options and asserts that
  `Accumulator.step_metrics/1` returns identical results for both runs.
  """
  @spec assert_deterministic(module(), keyword()) :: :ok
  def assert_deterministic(domain, opts) do
    {:ok, {run1, acc1}} = Engine.new(domain, opts)
    {:halted, {_run1, final_acc1}} = Engine.run(run1, acc1)

    {:ok, {run2, acc2}} = Engine.new(domain, opts)
    {:halted, {_run2, final_acc2}} = Engine.run(run2, acc2)

    assert Accumulator.step_metrics(final_acc1) == Accumulator.step_metrics(final_acc2)
    :ok
  end

  @doc """
  Run a single step and return the result for inspection.

  Convenience wrapper that calls `Engine.new/2` then `Engine.step/2` once.
  """
  @spec run_one_step(module(), keyword(), map(), keyword()) :: Engine.step_result()
  def run_one_step(domain, domain_opts, policies, opts \\ []) do
    seed = Keyword.get(opts, :seed, 42)
    max_steps = Keyword.get(opts, :max_steps, 100)
    interventions = Keyword.get(opts, :interventions, %{})
    params = Keyword.get(opts, :params, %{})

    {:ok, {run, acc}} =
      Engine.new(domain,
        domain_opts: domain_opts,
        policies: policies,
        seed: seed,
        max_steps: max_steps,
        interventions: interventions,
        params: params
      )

    Engine.step({run, acc})
  end
end
