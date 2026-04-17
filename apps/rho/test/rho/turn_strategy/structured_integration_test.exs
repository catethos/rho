defmodule Rho.TurnStrategy.StructuredIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the structured strategy through Runner.
  Uses Mimic to mock the LLM layer and verify the full cycle:
  prompt injection -> stream -> parse -> tool execution -> result fed back -> final answer.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Rho.Tape.{Service, Store}

  @test_tape "test_structured_#{System.os_time(:nanosecond)}"

  setup :verify_on_exit!

  setup do
    on_exit(fn -> Store.clear(@test_tape) end)
    :ok
  end

  # -- Helpers --

  defp stub_structured_stream(json_text, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{input_tokens: 50, output_tokens: 30})
    fake = :fake_structured_stream

    stub(ReqLLM, :stream_text, fn _model, _ctx, _opts ->
      {:ok, fake}
    end)

    stub(ReqLLM.StreamResponse, :tokens, fn ^fake ->
      json_text |> String.graphemes()
    end)

    stub(ReqLLM.StreamResponse, :usage, fn ^fake -> usage end)
  end

  defp expect_structured_sequence(json_texts, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{input_tokens: 50, output_tokens: 30})
    counter = :counters.new(1, [:atomics])

    expect(ReqLLM, :stream_text, length(json_texts), fn _model, _ctx, _opts ->
      {:ok, {:fake_structured_stream, :counters.get(counter, 1)}}
    end)

    expect(ReqLLM.StreamResponse, :tokens, length(json_texts), fn {:fake_structured_stream, _i} ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      json_texts |> Enum.at(i) |> String.graphemes()
    end)

    stub(ReqLLM.StreamResponse, :usage, fn {:fake_structured_stream, _i} -> usage end)

    counter
  end

  defp echo_tool do
    %{
      tool:
        ReqLLM.tool(
          name: "echo",
          description: "Echoes a message back",
          parameter_schema: [msg: [type: :string, required: true, doc: "Message to echo"]],
          callback: fn _args -> :ok end
        ),
      execute: fn %{msg: msg}, _ctx -> {:ok, "echoed: #{msg}"} end
    }
  end

  defp collect_events(fun) do
    table = :ets.new(:test_events, [:ordered_set, :public])
    counter = :counters.new(1, [:atomics])

    on_event = fn event ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      :ets.insert(table, {i, event})
      :ok
    end

    result = fun.(on_event)

    events = :ets.tab2list(table) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    :ets.delete(table)
    {result, events}
  end

  # -- Tests --

  describe "single-turn: final_answer" do
    test "structured strategy returns final answer directly" do
      json =
        Jason.encode!(%{
          "thinking" => "User said hi, I should greet them.",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Hello there!"}
        })

      stub_structured_stream(json)

      {result, events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("Hi")],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "Hello there!"} = result

      assert Enum.any?(events, &match?(%{type: :text_delta}, &1))
      assert Enum.any?(events, &match?(%{type: :structured_partial}, &1))
      assert Enum.any?(events, &match?(%{type: :llm_usage}, &1))

      usage_event = Enum.find(events, &match?(%{type: :llm_usage}, &1))
      assert usage_event.usage == %{input_tokens: 50, output_tokens: 30}
    end
  end

  describe "multi-turn: tool call -> result -> final answer" do
    test "executes tool, feeds result back, then returns final answer" do
      tool_json =
        Jason.encode!(%{
          "thinking" => "I need to echo the message.",
          "action" => "echo",
          "action_input" => %{"msg" => "ping"}
        })

      final_json =
        Jason.encode!(%{
          "thinking" => "Got the echo result, return it.",
          "action" => "final_answer",
          "action_input" => %{"answer" => "The echo returned: echoed: ping"}
        })

      _counter = expect_structured_sequence([tool_json, final_json])

      {result, events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("echo ping")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "The echo returned: echoed: ping"} = result

      assert Enum.any?(events, &match?(%{type: :tool_start, name: "echo"}, &1))
      assert Enum.any?(events, &match?(%{type: :tool_result, name: "echo", status: :ok}, &1))

      step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
      assert length(step_starts) == 2
    end
  end

  describe "tape recording" do
    test "structured tool steps are recorded to tape correctly" do
      Service.ensure_bootstrap_anchor(@test_tape)

      tool_json =
        Jason.encode!(%{
          "thinking" => "Let me echo.",
          "action" => "echo",
          "action_input" => %{"msg" => "tape_test"}
        })

      final_json =
        Jason.encode!(%{
          "thinking" => "Done.",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Tape recorded"}
        })

      _counter = expect_structured_sequence([tool_json, final_json])

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("echo for tape")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            tape_name: @test_tape,
            max_steps: 5
          )
        end)

      assert {:ok, "Tape recorded"} = result

      context = Rho.Tape.Context.build(@test_tape)
      assert context != []

      roles = Enum.map(context, & &1.role)
      assert :user in roles
      assert :assistant in roles
    end
  end

  describe "unknown tool handling" do
    test "returns error message for unknown tool and continues" do
      bad_json =
        Jason.encode!(%{
          "thinking" => "Using nonexistent tool.",
          "action" => "nonexistent_tool",
          "action_input" => %{}
        })

      final_json =
        Jason.encode!(%{
          "thinking" => "OK, let me answer directly.",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Recovered from error"}
        })

      _counter = expect_structured_sequence([bad_json, final_json])

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("do something")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "Recovered from error"} = result
    end
  end

  describe "unparseable output" do
    test "treats unparseable LLM output as final answer" do
      stub_structured_stream("I'm just going to answer directly without JSON.")

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("Hi")],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "I'm just going to answer directly without JSON."} = result
    end
  end

  describe "tool prompt injection" do
    test "system prompt includes tool descriptions when structured strategy is active" do
      pid = self()

      expect(ReqLLM, :stream_text, fn _model, ctx, _opts ->
        send(pid, {:context, ctx})
        {:ok, :fake_prompt_check}
      end)

      stub(ReqLLM.StreamResponse, :tokens, fn :fake_prompt_check ->
        Jason.encode!(%{"action" => "final_answer", "action_input" => %{"answer" => "ok"}})
        |> String.graphemes()
      end)

      stub(ReqLLM.StreamResponse, :usage, fn :fake_prompt_check -> %{} end)

      Rho.Runner.run("mock:model", [ReqLLM.Context.user("test")],
        tools: [echo_tool()],
        turn_strategy: Rho.TurnStrategy.Structured,
        emit: fn _event -> :ok end,
        max_steps: 1
      )

      assert_received {:context, context}
      system_msg = hd(context)
      system_text = extract_system_text(system_msg)

      assert system_text =~ "OUTPUT FORMAT"
      assert system_text =~ "echo"
      assert system_text =~ "Action variants"
      assert system_text =~ "final_answer"
      # Tool descriptions are merged into action variants (no separate Tool Reference section)
      assert system_text =~ "Echoes a message back"
    end
  end

  describe "re-prompt on parse failure" do
    test "retries with correction message when LLM output is not valid JSON" do
      bad_text = "Let me think about this... I'll use the bash tool to list files."

      final_json =
        Jason.encode!(%{
          "thinking" => "Right, I need to use JSON format.",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Recovered after re-prompt"}
        })

      _counter = expect_structured_sequence([bad_text, final_json])

      {result, events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("hello")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "Recovered after re-prompt"} = result

      step_starts = Enum.filter(events, &match?(%{type: :step_start}, &1))
      assert length(step_starts) == 2
    end
  end

  describe "action_input as string" do
    test "handles action_input as a string instead of object" do
      json =
        Jason.encode!(%{
          "thinking" => "Running a command",
          "action" => "echo",
          "action_input" => "ping"
        })

      final_json =
        Jason.encode!(%{
          "thinking" => "Got the result",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Done"}
        })

      _counter = expect_structured_sequence([json, final_json])

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("echo ping")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, _} = result
    end
  end

  describe "alternative field names" do
    test "handles 'tool' field name instead of 'action'" do
      json = ~s[{"thinking": "running command", "tool": "echo", "tool_input": {"msg": "hi"}}]

      final_json =
        Jason.encode!(%{
          "thinking" => "Done",
          "action" => "final_answer",
          "action_input" => %{"answer" => "Handled tool alias"}
        })

      _counter = expect_structured_sequence([json, final_json])

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("echo hi")],
            tools: [echo_tool()],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, _} = result
    end
  end

  describe "markdown-wrapped JSON" do
    test "parses JSON wrapped in markdown code fences" do
      json_text =
        "```json\n" <>
          Jason.encode!(%{
            "thinking" => "answering",
            "action" => "final_answer",
            "action_input" => %{"answer" => "From markdown fence"}
          }) <> "\n```"

      stub_structured_stream(json_text)

      {result, _events} =
        collect_events(fn on_event ->
          Rho.Runner.run("mock:model", [ReqLLM.Context.user("test")],
            turn_strategy: Rho.TurnStrategy.Structured,
            emit: on_event,
            max_steps: 5
          )
        end)

      assert {:ok, "From markdown fence"} = result
    end
  end

  # -- Helpers --

  defp extract_system_text(%{content: content}) when is_binary(content), do: content

  defp extract_system_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
  end
end
