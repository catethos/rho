defmodule Rho.Agent.TurnTaskTest do
  use ExUnit.Case, async: true

  alias Rho.Agent.Registry, as: AgentRegistry
  alias Rho.Agent.TurnTask
  alias Rho.Agent.Worker

  setup do
    AgentRegistry.init_table()
    :ok
  end

  describe "start/5" do
    test "starts a supervised task and records busy bookkeeping" do
      parent = self()
      session_id = "turn_task_session_#{System.unique_integer([:positive])}"
      agent_id = "#{session_id}/primary"

      AgentRegistry.register(agent_id, %{
        session_id: session_id,
        role: :primary,
        agent_name: :default,
        capabilities: [],
        pid: self(),
        status: :idle
      })

      Rho.Events.subscribe(session_id)

      state = %Worker{agent_id: agent_id, session_id: session_id, status: :idle}

      started =
        TurnTask.start(state, "turn-1", "task-1", [:echo], fn ->
          send(parent, :task_ran)
          {:ok, "done"}
        end)

      assert started.status == :busy
      assert started.current_turn_id == "turn-1"
      assert started.current_task_id == "task-1"
      assert started.persistent_tools == [:echo]
      assert is_reference(started.task_ref)
      assert is_pid(started.task_pid)
      assert is_integer(started.last_activity_at)

      assert_receive :task_ran
      assert_receive {ref, {:ok, "done"}}
      assert ref == started.task_ref
      Process.demonitor(started.task_ref, [:flush])

      assert_receive %Rho.Events.Event{
        kind: :task_accepted,
        data: %{task_id: "task-1"}
      }

      assert [%{status: :busy}] = AgentRegistry.list(session_id)
      Rho.Events.unsubscribe(session_id)
      AgentRegistry.unregister(agent_id)
    end
  end

  describe "cancel/1" do
    test "shuts down the task process and marks state cancelling" do
      task_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = Process.monitor(task_pid)

      state = %Worker{status: :busy, task_pid: task_pid}
      cancelled = TurnTask.cancel(state)

      assert cancelled.status == :cancelling
      assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid, :shutdown}
    end
  end

  describe "handle_watchdog/2" do
    test "kills inactive busy task processes" do
      task_pid = spawn(fn -> Process.sleep(:infinity) end)
      monitor_ref = Process.monitor(task_pid)

      state = %Worker{
        status: :busy,
        task_pid: task_pid,
        last_activity_at: System.monotonic_time(:millisecond) - 10
      }

      assert TurnTask.handle_watchdog(state, inactivity_limit: 1) == state
      assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid, :turn_inactive}
    end

    test "keeps inactive messages harmless when worker is idle" do
      state = %Worker{status: :idle}
      assert TurnTask.handle_watchdog(state, inactivity_limit: 1) == state
    end
  end
end
