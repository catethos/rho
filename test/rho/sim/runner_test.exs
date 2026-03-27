defmodule Rho.Sim.RunnerTest do
  use ExUnit.Case, async: true

  alias Rho.Sim.{Runner, Accumulator}

  describe "run_many/1" do
    test "10 runs of CounterDomain — returns 10 completed results, 0 failures" do
      assert {:ok, result} =
               Runner.run_many(
                 domain: Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 0],
                 policies: %{},
                 runs: 10,
                 max_steps: 100,
                 base_seed: 42,
                 reduce: fn {_run, _acc} -> :ok end,
                 task_supervisor: Rho.TaskSupervisor
               )

      assert result.total == 10
      assert result.success_count == 10
      assert result.failure_count == 0
      assert length(result.completed) == 10
      assert result.failed == []
    end

    test "all 10 runs with same base_seed produce the same aggregate (deterministic ensemble)" do
      opts = [
        domain: Rho.Sim.Test.CounterDomain,
        domain_opts: [start: 0],
        policies: %{},
        runs: 10,
        max_steps: 100,
        base_seed: 42,
        reduce: fn {run, _acc} -> run.domain_state.count end,
        aggregate: fn results -> Enum.sum(results) / length(results) end,
        task_supervisor: Rho.TaskSupervisor
      ]

      {:ok, result1} = Runner.run_many(opts)
      {:ok, result2} = Runner.run_many(opts)

      assert result1.aggregate == result2.aggregate
      assert result1.completed == result2.completed
    end

    test "reduce extracts final count from each run, aggregate computes mean" do
      assert {:ok, result} =
               Runner.run_many(
                 domain: Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 0],
                 policies: %{},
                 runs: 10,
                 max_steps: 100,
                 base_seed: 42,
                 reduce: fn {run, _acc} -> run.domain_state.count end,
                 aggregate: fn results -> Enum.sum(results) / length(results) end,
                 task_supervisor: Rho.TaskSupervisor
               )

      # CounterDomain always halts at count >= 10, so every run ends with count == 10
      assert Enum.all?(result.completed, fn count -> count == 10 end)
      assert result.aggregate == 10.0
    end

    test "ErrorDomain runs return in failed list" do
      assert {:ok, result} =
               Runner.run_many(
                 domain: Rho.Sim.Test.ErrorDomain,
                 domain_opts: [],
                 policies: %{},
                 runs: 10,
                 max_steps: 100,
                 base_seed: 42,
                 reduce: fn {_run, _acc} -> :ok end,
                 task_supervisor: Rho.TaskSupervisor
               )

      assert result.total == 10
      assert result.success_count == 0
      assert result.failure_count == 10
      assert length(result.failed) == 10
      assert result.completed == []

      # Each failure includes the run_index and reason
      Enum.each(result.failed, fn {run_index, _reason} ->
        assert is_integer(run_index)
        assert run_index >= 0 and run_index < 10
      end)
    end

    test "keep_trace? false — accumulator trace is empty for all runs" do
      traces =
        Runner.run_many(
          domain: Rho.Sim.Test.CounterDomain,
          domain_opts: [start: 0],
          policies: %{},
          runs: 5,
          max_steps: 100,
          base_seed: 42,
          keep_trace?: false,
          reduce: fn {_run, acc} -> Accumulator.trace(acc) end,
          task_supervisor: Rho.TaskSupervisor
        )

      assert {:ok, result} = traces

      # When keep_trace? is false, trace should be empty for all runs
      Enum.each(result.completed, fn trace ->
        assert trace == []
      end)
    end

    test "keep_trace? true — accumulator trace is non-empty" do
      assert {:ok, result} =
               Runner.run_many(
                 domain: Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 0],
                 policies: %{},
                 runs: 3,
                 max_steps: 100,
                 base_seed: 42,
                 keep_trace?: true,
                 reduce: fn {_run, acc} -> Accumulator.trace(acc) end,
                 task_supervisor: Rho.TaskSupervisor
               )

      Enum.each(result.completed, fn trace ->
        assert length(trace) == 10
      end)
    end

    test "aggregate is nil when no :aggregate function provided" do
      assert {:ok, result} =
               Runner.run_many(
                 domain: Rho.Sim.Test.CounterDomain,
                 domain_opts: [start: 0],
                 policies: %{},
                 runs: 3,
                 max_steps: 100,
                 base_seed: 42,
                 reduce: fn {run, _acc} -> run.domain_state.count end,
                 task_supervisor: Rho.TaskSupervisor
               )

      assert result.aggregate == nil
    end
  end
end
