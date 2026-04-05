defmodule RhoWeb.StreamEnvelopeTest do
  use ExUnit.Case, async: true

  alias RhoWeb.StreamEnvelope

  describe "analyze/1 — non-envelope" do
    test "returns :no_envelope for plain prose" do
      assert StreamEnvelope.analyze("Let me think about this...") == :no_envelope
    end

    test "returns :no_envelope for empty string" do
      assert StreamEnvelope.analyze("") == :no_envelope
    end

    test "returns :no_envelope for a raw number" do
      assert StreamEnvelope.analyze("42") == :no_envelope
    end

    test "returns :no_envelope for a JSON object without action/thinking" do
      assert StreamEnvelope.analyze(~s({"x": 1, "y": 2})) == :no_envelope
    end
  end

  describe "analyze/1 — full envelope" do
    test "extracts action name from a complete envelope" do
      text = ~s({"action": "add_rows", "action_input": {"rows": [{"name": "Alice"}]}})

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == "add_rows"
      assert summary.action_input == %{"rows" => [%{"name" => "Alice"}]}
    end

    test "extracts `thinking` alongside action" do
      text =
        ~s({"thinking": "I should add rows", "action": "add_rows", "action_input": {"rows": []}})

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == "add_rows"
      assert summary.thinking == "I should add rows"
    end

    test "handles alternate envelope keys (tool, arguments)" do
      text = ~s({"tool": "bash", "arguments": {"command": "ls"}})

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == "bash"
      assert summary.action_input == %{"command" => "ls"}
    end

    test "lenient-parses nested JSON string in action_input" do
      text = ~s({"action": "add_rows", "action_input": "{\\"rows\\":[1,2,3]}"})

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action_input == %{"rows" => [1, 2, 3]}
    end

    test "handles markdown-fenced envelope" do
      text = "```json\n{\"action\": \"bash\", \"action_input\": {\"command\": \"ls\"}}\n```"

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == "bash"
    end
  end

  describe "analyze/1 — partial envelope (streaming)" do
    test "extracts action name once it's present, even with unclosed braces" do
      text = ~s({"action": "add_rows", "action_input": {"rows": [{"name": "Al)

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == "add_rows"
    end

    test "surfaces thinking-only preamble before action arrives" do
      text = ~s({"thinking": "I need to first check the existing)

      assert {:envelope, summary} = StreamEnvelope.analyze(text)
      assert summary.action == nil
      assert summary.thinking =~ "check the existing"
    end

    test "returns :no_envelope when not enough yet to parse" do
      # Just an opening brace — auto_close gives us `{}` which has no action.
      assert StreamEnvelope.analyze("{") == :no_envelope
    end

    test "returns :no_envelope for partial envelope with neither action nor thinking yet" do
      assert StreamEnvelope.analyze(~s({"x": 1,)) == :no_envelope
    end
  end

  describe "envelope_candidate?/1" do
    test "true for leading { or [" do
      assert StreamEnvelope.envelope_candidate?("{")
      assert StreamEnvelope.envelope_candidate?("[")
      assert StreamEnvelope.envelope_candidate?("  { x }")
    end

    test "true for fenced JSON" do
      assert StreamEnvelope.envelope_candidate?("```json\n{}\n```")
    end

    test "false for prose" do
      refute StreamEnvelope.envelope_candidate?("The answer is 42")
      refute StreamEnvelope.envelope_candidate?("")
    end
  end
end
