defmodule Rho.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Rho.ToolExecutor

  defp tool_with(execute_fn) do
    %{
      tool:
        ReqLLM.tool(
          name: "stub",
          description: "Stub tool for typed-error tests.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: execute_fn
    }
  end

  defp run_tool(execute_fn) do
    tool_map = %{"stub" => tool_with(execute_fn)}
    test_pid = self()
    emit = fn event -> send(test_pid, {:event, event}) end

    [result] =
      ToolExecutor.run(
        [%{name: "stub", args: %{}, call_id: "call_1"}],
        tool_map,
        %Rho.Context{agent_name: :test},
        emit
      )

    result
  end

  describe "typed error passthrough" do
    test "atom error becomes error_type without classification" do
      result = run_tool(fn _args, _ctx -> {:error, :rate_limited} end)

      assert result.status == :error
      assert result.event.error_type == :rate_limited
      assert result.result == "Error: rate_limited"
    end

    test "{atom, message} error uses atom as error_type and message as output" do
      result =
        run_tool(fn _args, _ctx ->
          {:error, {:not_found, "Cannot read foo.txt: enoent"}}
        end)

      assert result.status == :error
      assert result.event.error_type == :not_found
      assert result.result =~ "Cannot read foo.txt"
    end

    test "binary error falls back to legacy classify_tool_error" do
      # Capture the deprecation warning to keep test output clean.
      ExUnit.CaptureLog.capture_log(fn ->
        result = run_tool(fn _args, _ctx -> {:error, "operation timeout"} end)
        send(self(), {:legacy_result, result})
      end)

      assert_received {:legacy_result, result}
      assert result.status == :error
      assert result.event.error_type == :timeout
    end
  end
end
