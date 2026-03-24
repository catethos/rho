defmodule Rho.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Rho.StructuredOutput

  # ── parse/1 ──

  describe "parse/1" do
    test "parses valid JSON" do
      assert {:ok, %{"name" => "John", "age" => 30}} =
               StructuredOutput.parse(~s({"name": "John", "age": 30}))
    end

    test "returns error for empty input" do
      assert {:error, :empty} = StructuredOutput.parse("")
      assert {:error, :empty} = StructuredOutput.parse("   ")
    end

    test "extracts JSON from markdown fences" do
      input = ~s(```json\n{"name": "John", "age": 30}\n```)
      assert {:ok, %{"name" => "John"}} = StructuredOutput.parse(input)
    end

    test "extracts JSON from bare markdown fences" do
      input = ~s(```\n{"name": "Alice"}\n```)
      assert {:ok, %{"name" => "Alice"}} = StructuredOutput.parse(input)
    end

    test "handles curly quotes in JSON structure" do
      # LLM uses curly quotes for keys/values outside strings
      input = "{ \u201Ctool\u201D: \u201CBash\u201D }"
      assert {:ok, %{"tool" => "Bash"}} = StructuredOutput.parse(input)
    end

    test "handles curly quotes inside string values" do
      input = ~s({"message": "blend of \u201Ccat\u201D and \u201Cethos\u201D"})
      assert {:ok, %{"message" => msg}} = StructuredOutput.parse(input)
      assert msg =~ "cat"
      assert msg =~ "ethos"
    end

    test "handles literal newlines in string values" do
      input = "{\"message\": \"Hello\nWorld\"}"
      assert {:ok, %{"message" => "Hello\nWorld"}} = StructuredOutput.parse(input)
    end

    test "handles literal tabs in string values" do
      input = "{\"message\": \"Hello\tWorld\"}"
      assert {:ok, %{"message" => "Hello\tWorld"}} = StructuredOutput.parse(input)
    end

    test "handles JSON with preamble text" do
      input = "Here's the JSON: {\"name\": \"John\"}"
      assert {:ok, %{"name" => "John"}} = StructuredOutput.parse(input)
    end

    test "handles JSON with embedded markdown code blocks in values" do
      input = ~s({"tool":"FinalResponse","message":"Here's a JSON example:\\n\\n```json\\n{\\"data\\": [1, 2, 3]}\\n```\\n\\nThis shows how to format data."})
      assert {:ok, %{"tool" => "FinalResponse"}} = StructuredOutput.parse(input)
    end

    test "handles uppercase JSON code fence" do
      input = "```JSON\n{\"name\": \"John\", \"age\": 30}\n```"
      assert {:ok, %{"name" => "John", "age" => 30}} = StructuredOutput.parse(input)
    end

    test "handles escaped quotes in string values" do
      input = ~s({"message": "Your username is \\"catethos\\"."})
      assert {:ok, %{"message" => msg}} = StructuredOutput.parse(input)
      assert msg =~ "catethos"
    end
  end

  # ── parse_partial/1 ──

  describe "parse_partial/1" do
    test "parses complete JSON" do
      assert {:ok, %{"name" => "John", "age" => 30}} =
               StructuredOutput.parse_partial(~s({"name": "John", "age": 30}))
    end

    test "returns partial nil for empty input" do
      assert {:partial, nil} = StructuredOutput.parse_partial("")
    end

    test "auto-closes incomplete object" do
      assert {:ok, %{"name" => "John", "age" => 30}} =
               StructuredOutput.parse_partial(~s({"name": "John", "age": 30))
    end

    test "auto-closes incomplete string" do
      assert {:ok, %{"name" => "Joh"}} =
               StructuredOutput.parse_partial(~s({"name": "Joh))
    end

    test "auto-closes incomplete array" do
      assert {:ok, %{"items" => [1, 2, 3]}} =
               StructuredOutput.parse_partial(~s({"items": [1, 2, 3))
    end

    test "auto-closes nested incomplete objects" do
      assert {:ok, %{"person" => %{"name" => "John", "age" => 30}}} =
               StructuredOutput.parse_partial(~s({"person": {"name": "John", "age": 30))
    end

    test "handles trailing comma" do
      assert {:ok, %{"name" => "John"}} =
               StructuredOutput.parse_partial(~s({"name": "John", "age": 30,))
    end

    test "handles incomplete JSON in markdown fence" do
      input = "```json\n{\"name\": \"John\", \"age\": 30"
      assert {:ok, %{"name" => "John"}} = StructuredOutput.parse_partial(input)
    end

    test "auto-closes deeply nested (3 levels)" do
      assert {:ok, result} =
               StructuredOutput.parse_partial(~s({"level1": {"level2": {"level3": {"name": "deep"))
      assert result["level1"]["level2"]["level3"]["name"] == "deep"
    end

    test "auto-closes deeply nested (4 levels)" do
      assert {:ok, result} =
               StructuredOutput.parse_partial(~s({"a": {"b": {"c": {"d": {"value": 42))
      assert result["a"]["b"]["c"]["d"]["value"] == 42
    end

    test "handles braces inside string values" do
      assert {:ok, %{"text" => "use { for scope"}} =
               StructuredOutput.parse_partial(~s({"text": "use { for scope))
    end

    test "handles brackets inside string values" do
      assert {:ok, %{"code" => "arr = [1, 2, 3]"}} =
               StructuredOutput.parse_partial(~s({"code": "arr = [1, 2, 3]))
    end

    test "handles curly quotes in streaming" do
      input = "{ \u201Ctool\u201D: \u201CBash\u201D }"
      assert {:ok, %{"tool" => "Bash"}} = StructuredOutput.parse_partial(input)
    end

    test "handles deeply nested with arrays" do
      assert {:ok, result} =
               StructuredOutput.parse_partial(~s({"data": {"items": [{"name": "first"}, {"name": "second"))
      assert result["data"]["items"] |> hd() |> Map.get("name") == "first"
    end
  end

  # ── Helper functions ──

  describe "normalize_quotes/1" do
    test "converts curly quotes outside strings to ASCII" do
      input = "{ \u201Ckey\u201D: \u201Cvalue\u201D }"
      result = StructuredOutput.normalize_quotes(input)
      assert result == ~s({ "key": "value" })
    end

    test "escapes curly quotes inside strings" do
      input = ~s({"msg": "He used \u201Cemphasis\u201D marks"})
      result = StructuredOutput.normalize_quotes(input)
      # Inside string, curly quotes become escaped quotes
      assert result =~ "emphasis"
    end

    test "preserves already escaped content" do
      input = ~s({"text": "already \\"escaped\\" here"})
      assert StructuredOutput.normalize_quotes(input) == input
    end
  end

  describe "count_braces/1" do
    test "counts braces outside strings" do
      assert {2, 1, 0, 0} = StructuredOutput.count_braces(~s({"a": {"b": "c"}))
      assert {1, 1, 0, 0} = StructuredOutput.count_braces(~s({"text": "use { here"}))
    end

    test "counts brackets outside strings" do
      assert {1, 0, 1, 0} = StructuredOutput.count_braces(~s({"items": [1, 2))
    end
  end

  describe "has_incomplete_string?/1" do
    test "detects incomplete string" do
      assert StructuredOutput.has_incomplete_string?(~s({"name": "Joh))
    end

    test "detects complete strings" do
      refute StructuredOutput.has_incomplete_string?(~s({"name": "John"}))
    end

    test "handles escaped quotes" do
      refute StructuredOutput.has_incomplete_string?(~s({"msg": "he said \\"hi\\""}))
    end
  end

  # ── AgentAction format (what the reasoner produces) ──

  describe "AgentAction parsing" do
    test "parses a tool call action" do
      input = ~s({"thinking": "I need to list files", "action": "bash", "action_input": {"cmd": "ls -la"}})
      assert {:ok, parsed} = StructuredOutput.parse(input)
      assert parsed["action"] == "bash"
      assert parsed["action_input"]["cmd"] == "ls -la"
    end

    test "parses a final answer action" do
      input = ~s({"thinking": "I have the answer", "action": "final_answer", "action_input": {"answer": "Hello!"}})
      assert {:ok, parsed} = StructuredOutput.parse(input)
      assert parsed["action"] == "final_answer"
      assert parsed["action_input"]["answer"] == "Hello!"
    end

    test "partially parses an incomplete tool call" do
      input = ~s({"thinking": "I need to check", "action": "bash", "action_input": {"cmd": "git st)
      assert {:ok, parsed} = StructuredOutput.parse_partial(input)
      assert parsed["action"] == "bash"
      assert parsed["action_input"]["cmd"] =~ "git st"
    end
  end
end
