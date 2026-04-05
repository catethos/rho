defmodule RhoWeb.ArgFormatterTest do
  use ExUnit.Case, async: true

  alias RhoWeb.ArgFormatter

  describe "extract_inner_json/1" do
    test "decodes a *_json string field and yields a labelled part" do
      args = %{"rows_json" => ~s([{"name":"Alice"},{"name":"Bob"}])}

      {parts, rest} = ArgFormatter.extract_inner_json(args)

      assert rest == %{}
      assert [{"rows", pretty, "json"}] = parts
      assert pretty =~ ~s("name": "Alice")
      assert pretty =~ ~s("name": "Bob")
    end

    test "handles fenced JSON inside the string field" do
      inner = ~s(```json\n[1,2,3]\n```)
      args = %{"ids_json" => inner}

      {parts, rest} = ArgFormatter.extract_inner_json(args)

      assert rest == %{}
      assert [{"ids", pretty, "json"}] = parts
      assert pretty =~ "1"
    end

    test "leaves fields whose value is not a string alone" do
      args = %{"rows_json" => [%{a: 1}], "count" => 5}
      {parts, rest} = ArgFormatter.extract_inner_json(args)
      assert parts == []
      assert rest == %{"rows_json" => [%{a: 1}], "count" => 5}
    end

    test "leaves fields with non-matching names alone" do
      args = %{"count" => 5, "name" => "foo"}
      {parts, rest} = ArgFormatter.extract_inner_json(args)
      assert parts == []
      assert rest == %{"count" => 5, "name" => "foo"}
    end

    test "falls back to raw when the inner string isn't valid JSON" do
      args = %{"rows_json" => "not actually json {{{"}
      {parts, rest} = ArgFormatter.extract_inner_json(args)
      assert parts == []
      assert rest == %{"rows_json" => "not actually json {{{"}
    end

    test "handles `arguments` literal key (OpenAI tool_calls style)" do
      args = %{"arguments" => ~s({"command":"ls -la"})}
      {parts, rest} = ArgFormatter.extract_inner_json(args)
      assert rest == %{}
      assert [{"arguments", pretty, "json"}] = parts
      assert pretty =~ "ls -la"
    end

    test "mixes extracted + remaining fields" do
      args = %{
        "rows_json" => ~s([{"id":1}]),
        "mode" => "append",
        "dry_run" => false
      }

      {parts, rest} = ArgFormatter.extract_inner_json(args)

      assert [{"rows", _, "json"}] = parts
      assert rest == %{"mode" => "append", "dry_run" => false}
    end

    test "handles atom keys" do
      args = %{rows_json: ~s([{"a":1}])}
      {parts, rest} = ArgFormatter.extract_inner_json(args)
      assert [{"rows", _, "json"}] = parts
      assert rest == %{}
    end

    test "all three suffix conventions (_json, _raw, _payload)" do
      args = %{
        "rows_json" => ~s([1]),
        "changes_raw" => ~s({"k":"v"}),
        "body_payload" => ~s({"x":true})
      }

      {parts, _rest} = ArgFormatter.extract_inner_json(args)
      labels = Enum.map(parts, fn {l, _, _} -> l end)
      assert "rows" in labels
      assert "changes" in labels
      assert "body" in labels
    end
  end

  describe "inner_json_key?/1" do
    test "matches known suffixes" do
      assert ArgFormatter.inner_json_key?("rows_json")
      assert ArgFormatter.inner_json_key?("ids_json")
      assert ArgFormatter.inner_json_key?("text_raw")
      assert ArgFormatter.inner_json_key?("body_payload")
      assert ArgFormatter.inner_json_key?("arguments")
      refute ArgFormatter.inner_json_key?("name")
      refute ArgFormatter.inner_json_key?("count")
      refute ArgFormatter.inner_json_key?("json")
    end
  end

  describe "inner_json_label/1" do
    test "strips known suffixes" do
      assert ArgFormatter.inner_json_label("rows_json") == "rows"
      assert ArgFormatter.inner_json_label("text_raw") == "text"
      assert ArgFormatter.inner_json_label("body_payload") == "body"
    end

    test "returns unchanged if stripping would yield empty" do
      assert ArgFormatter.inner_json_label("_json") == "_json"
    end

    test "leaves arguments unchanged (has no suffix to strip)" do
      assert ArgFormatter.inner_json_label("arguments") == "arguments"
    end
  end
end
