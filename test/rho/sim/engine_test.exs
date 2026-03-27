defmodule Rho.Sim.EngineTest do
  use ExUnit.Case, async: true

  alias Rho.Sim.{Engine, Run, Accumulator}

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
end
