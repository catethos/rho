defmodule Rho.Trace.ProjectionTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store}

  setup do
    tape = "trace_projection_#{System.unique_integer([:positive])}"

    on_exit(fn -> Store.clear(tape) end)
    %{tape: tape}
  end

  test "chat projection handles messages and tool entries", %{tape: tape} do
    {:ok, user} = Service.append(tape, :message, %{"role" => "user", "content" => "hi"})

    Service.append(tape, :tool_call, %{
      "name" => "fs_read",
      "args" => %{"path" => "README.md"},
      "call_id" => "call_1"
    })

    Service.append(tape, :tool_result, %{
      "name" => "fs_read",
      "output" => "ok",
      "status" => "ok",
      "call_id" => "call_1"
    })

    [msg, call, result] = Rho.Trace.Projection.chat(tape)
    assert msg.tape_entry_id == user.id
    assert msg.role == :user
    assert call.type == :tool_call
    assert result.output == "ok"
  end

  test "chat projection renders typed structured tool steps as tool rows", %{tape: tape} do
    Service.append(tape, :message, %{"role" => "user", "content" => "extract this"})

    {:ok, action} =
      Service.append(tape, :message, %{
        "role" => "assistant",
        "content" => ~s({"args":{"upload_id":"upl_123"},"tool":"extract_role_from_jd"})
      })

    Service.append(tape, :message, %{
      "role" => "user",
      "content" => "[Tool Result: extract_role_from_jd]\nExtracted 12 skill(s)."
    })

    [_user, tool] = Rho.Trace.Projection.chat(tape)
    assert tool.tape_entry_id == action.id
    assert tool.role == :assistant
    assert tool.type == :tool_call
    assert tool.name == "extract_role_from_jd"
    assert tool.args == %{"upload_id" => "upl_123"}
    assert tool.status == :ok
    assert tool.output == "Extracted 12 skill(s)."
  end

  test "chat projection hides typed structured think bookkeeping", %{tape: tape} do
    Service.append(tape, :message, %{
      "role" => "assistant",
      "content" => ~s({"tool":"think","thought":"I should inspect the table."})
    })

    Service.append(tape, :message, %{
      "role" => "user",
      "content" => "[System] Thought noted. Continue with your next action."
    })

    assert Rho.Trace.Projection.chat(tape) == []
  end

  test "context projection matches canonical JSONL projection", %{tape: tape} do
    Service.append(tape, :message, %{"role" => "user", "content" => "hello"})

    assert Rho.Trace.Projection.context(tape) == Rho.Tape.Projection.JSONL.build_context(tape)
  end

  test "debug projection is chronological and old tapes without metadata project", %{tape: tape} do
    Service.append(tape, :message, %{"role" => "user", "content" => "hello"})
    Service.append(tape, :event, %{"name" => "error", "reason" => "boom"})

    [first, second] = Rho.Trace.Projection.debug(tape)
    assert first.id < second.id
    assert first.meta == %{}
    assert second.kind == :event
  end

  test "cost projection aggregates llm_usage events", %{tape: tape} do
    Service.append(tape, :event, %{
      "name" => "llm_usage",
      "input_tokens" => 10,
      "output_tokens" => 5,
      "total_tokens" => 15,
      "total_cost" => 0.01
    })

    costs = Rho.Trace.Projection.costs(tape)
    assert costs.totals.input_tokens == 10
    assert costs.totals.total_cost == 0.01
  end
end
