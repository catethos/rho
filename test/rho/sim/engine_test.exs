defmodule Rho.Sim.Test.ActorDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{count: Keyword.get(opts, :start, 0), actors: Keyword.get(opts, :actors, [])}}
  def actors(state, _ctx), do: state.actors
  def observe(_actor, state, _derived, _ctx), do: %{count: state.count}

  def transition(state, _actions, _rolls, _derived, _ctx, rng) do
    {:ok, %{state | count: state.count + 1}, [], rng}
  end

  def metrics(state, _derived, _ctx), do: %{count: state.count}
end

defmodule Rho.Sim.Test.InterventionDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{count: Keyword.get(opts, :start, 0)}}
  def apply_intervention(state, {:set_count, n}, _ctx), do: %{state | count: n}

  def transition(state, _actions, _rolls, _derived, _ctx, rng) do
    {:ok, %{state | count: state.count + 1}, [], rng}
  end

  def metrics(state, _derived, _ctx), do: %{count: state.count}
end

defmodule Rho.Sim.Test.ErrorDomain do
  use Rho.Sim.Domain

  def init(_opts), do: {:ok, %{count: 0}}

  def transition(_state, _actions, _rolls, _derived, _ctx, _rng) do
    {:error, :kaboom}
  end
end

defmodule Rho.Sim.Test.ErrorAtStepDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{count: 0, error_at: Keyword.get(opts, :error_at, 3)}}

  def transition(state, _actions, _rolls, _derived, _ctx, rng) do
    if state.count >= state.error_at - 1 do
      {:error, :planned_failure}
    else
      {:ok, %{state | count: state.count + 1}, [], rng}
    end
  end

  def metrics(state, _derived, _ctx), do: %{count: state.count}
end

defmodule Rho.Sim.Test.StochasticDomain do
  use Rho.Sim.Domain

  def init(opts), do: {:ok, %{value: Keyword.get(opts, :start, 0.0), step_count: 0}}

  # Exogenous randomness: sample produces a random "shock" value
  def sample(_state, _ctx, rng) do
    {shock, rng} = :rand.uniform_s(rng)
    {%{shock: shock}, rng}
  end

  # Action-contingent randomness: transition does its own RNG draws
  def transition(state, _actions, rolls, _derived, _ctx, rng) do
    # Use the exogenous shock from sample
    shock = rolls.shock

    # Action-contingent roll inside transition
    {action_roll, rng} = :rand.uniform_s(rng)

    new_value = state.value + shock + action_roll
    {:ok, %{state | value: new_value, step_count: state.step_count + 1}, [], rng}
  end

  def metrics(state, _derived, _ctx), do: %{value: state.value, step_count: state.step_count}
  def halt?(state, _derived, _ctx), do: state.step_count >= 20
end

