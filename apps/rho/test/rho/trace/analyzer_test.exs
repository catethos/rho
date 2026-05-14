defmodule Rho.Trace.AnalyzerTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store}

  setup do
    tape = "trace_analyzer_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.clear(tape) end)
    %{tape: tape}
  end

  test "detects tool pair and repeated-call findings", %{tape: tape} do
    Service.append(tape, :tool_result, %{
      "name" => "bash",
      "status" => "ok",
      "output" => "orphan",
      "call_id" => "missing"
    })

    for id <- ["a", "b", "c"] do
      Service.append(tape, :tool_call, %{"name" => "fs_read", "args" => %{}, "call_id" => id})
    end

    findings = Rho.Trace.Analyzer.analyze(tape)
    codes = Enum.map(findings, & &1.code)
    assert :orphan_tool_result in codes
    assert :tool_call_without_result in codes
    assert :repeated_tool_call in codes
  end

  test "detects max steps, parse loop, missing response, untyped tool error, and high cost", %{
    tape: tape
  } do
    Service.append(tape, :message, %{"role" => "user", "content" => "hi"})
    Service.append(tape, :event, %{"name" => "error", "reason" => "max steps exceeded"})
    Service.append(tape, :event, %{"name" => "parse_error", "reason" => "parse failed"})
    Service.append(tape, :event, %{"name" => "parse_error", "reason" => "parse failed again"})

    Service.append(tape, :tool_result, %{"name" => "bash", "status" => "error", "output" => "bad"})

    Service.append(tape, :event, %{
      "name" => "llm_usage",
      "total_tokens" => 10,
      "total_cost" => 2.5
    })

    codes = tape |> Rho.Trace.Analyzer.analyze() |> Enum.map(& &1.code)
    assert :max_steps_exceeded in codes
    assert :parse_error_loop in codes
    assert :missing_final_assistant_message in codes
    assert :tool_error_without_type in codes
    assert :high_cost_turn in codes
  end
end
