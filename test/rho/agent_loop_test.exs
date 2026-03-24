defmodule Rho.AgentLoopTest do
  use ExUnit.Case
  use Mimic

  alias Rho.Tape.{Service, Store}
  alias Rho.MountRegistry

  @test_tape "test_agent_loop_#{System.os_time(:nanosecond)}"

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
    # stream_text returns a fake StreamResponse; process_stream returns the canned response
    stub(ReqLLM, :stream_text, fn _model, _ctx, _opts ->
      {:ok, :fake_stream_response}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn :fake_stream_response, _opts ->
      {:ok, response}
    end)
  end

  defp expect_stream_sequence(responses) do
    # Return responses in order across successive calls
    pid = self()
    ref = make_ref()

    # Use an agent to track call index
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    expect(ReqLLM, :stream_text, length(responses), fn _model, _ctx, _opts ->
      send(pid, {ref, :stream_text_called})
      {:ok, {:fake_stream, Agent.get(counter, & &1)}}
    end)

    expect(ReqLLM.StreamResponse, :process_stream, length(responses), fn {:fake_stream, _idx}, _opts ->
      i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
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
               Rho.AgentLoop.run("mock:model", messages,
                 on_event: fn _event -> :ok end,
                 max_steps: 5
               )
    end
  end

  # -- Test: multi-turn tool call → tool result → final response --

  describe "multi-turn tool call loop" do
    test "executes tool, feeds result back, then returns final text" do
      tool_resp = tool_call_response("Let me check.", [{"call_1", "echo", %{"msg" => "ping"}}])
      final_resp = text_response("The echo returned: pong")

      {_ref, _counter} = expect_stream_sequence([tool_resp, final_resp])

      echo_tool = %{
        tool: ReqLLM.tool(
          name: "echo",
          description: "Echoes a message",
          parameter_schema: [msg: [type: :string, required: true, doc: "Message"]],
          callback: fn _args -> :ok end
        ),
        execute: fn %{"msg" => msg} -> {:ok, "echoed: #{msg}"} end
      }

      events = collect_events(fn on_event ->
        assert {:ok, "The echo returned: pong"} =
                 Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("echo ping")],
                   tools: [echo_tool],
                   on_event: on_event,
                   max_steps: 5
                 )
      end)

      # Verify tool_start and tool_result events were emitted
      assert Enum.any?(events, &match?(%{type: :tool_start, name: "echo"}, &1))
      assert Enum.any?(events, &match?(%{type: :tool_result, name: "echo", status: :ok}, &1))
    end
  end

  # -- Test: auto-compaction triggers when token threshold is exceeded --

  describe "auto-compaction" do
    test "triggers compaction when tape tokens exceed threshold" do
      Service.ensure_bootstrap_anchor(@test_tape)

      # Stuff tape with enough content to exceed a low threshold (50 tokens = 200 chars)
      Service.append(@test_tape, :message, %{
        "role" => "user",
        "content" => String.duplicate("x", 800)
      })

      Service.append(@test_tape, :message, %{
        "role" => "assistant",
        "content" => String.duplicate("y", 800)
      })

      # Mock generate_text for compaction summarization
      expect(ReqLLM, :generate_text, fn _model, _messages, _opts ->
        {:ok, text_response("Summary of conversation.")}
      end)

      # The loop itself: single-turn text response
      stub_stream_returning(text_response("Done after compaction."))

      events = collect_events(fn on_event ->
        assert {:ok, "Done after compaction."} =
                 Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("continue")],
                   tape_name: @test_tape,
                   on_event: on_event,
                   max_steps: 5,
                   compact_threshold: 50
                 )
      end)

      assert Enum.any?(events, &match?(%{type: :compact}, &1))
    end
  end

  # -- Test: loop stops when create_anchor tool is called --

  describe "create_anchor stops the loop" do
    test "loop exits immediately after create_anchor is invoked" do
      Service.ensure_bootstrap_anchor(@test_tape)

      anchor_tool = Rho.Tools.Anchor.tool_def(@test_tape)

      tool_resp =
        tool_call_response("Saving progress.", [
          {"call_anchor", "create_anchor", %{"name" => "phase1", "summary" => "Did stuff"}}
        ])

      # Only one LLM call — the loop must NOT make a second call
      {_ref, _counter} = expect_stream_sequence([tool_resp])

      events = collect_events(fn on_event ->
        assert {:ok, "Saving progress."} =
                 Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("wrap up")],
                   tape_name: @test_tape,
                   tools: [anchor_tool],
                   on_event: on_event,
                   max_steps: 10
                 )
      end)

      # Verify the anchor tool was started
      assert Enum.any?(events, &match?(%{type: :tool_start, name: "create_anchor"}, &1))
      assert Enum.any?(events, &match?(%{type: :tool_result, name: "create_anchor", status: :ok}, &1))

      # Verify only one step_start (loop did not continue)
      step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
      assert length(step_starts) == 1
    end
  end

  # -- Lifecycle hooks through AgentLoop --

  describe "lifecycle: before_tool deny" do
    setup do
      MountRegistry.clear()
      on_exit(fn -> MountRegistry.clear() end)
      :ok
    end

    test "denied tool call returns denial message as tool result" do
      MountRegistry.register(__MODULE__.DenyMount)

      tool_resp = tool_call_response("Calling it.", [{"call_1", "dangerous", %{}}])
      final_resp = text_response("Got denied")

      {_ref, _counter} = expect_stream_sequence([tool_resp, final_resp])

      dangerous_tool = %{
        tool: ReqLLM.tool(
          name: "dangerous",
          description: "A dangerous tool",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
        execute: fn _args -> {:ok, "should not run"} end
      }

      events = collect_events(fn on_event ->
        assert {:ok, "Got denied"} =
                 Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("do something dangerous")],
                   tools: [dangerous_tool],
                   emit: on_event,
                   max_steps: 5,
                   agent_name: :default
                 )
      end)

      denied = Enum.find(events, &match?(%{type: :tool_result, name: "dangerous", status: :error}, &1))
      assert denied.output =~ "Denied"
    end
  end

  describe "lifecycle: after_tool replace" do
    setup do
      MountRegistry.clear()
      on_exit(fn -> MountRegistry.clear() end)
      :ok
    end

    test "mount can replace tool output" do
      MountRegistry.register(__MODULE__.FilterMount)

      tool_resp = tool_call_response("Running.", [{"call_1", "bash", %{"cmd" => "ls"}}])
      final_resp = text_response("Filtered result received")

      {_ref, _counter} = expect_stream_sequence([tool_resp, final_resp])

      bash_tool = %{
        tool: ReqLLM.tool(
          name: "bash",
          description: "Run a command",
          parameter_schema: [cmd: [type: :string, required: true, doc: "Command"]],
          callback: fn _args -> :ok end
        ),
        execute: fn _args -> {:ok, "raw output"} end
      }

      events = collect_events(fn on_event ->
        assert {:ok, "Filtered result received"} =
                 Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("run ls")],
                   tools: [bash_tool],
                   emit: on_event,
                   max_steps: 5,
                   agent_name: :default
                 )
      end)

      result_event = Enum.find(events, &match?(%{type: :tool_result, name: "bash", status: :ok}, &1))
      assert result_event.output =~ "[filtered]"
    end
  end

  describe "lifecycle: after_step inject" do
    setup do
      MountRegistry.clear()
      on_exit(fn -> MountRegistry.clear() end)
      :ok
    end

    test "injected messages appear in context for next LLM call" do
      MountRegistry.register(__MODULE__.InjectMount)

      tool_resp = tool_call_response("Working.", [{"call_1", "echo", %{"msg" => "hi"}}])
      final_resp = text_response("Done with injection")

      echo_tool = %{
        tool: ReqLLM.tool(
          name: "echo",
          description: "Echo",
          parameter_schema: [msg: [type: :string, required: true, doc: "Msg"]],
          callback: fn _args -> :ok end
        ),
        execute: fn %{"msg" => msg} -> {:ok, "echoed: #{msg}"} end
      }

      # Capture the context sent to the second LLM call
      pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      expect(ReqLLM, :stream_text, 2, fn _model, ctx, _opts ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if i == 1, do: send(pid, {:second_call_context, ctx})
        {:ok, {:fake_stream, i}}
      end)

      expect(ReqLLM.StreamResponse, :process_stream, 2, fn {:fake_stream, idx}, _opts ->
        {:ok, Enum.at([tool_resp, final_resp], idx)}
      end)

      assert {:ok, "Done with injection"} =
               Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("echo hi")],
                 tools: [echo_tool],
                 emit: fn _event -> :ok end,
                 max_steps: 5,
                 agent_name: :default
               )

      assert_received {:second_call_context, context}
      last_msg = List.last(context)
      assert last_msg.role == :user
      assert extract_msg_text(last_msg.content) =~ "Reminder from InjectMount"
    end
  end

  describe "lifecycle: before_llm modifies projection" do
    setup do
      MountRegistry.clear()
      on_exit(fn -> MountRegistry.clear() end)
      :ok
    end

    test "before_llm hook can modify the context sent to the LLM" do
      MountRegistry.register(__MODULE__.BeforeLlmMount)

      stub_stream_returning(text_response("Got it"))

      pid = self()

      expect(ReqLLM, :stream_text, fn _model, ctx, _opts ->
        send(pid, {:llm_context, ctx})
        {:ok, :fake_stream_response}
      end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :fake_stream_response, _opts ->
        {:ok, text_response("Got it")}
      end)

      assert {:ok, "Got it"} =
               Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("hello")],
                 emit: fn _event -> :ok end,
                 max_steps: 5,
                 agent_name: :default
               )

      assert_received {:llm_context, context}
      # The mount adds an extra user message
      texts = Enum.flat_map(context, fn msg ->
        case msg do
          %{role: :user, content: content} -> [extract_msg_text(content)]
          _ -> []
        end
      end)
      assert Enum.any?(texts, &(&1 =~ "injected_by_before_llm"))
    end
  end

  describe "lifecycle: subagent skips mount hooks" do
    setup do
      MountRegistry.clear()
      on_exit(fn -> MountRegistry.clear() end)
      :ok
    end

    test "subagent mode does not run before_llm or after_step hooks" do
      MountRegistry.register(__MODULE__.InjectMount)
      MountRegistry.register(__MODULE__.BeforeLlmMount)

      stub_stream_returning(text_response("subagent done"))

      pid = self()

      expect(ReqLLM, :stream_text, fn _model, ctx, _opts ->
        send(pid, {:subagent_context, ctx})
        {:ok, :fake_stream_response}
      end)

      stub(ReqLLM.StreamResponse, :process_stream, fn :fake_stream_response, _opts ->
        {:ok, text_response("subagent done")}
      end)

      # subagent text-only response triggers :subagent_nudge, but with only 1 max_step
      # it will hit max_steps on the next iteration
      assert {:error, "max steps exceeded (1)"} =
               Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("hello")],
                 emit: fn _event -> :ok end,
                 max_steps: 1,
                 subagent: true,
                 agent_name: :default
               )

      assert_received {:subagent_context, context}
      # before_llm should NOT have injected anything
      texts = Enum.flat_map(context, fn msg ->
        case msg do
          %{role: :user, content: content} -> [extract_msg_text(content)]
          _ -> []
        end
      end)
      refute Enum.any?(texts, &(&1 =~ "injected_by_before_llm"))
    end
  end

  describe "lifecycle: compaction error surfaces" do
    test "compaction failure returns error instead of silently continuing" do
      stub_stream_returning(text_response("Should not reach here"))

      result = Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("continue")],
        tape_name: "test_compact_error",
        memory_mod: __MODULE__.FailingCompactMem,
        emit: fn _event -> :ok end,
        max_steps: 5,
        compact_threshold: 50
      )

      assert {:error, {:compact_failed, :compaction_broken}} = result
    end
  end

  describe "lifecycle: Lifecycle.noop" do
    test "noop lifecycle allows agent to run without mounts" do
      MountRegistry.clear()

      stub_stream_returning(text_response("No mounts here"))

      assert {:ok, "No mounts here"} =
               Rho.AgentLoop.run("mock:model", [ReqLLM.Context.user("hi")],
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

  # -- Test mount modules for lifecycle hooks --

  defmodule DenyMount do
    @behaviour Rho.Mount

    @impl true
    def before_tool(%{name: "dangerous"}, _opts, _ctx), do: {:deny, "Not allowed"}
    def before_tool(_call, _opts, _ctx), do: :ok
  end

  defmodule FilterMount do
    @behaviour Rho.Mount

    @impl true
    def after_tool(%{name: "bash"}, result, _opts, _ctx), do: {:replace, "[filtered] " <> result}
    def after_tool(_call, result, _opts, _ctx), do: {:ok, result}
  end

  defmodule InjectMount do
    @behaviour Rho.Mount

    @impl true
    def after_step(_step, _max, _opts, _ctx), do: {:inject, "Reminder from InjectMount"}
  end

  defmodule BeforeLlmMount do
    @behaviour Rho.Mount

    @impl true
    def before_llm(projection, _opts, _ctx) do
      injected_msg = ReqLLM.Context.user("injected_by_before_llm")
      {:replace, %{projection | context: projection.context ++ [injected_msg]}}
    end
  end

  # -- Helpers --

  defp extract_msg_text(content) when is_binary(content), do: content
  defp extract_msg_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
  end
  defp extract_msg_text(other), do: inspect(other)

  # -- Event collection helper --

  defp collect_events(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    on_event = fn event ->
      Agent.update(agent, fn events -> [event | events] end)
      :ok
    end

    fun.(on_event)

    events = Agent.get(agent, &Enum.reverse/1)
    Agent.stop(agent)
    events
  end
end