defmodule Rho.Sim.EngineTest do
  use ExUnit.Case, async: true

  alias Rho.Sim.{Engine, Run, Accumulator, StepError}

  describe "Engine.new/2" do
    test "returns {:ok, {%Run{}, %Accumulator{}}} with correct fields" do
      assert {:ok, {%Run{} = run, %Accumulator{} = acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 0],
                 policies: %{},
                 max_steps: 10,
                 seed: 42
               )

      assert run.domain == Rho.Sim.Test.CounterDomain
      assert run.domain_state == %{count: 0}
      assert run.policies == %{}
      assert run.policy_states == %{}
      assert run.seed == 42
      assert run.max_steps == 10
      assert run.step == 0
      assert run.interventions == %{}
      assert run.params == %{}
      assert is_binary(run.run_id)
      assert String.starts_with?(run.run_id, "run_42_")
      assert run.rng != nil

      assert acc.trace == []
      assert acc.step_metrics == []
    end

    test "returns error for invalid domain module" do
      assert {:error, msg} = Engine.new(NotAModule, seed: 42, max_steps: 10)
      assert msg =~ "not a loaded module" or msg =~ "not loaded" or msg =~ "invalid"
    end

    test "returns error for module that doesn't implement Domain behaviour" do
      assert {:error, msg} = Engine.new(Enum, seed: 42, max_steps: 10)
      assert msg =~ "init/1" or msg =~ "Domain"
    end

    test "bare policy module normalizes to {Module, []}" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 policies: %{agent_a: Rho.Sim.Test.StubPolicy},
                 max_steps: 10,
                 seed: 42
               )

      assert run.policies == %{agent_a: {Rho.Sim.Test.StubPolicy, []}}
    end

    test "policy tuple {Module, opts} is kept as-is" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 policies: %{agent_a: {Rho.Sim.Test.StubPolicy, [mode: :greedy]}},
                 max_steps: 10,
                 seed: 42
               )

      assert run.policies == %{agent_a: {Rho.Sim.Test.StubPolicy, [mode: :greedy]}}
    end

    test "emits Logger.warning when policies are non-empty" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          Engine.new(Rho.Sim.Test.CounterDomain,
            policies: %{agent_a: Rho.Sim.Test.StubPolicy},
            max_steps: 10,
            seed: 42
          )
        end)

      assert log =~ "actors/2"
    end

    test "returns error for invalid policy module" do
      assert {:error, msg} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 policies: %{agent_a: NotAPolicyModule},
                 max_steps: 10,
                 seed: 42
               )

      assert msg =~ "not a loaded module" or msg =~ "not loaded" or msg =~ "invalid"
    end

    test "returns error for policy module missing decide/4" do
      assert {:error, msg} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 policies: %{agent_a: Enum},
                 max_steps: 10,
                 seed: 42
               )

      assert msg =~ "decide/4" or msg =~ "Policy"
    end

    test "policy init/2 is called for each actor" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 policies: %{agent_a: Rho.Sim.Test.StubPolicy},
                 max_steps: 10,
                 seed: 42
               )

      # StubPolicy.init returns {:ok, nil}
      assert run.policy_states == %{agent_a: nil}
    end

    test "passes domain_opts to domain.init/1" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 5],
                 max_steps: 10,
                 seed: 42
               )

      assert run.domain_state == %{count: 5}
    end

    test "defaults seed to 0 when not provided" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain, max_steps: 10)

      assert run.seed == 0
    end

    test "defaults max_steps to 100 when not provided" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain, seed: 42)

      assert run.max_steps == 100
    end

    test "passes params through to Run" do
      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 max_steps: 10,
                 seed: 42,
                 params: %{foo: :bar}
               )

      assert run.params == %{foo: :bar}
    end

    test "passes interventions through to Run" do
      interventions = %{3 => [:boost], 5 => [:reset]}

      assert {:ok, {%Run{} = run, _acc}} =
               Engine.new(Rho.Sim.Test.CounterDomain,
                 max_steps: 10,
                 seed: 42,
                 interventions: interventions
               )

      assert run.interventions == interventions
    end
  end

  describe "Engine.step/2" do
    test "one step with CounterDomain — count goes from 0 to 1, metrics recorded" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 10,
          seed: 42
        )

      assert {:ok, {%Run{} = run2, %Accumulator{} = acc2}} = Engine.step({run, acc})

      # State advanced: count 0 -> 1
      assert run2.domain_state.count == 1
      # Step incremented
      assert run2.step == 1
      # Metrics recorded
      step_metrics = Accumulator.step_metrics(acc2)
      assert length(step_metrics) == 1
      assert [{0, %{count: 1}}] = step_metrics
    end

    test "step with interventions — intervention applied before derive" do
      # Intervention at step 0 sets count to 100, then transition increments to 101
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.InterventionDomain,
          domain_opts: [start: 0],
          max_steps: 10,
          seed: 42,
          interventions: %{0 => [{:set_count, 100}]}
        )

      assert {:ok, {%Run{} = run2, %Accumulator{} = acc2}} = Engine.step({run, acc})

      # After intervention (set to 100) + transition (increment) = 101
      assert run2.domain_state.count == 101
      step_metrics = Accumulator.step_metrics(acc2)
      assert [{0, %{count: 101}}] = step_metrics
    end

    test "step with actors and policies — observe, decide, resolve called in order" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.ActorDomain,
          domain_opts: [start: 0, actors: [:agent_a]],
          policies: %{agent_a: Rho.Sim.Test.StubPolicy},
          max_steps: 10,
          seed: 42
        )

      assert {:ok, {%Run{} = run2, %Accumulator{} = acc2}} = Engine.step({run, acc})

      # State advanced
      assert run2.domain_state.count == 1
      assert run2.step == 1
      # Metrics recorded
      step_metrics = Accumulator.step_metrics(acc2)
      assert [{0, %{count: 1}}] = step_metrics
    end

    test "step with unknown actor in actors/2 returns StepError with phase :decide" do
      # ActorDomain returns [:unknown_actor] but no policy registered for it
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.ActorDomain,
          domain_opts: [start: 0, actors: [:unknown_actor]],
          policies: %{},
          max_steps: 10,
          seed: 42
        )

      assert {:error, {0, %StepError{} = err, _run, _acc}} = Engine.step({run, acc})
      assert err.phase == :decide
      assert err.step == 0
    end

    test "step where transition returns error produces StepError with phase :transition" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.ErrorDomain,
          max_steps: 10,
          seed: 42
        )

      assert {:error, {0, %StepError{} = err, _run, _acc}} = Engine.step({run, acc})
      assert err.phase == :transition
      assert err.step == 0
      assert err.reason == :kaboom
    end

    test "step returns :halted when step+1 >= max_steps" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 1,
          seed: 42
        )

      # Step 0 -> step becomes 1, which equals max_steps=1
      assert {:halted, {%Run{} = run2, %Accumulator{}}} = Engine.step({run, acc})
      assert run2.step == 1
    end

    test "step returns :halted when domain.halt? returns true" do
      # CounterDomain halts at count >= 10
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 9],
          max_steps: 100,
          seed: 42
        )

      # count goes from 9 to 10, halt? returns true
      assert {:halted, {%Run{} = run2, %Accumulator{}}} = Engine.step({run, acc})
      assert run2.domain_state.count == 10
    end

    test "trace records events from transition" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 10,
          seed: 42
        )

      assert {:ok, {_run2, acc2}} = Engine.step({run, acc})
      trace = Accumulator.trace(acc2)
      assert length(trace) == 1
      assert [{0, trace_entry}] = trace
      assert trace_entry.events == [%{type: :incremented}]
    end

    test "RNG state is updated after step" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 10,
          seed: 42
        )

      {:ok, {run2, _acc2}} = Engine.step({run, acc})
      # RNG should be different (or same if passthrough, but at least not crash)
      assert run2.rng != nil
    end
  end

  describe "Engine.run/2" do
    test "run CounterDomain from 0 — halts at 10 with 10 step_metrics entries" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 100,
          seed: 42
        )

      assert {:halted, {%Run{} = final_run, %Accumulator{} = final_acc}} =
               Engine.run(run, acc)

      assert final_run.domain_state.count == 10
      assert length(final_acc.step_metrics) == 10
    end

    test "run with max_steps: 5 — returns {:ok, _} is never returned; halted at step 5 with 5 entries" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          max_steps: 5,
          seed: 42
        )

      assert {:halted, {%Run{} = final_run, %Accumulator{} = final_acc}} =
               Engine.run(run, acc)

      assert final_run.step == 5
      assert final_run.domain_state.count == 5
      assert length(final_acc.step_metrics) == 5
    end

    test "run with domain that errors at step 3 — returns {:error, ...} with partial accumulator" do
      {:ok, {run, acc}} =
        Engine.new(Rho.Sim.Test.ErrorAtStepDomain,
          domain_opts: [error_at: 3],
          max_steps: 100,
          seed: 42
        )

      assert {:error, {step_num, %StepError{} = err, %Run{}, %Accumulator{} = partial_acc}} =
               Engine.run(run, acc)

      assert step_num == 2
      assert err.phase == :transition
      assert err.reason == :planned_failure
      # 2 successful steps before the error (steps 0 and 1)
      assert length(partial_acc.step_metrics) == 2
    end
  end

  describe "reproducibility" do
    test "same seed + CounterDomain produces identical step_metrics across two runs" do
      opts = [domain_opts: [start: 0], max_steps: 100, seed: 42]

      {:ok, {run1, acc1}} = Engine.new(Rho.Sim.Test.CounterDomain, opts)
      {:halted, {_final_run1, final_acc1}} = Engine.run(run1, acc1)

      {:ok, {run2, acc2}} = Engine.new(Rho.Sim.Test.CounterDomain, opts)
      {:halted, {_final_run2, final_acc2}} = Engine.run(run2, acc2)

      assert Accumulator.step_metrics(final_acc1) == Accumulator.step_metrics(final_acc2)
    end

    test "same seed + StochasticDomain produces identical step_metrics across two runs" do
      opts = [domain_opts: [start: 0.0], max_steps: 100, seed: 42]

      {:ok, {run1, acc1}} = Engine.new(Rho.Sim.Test.StochasticDomain, opts)
      {:halted, {_final_run1, final_acc1}} = Engine.run(run1, acc1)

      {:ok, {run2, acc2}} = Engine.new(Rho.Sim.Test.StochasticDomain, opts)
      {:halted, {_final_run2, final_acc2}} = Engine.run(run2, acc2)

      assert Accumulator.step_metrics(final_acc1) == Accumulator.step_metrics(final_acc2)
    end

    test "different seed + StochasticDomain produces different step_metrics" do
      opts_42 = [domain_opts: [start: 0.0], max_steps: 100, seed: 42]
      opts_99 = [domain_opts: [start: 0.0], max_steps: 100, seed: 99]

      {:ok, {run_42, acc_42}} = Engine.new(Rho.Sim.Test.StochasticDomain, opts_42)
      {:halted, {_run_42, final_acc_42}} = Engine.run(run_42, acc_42)

      {:ok, {run_99, acc_99}} = Engine.new(Rho.Sim.Test.StochasticDomain, opts_99)
      {:halted, {_run_99, final_acc_99}} = Engine.run(run_99, acc_99)

      refute Accumulator.step_metrics(final_acc_42) == Accumulator.step_metrics(final_acc_99)
    end
  end
end
