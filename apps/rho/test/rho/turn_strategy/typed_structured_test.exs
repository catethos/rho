defmodule Rho.TurnStrategy.TypedStructuredTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Rho.TurnStrategy.TypedStructured

  setup :verify_on_exit!

  # --- Test helpers ---

  defp make_tool_def(name, params) do
    make_tool_def(name, params, fn args, _ctx -> {:ok, inspect(args)} end)
  end

  defp make_tool_def(name, params, execute) do
    %{
      tool: %{
        name: name,
        description: "Test tool #{name}",
        parameter_schema: params
      },
      execute: execute
    }
  end

  defp tool_defs do
    [
      make_tool_def("bash", cmd: [type: :string, required: true, doc: "Command to run"]),
      make_tool_def("fs_read", path: [type: :string, required: true], offset: [type: :integer])
    ]
  end

  defp build_runtime(opts \\ []) do
    defs = opts[:tool_defs] || tool_defs()
    events = opts[:events] || :ets.new(:events, [:ordered_set, :public])
    counter = opts[:counter] || :counters.new(1, [:atomics])

    emit = fn event ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      :ets.insert(events, {i, event})
      :ok
    end

    %Rho.Runner.Runtime{
      model: "mock:model",
      turn_strategy: TypedStructured,
      emit: emit,
      gen_opts: [],
      tool_defs: defs,
      req_tools: Enum.map(defs, & &1.tool),
      tool_map: Map.new(defs, fn t -> {t.tool.name, t} end),
      system_prompt_stable: "You are helpful.",
      system_prompt_volatile: "",
      depth: 0,
      tape: %Rho.Runner.TapeConfig{
        name: nil,
        tape_module: Rho.Tape.Projection.JSONL,
        compact_threshold: 100_000,
        compact_supported: false
      },
      context: %Rho.Context{
        tape_name: nil,
        tape_module: Rho.Tape.Projection.JSONL,
        workspace: "/tmp",
        agent_name: :test,
        depth: 0
      }
    }
  end

  defp projection(step \\ 1) do
    %{
      context: [ReqLLM.Context.user("test")],
      tools: [],
      step: step
    }
  end

  defp stub_baml_response(result_map) when is_map(result_map) do
    stub(RhoBaml.SchemaWriter, :write!, fn _dir, _tool_defs, _opts -> :ok end)

    stub(BamlElixir.Client, :sync_stream, fn _fn_name, _args, _callback, _opts ->
      {:ok, result_map}
    end)
  end

  defp collect_events(events_table) do
    :ets.tab2list(events_table)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # --- Tests ---

  describe "run/2 — respond" do
    test "returns {:respond, text} for respond action" do
      stub_baml_response(%{tool: "respond", message: "Hello!"})

      runtime = build_runtime()

      assert {:respond, "Hello!"} = TypedStructured.run(projection(), runtime)
    end
  end

  describe "run/2 — think" do
    test "returns {:think, thought} for think action" do
      stub_baml_response(%{tool: "think", thought: "Let me reconsider..."})

      runtime = build_runtime()
      result = TypedStructured.run(projection(), runtime)

      assert {:think, "Let me reconsider..."} = result
    end
  end

  describe "run/2 — tool call" do
    test "returns {:call_tools, tool_calls, nil} for tool action" do
      stub_baml_response(%{tool: "bash", cmd: "ls -la"})

      runtime = build_runtime()
      result = TypedStructured.run(projection(), runtime)

      assert {:call_tools, [tc], nil} = result
      assert tc.name == "bash"
      assert tc.args == %{cmd: "ls -la"}
      assert is_binary(tc.call_id)
    end

    test "emits thinking side-channel on tool calls" do
      events = :ets.new(:events, [:ordered_set, :public])
      counter = :counters.new(1, [:atomics])

      stub_baml_response(%{tool: "bash", cmd: "ls", thinking: "Check directory"})

      runtime = build_runtime(events: events, counter: counter)
      assert {:call_tools, _, nil} = TypedStructured.run(projection(), runtime)

      emitted = collect_events(events)
      assert Enum.any?(emitted, &match?(%{type: :llm_text, text: "Check directory"}, &1))
    end
  end

  describe "run/2 — unknown tool" do
    test "returns {:parse_error, reason, raw_text} for unknown tool" do
      stub_baml_response(%{tool: "nonexistent", foo: "bar"})

      runtime = build_runtime()
      result = TypedStructured.run(projection(), runtime)

      assert {:parse_error, reason, _raw_text} = result
      assert reason =~ "nonexistent"
    end
  end

  describe "run/2 — parse error fallback to respond" do
    test "treats response without tool tag as respond" do
      # BAML returns a map without "tool" key — dispatch_parsed returns :parse_error,
      # which TypedStructured treats as a respond fallback
      stub_baml_response(%{message: "I'm just chatting"})

      runtime = build_runtime()
      assert {:respond, _text} = TypedStructured.run(projection(), runtime)
    end
  end

  describe "run/2 — tool returning {:final, value}" do
    test "returns {:call_tools, ...} (Runner handles :final disposition)" do
      final_tool =
        make_tool_def(
          "finish",
          [result: [type: :string, required: true]],
          fn _args, _ctx -> {:final, "All done"} end
        )

      stub_baml_response(%{tool: "finish", result: "done"})

      runtime = build_runtime(tool_defs: [final_tool])
      result = TypedStructured.run(projection(), runtime)

      assert {:call_tools, [tc], nil} = result
      assert tc.name == "finish"
    end
  end

  describe "run/2 — tool returning {:error, reason}" do
    test "returns {:call_tools, ...} (Runner handles error results)" do
      error_tool =
        make_tool_def(
          "failing",
          [input: [type: :string, required: true]],
          fn _args, _ctx -> {:error, "something broke"} end
        )

      stub_baml_response(%{tool: "failing", input: "test"})

      runtime = build_runtime(tool_defs: [error_tool])
      result = TypedStructured.run(projection(), runtime)

      assert {:call_tools, [tc], nil} = result
      assert tc.name == "failing"
    end
  end

  describe "prompt_sections/2" do
    test "returns empty list (BAML handles format injection)" do
      sections = TypedStructured.prompt_sections(tool_defs(), %{})
      assert sections == []
    end
  end

  describe "run/2 — BAML error" do
    test "returns {:error, reason} on BAML failure" do
      stub(RhoBaml.SchemaWriter, :write!, fn _dir, _tool_defs, _opts -> :ok end)

      stub(BamlElixir.Client, :sync_stream, fn _fn_name, _args, _callback, _opts ->
        {:error, "connection refused"}
      end)

      events = :ets.new(:events, [:ordered_set, :public])
      counter = :counters.new(1, [:atomics])
      runtime = build_runtime(events: events, counter: counter)

      assert {:error, _reason} = TypedStructured.run(projection(), runtime)
    end
  end

  # --- build_tool_step/3 ---

  describe "build_tool_step/3" do
    test "builds structured tool step entries" do
      tool_calls = [%{name: "bash", args: %{cmd: "echo hi"}, call_id: "tc_1"}]

      results = [
        %{
          name: "bash",
          args: %{cmd: "echo hi"},
          call_id: "tc_1",
          result: "hi",
          status: :ok,
          disposition: :normal,
          event: %{}
        }
      ]

      step = TypedStructured.build_tool_step(tool_calls, results, nil)

      assert step.type == :tool_step
      assert step.tool_calls == []
      assert [{_, _}] = step.structured_calls
    end
  end

  describe "build_think_step/1" do
    test "builds think step entries" do
      step = TypedStructured.build_think_step("Considering options...")

      assert step.type == :tool_step
      assert step.assistant_msg.content |> hd() |> Map.get(:text) =~ "think"
    end
  end

  describe "serialize_messages/2 — volatile hoisting" do
    test "hoists volatile system text to the end" do
      runtime =
        build_runtime()
        |> Map.put(:system_prompt_stable, "STABLE BODY")
        |> Map.put(:system_prompt_volatile, "VOLATILE BODY")

      messages = [
        ReqLLM.Context.system("ignored — runtime carries the truth"),
        ReqLLM.Context.user("hello"),
        ReqLLM.Context.assistant("hi back")
      ]

      out = TypedStructured.serialize_messages(messages, runtime)

      stable_pos = :binary.match(out, "STABLE BODY") |> elem(0)
      user_pos = :binary.match(out, "hello") |> elem(0)
      assistant_pos = :binary.match(out, "hi back") |> elem(0)
      volatile_pos = :binary.match(out, "VOLATILE BODY") |> elem(0)

      assert stable_pos < user_pos
      assert user_pos < assistant_pos
      assert assistant_pos < volatile_pos
    end

    test "with empty volatile, output has no trailing volatile section" do
      runtime =
        build_runtime()
        |> Map.put(:system_prompt_stable, "STABLE")
        |> Map.put(:system_prompt_volatile, "")

      messages = [
        ReqLLM.Context.system("ignored"),
        ReqLLM.Context.user("hi")
      ]

      out = TypedStructured.serialize_messages(messages, runtime)

      assert out =~ "System: STABLE"
      assert out =~ "User: hi"
      # Only one System: prefix when volatile is empty
      assert length(:binary.matches(out, "System:")) == 1
    end

    test "byte-identical preamble across turns when only volatile changes" do
      stable = "STABLE PREAMBLE"
      messages = [ReqLLM.Context.system("x"), ReqLLM.Context.user("hi")]

      r1 =
        build_runtime()
        |> Map.put(:system_prompt_stable, stable)
        |> Map.put(:system_prompt_volatile, "first volatile")

      r2 =
        build_runtime()
        |> Map.put(:system_prompt_stable, stable)
        |> Map.put(:system_prompt_volatile, "second volatile — different")

      out1 = TypedStructured.serialize_messages(messages, r1)
      out2 = TypedStructured.serialize_messages(messages, r2)

      # Find the position of the volatile tail in each output
      idx1 = :binary.match(out1, "first volatile") |> elem(0)
      idx2 = :binary.match(out2, "second volatile") |> elem(0)

      # Bytes before the volatile tail should be byte-identical
      common = min(idx1, idx2)
      assert binary_part(out1, 0, common) == binary_part(out2, 0, common)
    end
  end
end
