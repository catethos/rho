defmodule RhoFrameworks.Tools.LensToolsTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Tools.LensTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = LensTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      expected =
        [
          "score_role",
          "show_lens_dashboard",
          "switch_lens"
        ]

      assert names == expected
    end

    test "all tools have descriptions" do
      for tool_def <- LensTools.__tools__() do
        assert is_binary(tool_def.tool.description),
               "#{tool_def.tool.name} missing description"

        assert String.length(tool_def.tool.description) > 0,
               "#{tool_def.tool.name} has empty description"
      end
    end

    test "all tools have 2-arity execute functions" do
      for tool_def <- LensTools.__tools__() do
        assert is_function(tool_def.execute, 2),
               "#{tool_def.tool.name} execute is not arity 2"
      end
    end
  end

  describe "parameter schemas" do
    test "score_role has required role_profile_id" do
      tools = LensTools.__tools__()
      score = Enum.find(tools, &(&1.tool.name == "score_role"))
      schema = score.tool.parameter_schema

      assert schema[:role_profile_id][:type] == :string
      assert schema[:role_profile_id][:required] == true
    end

    test "switch_lens has required lens_slug" do
      tools = LensTools.__tools__()
      switch = Enum.find(tools, &(&1.tool.name == "switch_lens"))
      schema = switch.tool.parameter_schema

      assert schema[:lens_slug][:type] == :string
      assert schema[:lens_slug][:required] == true
    end
  end
end
