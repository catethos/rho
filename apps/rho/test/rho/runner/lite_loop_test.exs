defmodule Rho.Runner.LiteLoopTest do
  use ExUnit.Case, async: true

  defmodule ThinkForeverStrategy do
    @behaviour Rho.TurnStrategy

    @impl true
    def prompt_sections(_tool_defs, _context), do: []

    @impl true
    def run(_projection, _runtime), do: {:think, "still thinking"}

    @impl true
    def build_tool_step(_tool_calls, _results, _response_text) do
      %{type: :tool_step, assistant_msg: nil, tool_results: [], tool_calls: []}
    end
  end

  defmodule ErrorStrategy do
    @behaviour Rho.TurnStrategy

    @impl true
    def prompt_sections(_tool_defs, _context), do: []

    @impl true
    def run(_projection, _runtime), do: {:error, :boom}

    @impl true
    def build_tool_step(_tool_calls, _results, _response_text) do
      %{type: :tool_step, assistant_msg: nil, tool_results: [], tool_calls: []}
    end
  end

  test "lite loop enforces max steps without tape or transformer work" do
    test_pid = self()

    spec =
      Rho.RunSpec.build(
        model: "mock:test",
        turn_strategy: ThinkForeverStrategy,
        tools: [],
        plugins: [],
        max_steps: 2,
        emit: fn event -> send(test_pid, {:event, event}) end,
        lite: true
      )

    assert Rho.Runner.run([ReqLLM.Context.user("go")], spec) ==
             {:error, "max steps exceeded (2)"}

    assert_receive {:event, %{type: :step_start, step: 1, max_steps: 2}}
    assert_receive {:event, %{type: :step_start, step: 2, max_steps: 2}}
  end

  test "lite loop emits errors from the turn strategy" do
    test_pid = self()

    spec =
      Rho.RunSpec.build(
        model: "mock:test",
        turn_strategy: ErrorStrategy,
        tools: [],
        plugins: [],
        max_steps: 2,
        emit: fn event -> send(test_pid, {:event, event}) end,
        lite: true
      )

    assert Rho.Runner.run([ReqLLM.Context.user("go")], spec) ==
             {:error, "LLM call failed: :boom"}

    assert_receive {:event, %{type: :error, reason: :boom}}
  end
end
