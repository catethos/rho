defmodule Rho.RunnerToolCoercionTest do
  @moduledoc """
  Regression tests for tool-result coercion in the lite-mode runner path.

  Covers the `Protocol.UndefinedError` crash that hit production when
  `web_fetch` returned `{:error, {:fetch_failed, "..."}}` and the runner
  tried to interpolate the tuple bare. Tools may return arbitrary terms;
  the runner must coerce them to strings without crashing.
  """

  use ExUnit.Case
  use Mimic

  setup :verify_on_exit!

  # -- Helpers (canned ReqLLM responses) --

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

  defp expect_stream_sequence(responses) do
    counter = :counters.new(1, [:atomics])

    expect(ReqLLM, :stream_text, length(responses), fn _model, _ctx, _opts ->
      {:ok, {:fake_stream, :counters.get(counter, 1)}}
    end)

    expect(ReqLLM.StreamResponse, :process_stream, length(responses), fn {:fake_stream, _idx},
                                                                         _opts ->
      i = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, Enum.at(responses, i)}
    end)
  end

  defp tool_def(name, execute_fn) do
    %{
      tool:
        ReqLLM.tool(
          name: name,
          description: "Stub for coercion regression tests.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: execute_fn
    }
  end

  defp run_lite(tool, tool_call_resp, follow_up_resp \\ nil) do
    responses =
      if follow_up_resp, do: [tool_call_resp, follow_up_resp], else: [tool_call_resp]

    expect_stream_sequence(responses)

    test_pid = self()

    spec =
      Rho.RunSpec.build(
        model: "mock:model",
        tools: [tool],
        max_steps: 5,
        emit: fn event -> send(test_pid, {:event, event}) end,
        lite: true
      )

    Rho.Runner.run([ReqLLM.Context.user("go")], spec)
  end

  # Drain the mailbox until we get the :tool_result event.
  defp wait_for_tool_result(timeout_ms \\ 1000) do
    receive do
      {:event, %{type: :tool_result} = event} -> event
      {:event, _other} -> wait_for_tool_result(timeout_ms)
    after
      timeout_ms -> flunk("did not receive :tool_result event within #{timeout_ms}ms")
    end
  end

  # -- Tests --

  describe "lite-mode tool result coercion" do
    test "tuple-shaped {:error, _} does not crash and is stringified" do
      tool =
        tool_def("web_fetch", fn _args, _ctx ->
          {:error, {:fetch_failed, "%Req.TransportError{reason: :nxdomain}"}}
        end)

      tool_resp = tool_call_response("fetching", [{"call_1", "web_fetch", %{}}])
      final = text_response("done")

      assert {:ok, "done"} = run_lite(tool, tool_resp, final)

      event = wait_for_tool_result()
      assert event.status == :error
      assert is_binary(event.output)
      assert event.output =~ "fetch_failed"
    end

    test "{:ok, tagged tuple} is coerced via inspect/1 (no String.Chars crash)" do
      tool =
        tool_def("tuple_tool", fn _args, _ctx ->
          {:ok, {:custom_tag, "payload"}}
        end)

      tool_resp = tool_call_response("calling", [{"call_1", "tuple_tool", %{}}])
      final = text_response("done")

      assert {:ok, "done"} = run_lite(tool, tool_resp, final)

      event = wait_for_tool_result()
      assert event.status == :ok
      assert is_binary(event.output)
      assert event.output =~ "custom_tag"
    end

    test "{:final, tuple} is coerced and terminates the loop" do
      tool =
        tool_def("final_tuple", fn _args, _ctx ->
          {:final, {:tuple, "x"}}
        end)

      tool_resp = tool_call_response("ending", [{"call_1", "final_tuple", %{}}])

      assert {:ok, output} = run_lite(tool, tool_resp)
      assert is_binary(output)
      assert output =~ "tuple"
    end

    test "{:ok, plain string} passes through unchanged (no inspect-quoting)" do
      tool =
        tool_def("string_tool", fn _args, _ctx ->
          {:ok, "plain string"}
        end)

      tool_resp = tool_call_response("calling", [{"call_1", "string_tool", %{}}])
      final = text_response("done")

      assert {:ok, "done"} = run_lite(tool, tool_resp, final)

      event = wait_for_tool_result()
      assert event.output == "plain string"
    end
  end

  describe "non-lite ToolExecutor coercion" do
    # Sibling coverage for the shared dispatch path used by Direct/TypedStructured
    # outside lite mode. These bypass Runner entirely — they exercise
    # ToolExecutor.run/5 directly.

    test "tuple-shaped {:error, _} routes through error_info, error_type carries the tag" do
      # The non-lite path uses error_info/1, which routes
      # `{atom, detail}` to `{atom, format_error_detail(detail)}`. With a
      # binary detail, output is just the detail; the tag is preserved on
      # `event.error_type`. This pre-existing path was already safe — we
      # assert that contract here so a future change to the success path
      # doesn't accidentally regress error handling.
      tool =
        tool_def("web_fetch", fn _args, _ctx ->
          {:error, {:fetch_failed, "boom"}}
        end)

      tool_map = %{"web_fetch" => tool}
      test_pid = self()

      [result] =
        Rho.ToolExecutor.run(
          [%{name: "web_fetch", args: %{}, call_id: "call_1"}],
          tool_map,
          %Rho.Context{agent_name: :test},
          fn event -> send(test_pid, {:event, event}) end
        )

      assert result.status == :error
      assert is_binary(result.result)
      assert result.result =~ "boom"
      assert result.event.error_type == :fetch_failed
    end

    test "{:ok, tagged tuple} success path uses inspect, not to_string" do
      tool =
        tool_def("tuple_tool", fn _args, _ctx ->
          {:ok, {:custom_tag, "payload"}}
        end)

      tool_map = %{"tuple_tool" => tool}
      test_pid = self()

      [result] =
        Rho.ToolExecutor.run(
          [%{name: "tuple_tool", args: %{}, call_id: "call_1"}],
          tool_map,
          %Rho.Context{agent_name: :test},
          fn event -> send(test_pid, {:event, event}) end
        )

      assert result.status == :ok
      assert is_binary(result.result)
      assert result.result =~ "custom_tag"
    end

    test "{:ok, binary} success path passes through unchanged" do
      tool = tool_def("string_tool", fn _args, _ctx -> {:ok, "plain string"} end)

      tool_map = %{"string_tool" => tool}
      test_pid = self()

      [result] =
        Rho.ToolExecutor.run(
          [%{name: "string_tool", args: %{}, call_id: "call_1"}],
          tool_map,
          %Rho.Context{agent_name: :test},
          fn event -> send(test_pid, {:event, event}) end
        )

      assert result.status == :ok
      assert result.result == "plain string"
    end
  end

  describe "transformer :tool_args_out deny coercion" do
    defmodule TupleDenyTransformer do
      @behaviour Rho.Transformer

      @impl Rho.Transformer
      def transform(:tool_args_out, _data, _context) do
        {:deny, {:rate_limit, 5}}
      end

      def transform(_stage, data, _context), do: {:cont, data}
    end

    setup do
      # Scope is unique to :coercion_deny_test agent_name — no other test
      # uses that agent, so the registration doesn't leak into the rest of
      # the suite. The registry has no per-module unregister, so we leave it.
      Rho.TransformerRegistry.register(TupleDenyTransformer,
        scope: {:agent, :coercion_deny_test}
      )

      :ok
    end

    test "tuple deny reason is stringified, runner does not crash" do
      tool = tool_def("denied_tool", fn _args, _ctx -> {:ok, "should not run"} end)

      tool_map = %{"denied_tool" => tool}
      test_pid = self()

      [result] =
        Rho.ToolExecutor.run(
          [%{name: "denied_tool", args: %{}, call_id: "call_1"}],
          tool_map,
          %Rho.Context{agent_name: :coercion_deny_test},
          fn event -> send(test_pid, {:event, event}) end
        )

      assert result.status == :error
      assert is_binary(result.result)
      assert result.result =~ "Denied:"
      assert result.result =~ "rate_limit"
    end
  end
end
