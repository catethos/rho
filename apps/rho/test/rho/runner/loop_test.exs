defmodule Rho.Runner.LoopTest do
  use ExUnit.Case, async: true

  alias Rho.Runner.{Loop, RuntimeBuilder}

  defmodule RespondStrategy do
    @behaviour Rho.TurnStrategy

    @impl true
    def prompt_sections(_tool_defs, _context), do: []

    @impl true
    def run(%{step: 1}, _runtime), do: {:respond, "loop ok"}

    @impl true
    def build_tool_step(_tool_calls, _results, _response_text) do
      %{type: :tool_step, assistant_msg: nil, tool_results: [], tool_calls: []}
    end
  end

  test "normal loop runs prompt_out, strategy dispatch, and emits step events" do
    test_pid = self()

    runtime =
      Rho.RunSpec.build(
        model: "mock:test",
        turn_strategy: RespondStrategy,
        tools: [],
        plugins: [],
        emit: fn event -> send(test_pid, {:event, event}) end
      )
      |> RuntimeBuilder.from_spec()

    context = [Rho.Runner.build_system_message(runtime), ReqLLM.Context.user("go")]

    assert Loop.run(context, runtime, 3) == {:ok, "loop ok"}

    assert_receive {:event, %{type: :step_start, step: 1, max_steps: 3}}
    assert_receive {:event, %{type: :before_llm, projection: %{step: 1}}}
  end

  test "normal loop enforces max steps before strategy dispatch" do
    runtime =
      Rho.RunSpec.build(
        model: "mock:test",
        turn_strategy: RespondStrategy,
        tools: [],
        plugins: []
      )
      |> RuntimeBuilder.from_spec()

    context = [Rho.Runner.build_system_message(runtime), ReqLLM.Context.user("go")]

    assert Loop.run(context, runtime, 0) == {:error, "max steps exceeded (0)"}
  end
end
