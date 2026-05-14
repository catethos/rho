defmodule Rho.Test do
  @moduledoc """
  Test helpers for Rho agents — mocked LLM responses, one-shot runs,
  and session lifecycle without any external dependencies.

  ## Quick start

      use Rho.Test

      test "simple text response" do
        stub_llm(text_response("Hello!"))
        assert {:ok, "Hello!"} = run_agent("Hi")
      end

      test "tool call sequence" do
        stub_llm_sequence([
          tool_call_response("Let me check.", [{"c1", "echo", %{"msg" => "hi"}}]),
          text_response("Done")
        ])
        {:ok, session} = start_mock_session(tools: [echo_tool()])
        assert {:ok, "Done"} = Rho.Session.send(session, "echo hi")
        Rho.Session.stop(session)
      end

  ## How mocking works

  Rho calls `ReqLLM.stream_text/3` → gets a stream ref → passes it to
  `ReqLLM.StreamResponse.process_stream/2` → gets a `%ReqLLM.Response{}`.
  We stub both via Mimic to return canned responses without any network.
  """

  defmacro __using__(_opts) do
    quote do
      import Rho.Test
    end
  end

  # -------------------------------------------------------------------
  # Response builders
  # -------------------------------------------------------------------

  @doc "Build a canned text-only LLM response."
  def text_response(text) do
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

  @doc """
  Build a canned tool-call LLM response.

  `tool_calls` is a list of `{call_id, tool_name, args_map}` tuples.
  """
  def tool_call_response(text, tool_calls) do
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

  # -------------------------------------------------------------------
  # LLM stubbing
  # -------------------------------------------------------------------

  @doc """
  Stub `ReqLLM.stream_text` and `ReqLLM.StreamResponse.process_stream`
  to always return the given response. Use for single-turn tests.
  """
  def stub_llm(response) do
    Mimic.stub(ReqLLM, :stream_text, fn _model, _ctx, _opts ->
      {:ok, :mock_stream}
    end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn :mock_stream, _opts ->
      {:ok, response}
    end)
  end

  @doc """
  Set up expectations for a multi-turn sequence of LLM responses.
  Each call to the LLM returns the next response in order.
  """
  def stub_llm_sequence(responses) when is_list(responses) do
    counter = :counters.new(1, [:atomics])

    Mimic.expect(ReqLLM, :stream_text, length(responses), fn _model, _ctx, _opts ->
      {:ok, {:mock_stream, :counters.get(counter, 1)}}
    end)

    Mimic.expect(ReqLLM.StreamResponse, :process_stream, length(responses), fn
      {:mock_stream, _idx}, _opts ->
        i = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        {:ok, Enum.at(responses, i)}
    end)
  end

  # -------------------------------------------------------------------
  # One-shot agent run (Runner-level, no session/worker)
  # -------------------------------------------------------------------

  @doc """
  Run a single agent interaction with mocked LLM responses.
  Goes through `Rho.Runner.run/2` directly — no Worker/Session overhead.

  Returns `{:ok, text}` or `{:error, reason}`.

  ## Options

    * `:responses` — list of canned responses (required)
    * `:tools` — list of tool_def maps
    * `:model` — model string (default: `"mock:test"`)
    * `:max_steps` — step budget (default: 10)
    * All other opts forwarded to `RunSpec.build/1`
  """
  def run_with_responses(message, responses, opts \\ []) when is_list(responses) do
    if match?([_], responses) do
      stub_llm(hd(responses))
    else
      stub_llm_sequence(responses)
    end

    spec_opts =
      opts
      |> Keyword.put_new(:model, "mock:test")
      |> Keyword.put_new(:max_steps, 10)
      |> Keyword.delete(:responses)

    spec = Rho.RunSpec.build(spec_opts)
    messages = [ReqLLM.Context.user(message)]

    Rho.Runner.run(messages, spec)
  end

  # -------------------------------------------------------------------
  # Session-level helpers
  # -------------------------------------------------------------------

  @doc """
  Start a session backed by a mocked LLM. Returns `{:ok, %Handle{}}`.

  The session uses a fresh RunSpec with `model: "mock:test"` and no tape.
  You must call `stub_llm/1` or `stub_llm_sequence/1` before sending
  messages through the session.

  ## Options

    * `:tools` — list of tool_def maps (pre-resolved, skips PluginRegistry)
    * `:model` — model string (default: `"mock:test"`)
    * `:max_steps` — step budget (default: 10)
    * `:system_prompt` — system prompt
    * `:plugins` — plugin list (default: [])
    * All other opts forwarded to `RunSpec.build/1`
  """
  def start_mock_session(opts \\ []) do
    spec_opts =
      opts
      |> Keyword.put_new(:model, "mock:test")
      |> Keyword.put_new(:max_steps, 10)
      |> Keyword.put_new(:tools, [])
      |> Keyword.put_new(:plugins, [])

    spec = Rho.RunSpec.build(spec_opts)

    Rho.Session.start(run_spec: spec)
  end

  # -------------------------------------------------------------------
  # Inline tool builders
  # -------------------------------------------------------------------

  @doc """
  Build an inline tool definition for testing. The tool executes
  the given function when called.

  ## Example

      tool = inline_tool("greet", "Say hello",
        [name: [type: :string, required: true, doc: "Name"]],
        fn %{name: name}, _ctx -> {:ok, "Hello, \#{name}!"} end
      )
  """
  def inline_tool(name, description, params, execute_fn) do
    %{
      tool:
        ReqLLM.tool(
          name: name,
          description: description,
          parameter_schema: params,
          callback: fn _args -> :ok end
        ),
      execute: execute_fn
    }
  end

  @doc "A simple echo tool for testing."
  def echo_tool do
    inline_tool(
      "echo",
      "Echoes the message back",
      [msg: [type: :string, required: true, doc: "Message to echo"]],
      fn %{msg: msg}, _ctx -> {:ok, "echoed: #{msg}"} end
    )
  end

  # -------------------------------------------------------------------
  # Event collection
  # -------------------------------------------------------------------

  @doc """
  Collect all events emitted during a block. Pass the returned
  `on_event` function as the `:emit` option.

      {events, result} = collect_events(fn emit ->
        spec = RunSpec.build(model: "mock:test", emit: emit)
        Rho.Runner.run(messages, spec)
      end)
  """
  def collect_events(fun) do
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
    {events, result}
  end
end
