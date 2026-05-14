defmodule Rho.RunnerMetadataTest do
  use ExUnit.Case
  use Mimic

  alias Rho.Tape.{Service, Store}

  setup :verify_on_exit!

  setup do
    tape = "runner_metadata_#{System.unique_integer([:positive])}"
    Service.ensure_bootstrap_anchor(tape)
    on_exit(fn -> Store.clear(tape) end)
    %{tape: tape}
  end

  test "records conversation and thread metadata on tape entries", %{tape: tape} do
    response = %ReqLLM.Response{
      id: "resp_meta",
      model: "mock",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("hello")],
        tool_calls: nil
      },
      usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, total_cost: 0.0}
    }

    stub(ReqLLM, :stream_text, fn _model, _ctx, _opts -> {:ok, :stream} end)
    stub(ReqLLM.StreamResponse, :process_stream, fn :stream, _opts -> {:ok, response} end)

    spec =
      Rho.RunSpec.build(
        model: "mock:model",
        tape_name: tape,
        session_id: "sid_meta",
        agent_id: "sid_meta/primary",
        conversation_id: "conv_meta",
        thread_id: "thread_meta",
        turn_id: "turn_meta",
        max_steps: 1
      )

    assert {:ok, "hello"} = Rho.Runner.run([ReqLLM.Context.user("hi")], spec)

    entries = Store.read(tape)
    message = Enum.find(entries, &(&1.kind == :message and &1.payload["role"] == "user"))
    usage = Enum.find(entries, &(&1.kind == :event and &1.payload["name"] == "llm_usage"))

    for entry <- [message, usage] do
      assert entry.meta["conversation_id"] == "conv_meta"
      assert entry.meta["thread_id"] == "thread_meta"
      assert entry.meta["session_id"] == "sid_meta"
      assert entry.meta["agent_id"] == "sid_meta/primary"
      assert entry.meta["turn_id"] == "turn_meta"
    end

    assert usage.meta["step"] == 1
  end
end
