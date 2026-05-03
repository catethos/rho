defmodule RhoFrameworks.Tools.LensToolsTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Tools.LensTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = LensTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      expected =
        [
          "lens_dashboard",
          "score_role"
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
  end
end
