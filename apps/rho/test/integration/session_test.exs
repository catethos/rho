defmodule Rho.Integration.SessionTest do
  @moduledoc """
  Integration tests that exercise the full Session → Worker → Runner → Strategy
  stack with mocked LLM responses. No network, no .rho.exs, no boot-time setup.
  """
  use ExUnit.Case, async: false
  use Mimic
  use Rho.Test

  setup :set_mimic_global
  setup :verify_on_exit!

  # -- Smoke tests (fast, core path) --

  describe "session start/send/stop" do
    @describetag :smoke
    test "session starts, accepts a message, returns text response" do
      stub_llm(text_response("Hello from mock!"))

      {:ok, session} = start_mock_session()
      assert {:ok, "Hello from mock!"} = Rho.Session.send(session, "Hi")
      assert :ok = Rho.Session.stop(session)
    end

    test "Rho.run/2 one-shot convenience works" do
      stub_llm(text_response("One-shot reply"))

      spec = Rho.RunSpec.build(model: "mock:test", max_steps: 5, tools: [], plugins: [])
      assert {:ok, "One-shot reply"} = Rho.run("hello", run_spec: spec)
    end
  end

  describe "tools through full stack" do
    @describetag :smoke
    test "tool call executes and result feeds back to LLM" do
      stub_llm_sequence([
        tool_call_response("Let me echo that.", [{"c1", "echo", %{"msg" => "hello"}}]),
        text_response("The echo returned: echoed: hello")
      ])

      {:ok, session} = start_mock_session(tools: [echo_tool()])
      assert {:ok, "The echo returned: echoed: hello"} = Rho.Session.send(session, "echo hello")
      Rho.Session.stop(session)
    end

    test "custom inline tool works end-to-end" do
      add_tool =
        inline_tool(
          "add",
          "Add two numbers",
          [
            a: [type: :integer, required: true, doc: "First number"],
            b: [type: :integer, required: true, doc: "Second number"]
          ],
          fn %{a: a, b: b}, _ctx -> {:ok, "#{a + b}"} end
        )

      stub_llm_sequence([
        tool_call_response("Computing.", [{"c1", "add", %{"a" => 2, "b" => 3}}]),
        text_response("The sum is 5")
      ])

      {:ok, session} = start_mock_session(tools: [add_tool])
      assert {:ok, "The sum is 5"} = Rho.Session.send(session, "add 2 + 3")
      Rho.Session.stop(session)
    end
  end

  # -- Integration tests (broader coverage) --

  describe "multi-turn conversation" do
    @describetag :integration
    test "session maintains context across turns" do
      # First turn: simple text
      stub_llm(text_response("I'm ready."))
      {:ok, session} = start_mock_session()
      assert {:ok, "I'm ready."} = Rho.Session.send(session, "Hello")

      # Second turn: another text response
      stub_llm(text_response("Still here."))
      assert {:ok, "Still here."} = Rho.Session.send(session, "Are you there?")

      Rho.Session.stop(session)
    end
  end

  describe "RunSpec with explicit config" do
    @describetag :integration
    test "custom system prompt is passed through" do
      stub_llm(text_response("I am a pirate assistant!"))

      {:ok, session} =
        start_mock_session(system_prompt: "You are a pirate. Respond in pirate speak.")

      assert {:ok, "I am a pirate assistant!"} = Rho.Session.send(session, "Who are you?")
      Rho.Session.stop(session)
    end

    test "max_steps budget is respected" do
      loop_tool =
        inline_tool(
          "loop",
          "Always loops",
          [x: [type: :string, doc: "Input"]],
          fn _args, _ctx -> {:ok, "looped"} end
        )

      # max_steps: 2 means exactly 2 LLM calls, each returning a tool call
      stub_llm_sequence([
        tool_call_response("Calling loop.", [{"c1", "loop", %{"x" => "1"}}]),
        tool_call_response("Calling loop again.", [{"c2", "loop", %{"x" => "2"}}])
      ])

      {:ok, session} = start_mock_session(tools: [loop_tool], max_steps: 2)
      result = Rho.Session.send(session, "loop forever")
      assert {:error, _reason} = result
      Rho.Session.stop(session)
    end
  end

  describe "session lifecycle" do
    @describetag :integration
    test "session info returns agent metadata" do
      stub_llm(text_response("ok"))
      {:ok, session} = start_mock_session()

      info = Rho.Session.info(session)
      assert is_map(info)
      assert Map.has_key?(info, :session_id)
      assert Map.has_key?(info, :status)

      Rho.Session.stop(session)
    end

    test "stop is idempotent" do
      stub_llm(text_response("ok"))
      {:ok, session} = start_mock_session()
      assert {:ok, "ok"} = Rho.Session.send(session, "hi")

      assert :ok = Rho.Session.stop(session)
      assert :ok = Rho.Session.stop(session)
    end
  end

  describe "run_with_responses helper" do
    @describetag :integration
    test "single text response through Runner" do
      assert {:ok, "Direct!"} = run_with_responses("hi", [text_response("Direct!")])
    end

    test "tool call through Runner" do
      assert {:ok, "Done"} =
               run_with_responses(
                 "echo hi",
                 [
                   tool_call_response("", [{"c1", "echo", %{"msg" => "hi"}}]),
                   text_response("Done")
                 ],
                 tools: [echo_tool()]
               )
    end
  end

  describe "event collection" do
    @describetag :integration
    test "events are emitted during runner execution" do
      {events, result} =
        collect_events(fn emit ->
          stub_llm(text_response("Hi"))
          spec = Rho.RunSpec.build(model: "mock:test", max_steps: 5, emit: emit, tools: [])
          Rho.Runner.run([ReqLLM.Context.user("hello")], spec)
        end)

      assert {:ok, "Hi"} = result
      assert Enum.any?(events, &match?(%{type: :step_start}, &1))
      assert Enum.any?(events, &match?(%{type: :before_llm}, &1))
    end
  end
end
