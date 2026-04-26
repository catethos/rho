defmodule Rho.RunnerTest do
  use ExUnit.Case
  use Mimic

  alias Rho.Tape.{Service, Store}

  @test_tape "test_runner_#{System.os_time(:nanosecond)}"

  setup :verify_on_exit!

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  # -- Helpers to build canned ReqLLM responses --

  defp text_response(text) do
    %ReqLLM.Response{
      id: "resp_#{System.unique_integer([:positive])}",
      model: "mock",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text)],
        tool_calls: nil
      },
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  defp tool_call_response(text, tool_calls) do
    tc_structs =
      Enum.map(tool_calls, fn {id, name, args} ->
        ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
      end)

    %ReqLLM.Response{
      id: "resp_#{System.unique_integer([:positive])}",
      model: "mock",
      context: %ReqLLM.Context{messages: []},
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text)],
        tool_calls: tc_structs
      },
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  defp stub_stream_returning(response) do
    stub(ReqLLM, :stream_text, fn _model, _ctx, _opts ->
      {:ok, :fake_stream_response}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn :fake_stream_response, _opts ->
      {:ok, response}
    end)
  end

  defp expect_stream_sequence(responses) do
    pid = self()
    ref = make_ref()
    counter = :counters.new(1, [:atomics])

    expect(ReqLLM, :stream_text, length(responses), fn _model, _ctx, _opts ->
      send(pid, {ref, :stream_text_called})
      {:ok, {:fake_stream, :counters.get(counter, 1)}}
    end)

    expect(ReqLLM.StreamResponse, :process_stream, length(responses), fn {:fake_stream, _idx},
                                                                         _opts ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, Enum.at(responses, i)}
    end)

    {ref, counter}
  end

  # -- Test: single-turn text response --

  describe "single-turn text response" do
    test "returns text when LLM responds without tool calls" do
      stub_stream_returning(text_response("Hello, world!"))

      messages = [ReqLLM.Context.user("Hi")]

      assert {:ok, "Hello, world!"} =
               Rho.Runner.run("mock:model", messages,
                 on_event: fn _event -> :ok end,
                 max_steps: 5
               )
    end
  end

  # -- Test: multi-turn tool call -> tool result -> final response --

  describe "multi-turn tool call loop" do
    test "executes tool, feeds result back, then returns final text" do
      tool_resp = tool_call_response("Let me check.", [{"call_1", "echo", %{"msg" => "ping"}}])
      final_resp = text_response("The echo returned: pong")

      {_ref, _counter} = expect_stream_sequence([tool_resp, final_resp])

      echo_tool = %{
        tool:
          ReqLLM.tool(
            name: "echo",
            description: "Echoes a message",
            parameter_schema: [msg: [type: :string, required: true, doc: "Message"]],
            callback: fn _args -> :ok end
          ),
        execute: fn %{msg: msg}, _ctx -> {:ok, "echoed: #{msg}"} end
      }

      events =
        collect_events(fn on_event ->
          assert {:ok, "The echo returned: pong"} =
                   Rho.Runner.run("mock:model", [ReqLLM.Context.user("echo ping")],
                     tools: [echo_tool],
                     on_event: on_event,
                     max_steps: 5
                   )
        end)

      assert Enum.any?(events, &match?(%{type: :tool_start, name: "echo"}, &1))
      assert Enum.any?(events, &match?(%{type: :tool_result, name: "echo", status: :ok}, &1))
    end
  end

  # -- Test: auto-compaction triggers when token threshold is exceeded --

  describe "auto-compaction" do
    test "triggers compaction when tape tokens exceed threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)

      Service.append(@test_tape, :message, %{
        "role" => "user",
        "content" => String.duplicate("x", 800)
      })

      Service.append(@test_tape, :message, %{
        "role" => "assistant",
        "content" => String.duplicate("y", 800)
      })

      expect(ReqLLM, :generate_text, fn _model, _messages, _opts ->
        {:ok, text_response("Summary of conversation.")}
      end)

      stub_stream_returning(text_response("Done after compaction."))

      events =
        collect_events(fn on_event ->
          assert {:ok, "Done after compaction."} =
                   Rho.Runner.run("mock:model", [ReqLLM.Context.user("continue")],
                     tape_name: @test_tape,
                     on_event: on_event,
                     max_steps: 5,
                     compact_threshold: 50
                   )
        end)

      assert Enum.any?(events, &match?(%{type: :compact}, &1))
    end
  end

  # -- Test: terminal tools stop the loop --
  #
  # Characterisation tests for the four built-in tools that historically
  # ended the loop. Each stub returns `{:final, _}` (the disposition shape)
  # so the test passes both with and without the legacy `@terminal_tools`
  # name list. Asserts only termination + status, not the exact return
  # text — the two paths produce different text values for non-`finish`
  # tools.

  describe "terminal tools stop the loop" do
    for tool_name <- ["finish", "end_turn", "create_anchor", "clear_memory"] do
      test "#{tool_name} terminates after a single step" do
        Service.ensure_bootstrap_anchor(@test_tape)
        name = unquote(tool_name)

        tool = %{
          tool:
            ReqLLM.tool(
              name: name,
              description: "Stub terminal tool.",
              parameter_schema: [],
              callback: fn _args -> :ok end
            ),
          execute: fn _args, _ctx -> {:final, "#{name} stub-result"} end
        }

        tool_resp =
          tool_call_response("Wrapping up.", [{"call_#{name}", name, %{}}])

        {_ref, _counter} = expect_stream_sequence([tool_resp])

        events =
          collect_events(fn on_event ->
            assert {:ok, _text} =
                     Rho.Runner.run("mock:model", [ReqLLM.Context.user("done")],
                       tape_name: @test_tape,
                       tools: [tool],
                       on_event: on_event,
                       max_steps: 10
                     )
          end)

        assert Enum.any?(events, &match?(%{type: :tool_start, name: ^name}, &1))

        assert Enum.any?(
                 events,
                 &match?(%{type: :tool_result, name: ^name, status: :ok}, &1)
               )

        step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
        assert length(step_starts) == 1
      end
    end
  end

  describe "subagent nudge via :post_step transformer" do
    # Test transformer scoped to :test_nudge agent_name to avoid leaking
    # into other tests. Mirrors what Rho.Stdlib.Transformers.SubagentNudge
    # does, but lives here so apps/rho stays self-contained.
    defmodule TestNudge do
      @behaviour Rho.Transformer

      @impl Rho.Transformer
      def transform(:post_step, %{step_kind: :text_response}, %{depth: depth})
          when depth > 0 do
        {:inject, ["[System] keep going, call finish when done"]}
      end

      def transform(_stage, data, _context), do: {:cont, data}
    end

    setup do
      Rho.TransformerRegistry.register(TestNudge, scope: {:agent, :test_nudge})
      :ok
    end

    test "depth > 0 + nudge registered → text response loops" do
      # First call: text response → nudge fires → loop continues.
      # Second call: text response again → nudge fires → step 3 → max_steps exceeded.
      expect_stream_sequence([
        text_response("first reply"),
        text_response("second reply")
      ])

      result =
        Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
          on_event: fn _event -> :ok end,
          max_steps: 2,
          depth: 1,
          agent_name: :test_nudge
        )

      assert {:error, "max steps exceeded (2)"} = result
    end

    test "depth > 0 + no transformer registered → text response terminates" do
      # Snapshot any global transformers (e.g. SubagentNudge from rho_stdlib),
      # clear, run, and re-register on exit. Proves the kernel itself doesn't
      # nudge — termination depends on a registered transformer.
      snapshot = :ets.tab2list(:rho_transformer_instances)
      Rho.TransformerRegistry.clear()

      on_exit(fn ->
        Rho.TransformerRegistry.clear()

        for {_priority, instance} <- snapshot do
          Rho.TransformerRegistry.register(instance.module,
            scope: instance.scope,
            opts: instance.opts
          )
        end
      end)

      stub_stream_returning(text_response("done"))

      assert {:ok, "done"} =
               Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
                 on_event: fn _event -> :ok end,
                 max_steps: 5,
                 depth: 1,
                 agent_name: :no_transformer_agent
               )
    end

    test "depth = 0 + nudge registered → text response terminates (depth-gated)" do
      stub_stream_returning(text_response("done"))

      assert {:ok, "done"} =
               Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
                 on_event: fn _event -> :ok end,
                 max_steps: 5,
                 depth: 0,
                 agent_name: :test_nudge
               )
    end
  end

  describe "lifecycle: compaction error surfaces" do
    test "compaction failure returns error instead of silently continuing" do
      stub_stream_returning(text_response("Should not reach here"))

      result =
        Rho.Runner.run("mock:model", [ReqLLM.Context.user("continue")],
          tape_name: "test_compact_error",
          tape_module: __MODULE__.FailingCompactMem,
          emit: fn _event -> :ok end,
          max_steps: 5,
          compact_threshold: 50
        )

      assert {:error, {:compact_failed, :compaction_broken}} = result
    end
  end

  describe "lifecycle: noop lifecycle" do
    test "agent runs without plugins/transformers" do
      stub_stream_returning(text_response("No mounts here"))

      assert {:ok, "No mounts here"} =
               Rho.Runner.run("mock:model", [ReqLLM.Context.user("hi")],
                 emit: fn _event -> :ok end,
                 max_steps: 5
               )
    end
  end

  # -- Test memory module for compaction error --

  defmodule FailingCompactMem do
    def append(_tape, _type, _data), do: :ok
    def append_from_event(_tape, _event), do: :ok
    def build_context(_tape), do: []
    def compact_if_needed(_tape, _opts), do: {:error, :compaction_broken}
  end

  # -- Helpers --

  defp collect_events(fun) do
    table = :ets.new(:test_events, [:ordered_set, :public])
    counter = :counters.new(1, [:atomics])

    on_event = fn event ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      :ets.insert(table, {i, event})
      :ok
    end

    fun.(on_event)

    events = :ets.tab2list(table) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    :ets.delete(table)
    events
  end
end
