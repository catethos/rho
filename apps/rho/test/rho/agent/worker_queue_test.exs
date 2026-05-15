defmodule Rho.Agent.WorkerQueueTest do
  use ExUnit.Case, async: true

  alias Rho.Agent.Worker

  defmodule SlowThenFastStrategy do
    @behaviour Rho.TurnStrategy

    @impl true
    def prompt_sections(_tool_defs, _context), do: []

    @impl true
    def run(_projection, _runtime) do
      Process.sleep(80)
      {:respond, "done"}
    end

    @impl true
    def build_tool_step(_tool_calls, _results, _response_text) do
      %{type: :tool_step, assistant_msg: nil, tool_results: [], tool_calls: []}
    end
  end

  test "queued submit result uses the turn id returned to the caller" do
    session_id = "worker_queue_#{System.unique_integer([:positive])}"
    agent_id = "#{session_id}/primary"

    run_spec =
      Rho.RunSpec.build(
        model: "mock:test",
        turn_strategy: SlowThenFastStrategy,
        tape_module: Rho.Tape.Projection.JSONL,
        plugins: []
      )

    {:ok, pid} =
      Worker.start_link(
        agent_id: agent_id,
        session_id: session_id,
        run_spec: run_spec,
        tape_ref: "worker_queue_tape_#{session_id}"
      )

    Rho.Events.subscribe(session_id)

    assert {:ok, _first_turn_id} = Worker.submit(pid, "slow")
    assert {:ok, queued_turn_id} = Worker.submit(pid, "queued")

    assert_receive %Rho.Events.Event{
                     kind: :turn_finished,
                     data: %{turn_id: ^queued_turn_id, result: {:ok, "done"}}
                   },
                   1_000

    Rho.Events.unsubscribe(session_id)
    GenServer.stop(pid)
  end
end
