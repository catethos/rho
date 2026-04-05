defmodule Rho.Parse.LenientTest do
  use ExUnit.Case, async: true

  alias Rho.Parse.Lenient

  # ── parse/1 ──

  describe "parse/1" do
    test "decodes valid JSON object" do
      assert {:ok, %{"a" => 1}} = Lenient.parse(~s({"a": 1}))
    end

    test "decodes valid JSON array" do
      assert {:ok, [1, 2, 3]} = Lenient.parse(~s([1, 2, 3]))
    end

    test "strips ```json fence" do
      input = "```json\n{\"a\": 1}\n```"
      assert {:ok, %{"a" => 1}} = Lenient.parse(input)
    end

    test "strips bare ``` fence" do
      input = "```\n{\"a\": 1}\n```"
      assert {:ok, %{"a" => 1}} = Lenient.parse(input)
    end

    test "handles leading/trailing whitespace around fence" do
      input = "  \n```json\n{\"a\": 1}\n```\n  "
      assert {:ok, %{"a" => 1}} = Lenient.parse(input)
    end

    test "returns error for malformed JSON" do
      assert {:error, _} = Lenient.parse("{not json")
    end

    test "returns error for empty input" do
      assert {:error, _} = Lenient.parse("")
    end

    test "is idempotent when no fences present" do
      assert {:ok, %{"a" => 1}} = Lenient.parse(~s({"a": 1}))
    end
  end

  # ── parse_partial/1 ──

  describe "parse_partial/1 — auto-closing" do
    test "closes missing } on simple object" do
      assert {:ok, %{"a" => 1}} = Lenient.parse_partial(~s({"a": 1))
    end

    test "closes missing ] on array inside object" do
      assert {:ok, %{"rows" => [1, 2]}} =
               Lenient.parse_partial(~s({"rows": [1, 2))
    end

    test "closes missing \" on unterminated string" do
      assert {:ok, %{"name" => "Ali"}} =
               Lenient.parse_partial(~s({"name": "Ali))
    end

    test "closes deeply nested partials" do
      assert {:ok, %{"a" => %{"b" => %{"c" => 1}}}} =
               Lenient.parse_partial(~s({"a": {"b": {"c": 1))
    end

    test "does not double-close" do
      assert {:ok, %{"a" => 1}} = Lenient.parse_partial(~s({"a": 1}))
    end

    test "ignores structural chars inside strings" do
      # The { inside the string must not be counted as an opener
      assert {:ok, %{"cmd" => "echo {}"}} =
               Lenient.parse_partial(~s({"cmd": "echo {}"}))
    end

    test "closes object with string containing braces, mid-stream" do
      assert {:ok, %{"cmd" => "echo {"}} =
               Lenient.parse_partial(~s({"cmd": "echo {))
    end

    test "handles escaped quotes inside strings" do
      assert {:ok, %{"s" => "a\"b"}} =
               Lenient.parse_partial(~s({"s": "a\\"b"}))
    end

    test "returns partial nil / error for empty input" do
      assert {:error, _} = Lenient.parse_partial("")
    end

    test "strips fences on partials" do
      assert {:ok, %{"a" => 1}} =
               Lenient.parse_partial("```json\n{\"a\": 1")
    end
  end

  # ── auto_close/1 ──

  describe "auto_close/1" do
    test "adds closers for unclosed openers" do
      assert Lenient.auto_close(~s({"a": [1, 2)) == ~s({"a": [1, 2]})
    end

    test "leaves complete input unchanged" do
      assert Lenient.auto_close(~s({"a": 1})) == ~s({"a": 1})
    end

    test "closes unterminated string first, then structures" do
      assert Lenient.auto_close(~s({"s": "ab)) == ~s({"s": "ab"})
    end

    test "does not count braces inside strings" do
      assert Lenient.auto_close(~s({"s": "a{b}c")) == ~s({"s": "a{b}c"})
    end
  end

  # ── strip_fences/1 ──

  describe "strip_fences/1" do
    test "strips ```json fence" do
      assert Lenient.strip_fences("```json\n{\"a\": 1}\n```") == ~s({"a": 1})
    end

    test "strips bare fence" do
      assert Lenient.strip_fences("```\n{\"a\": 1}\n```") == ~s({"a": 1})
    end

    test "is idempotent with no fences" do
      assert Lenient.strip_fences(~s({"a": 1})) == ~s({"a": 1})
    end
  end
end
