defmodule RhoFrameworks.Tools.SharedToolsTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Tools.SharedTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = SharedTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      assert names == ["add_proficiency_levels"]
    end

    test "all tools have descriptions" do
      for tool_def <- SharedTools.__tools__() do
        assert is_binary(tool_def.tool.description),
               "#{tool_def.tool.name} missing description"

        assert String.length(tool_def.tool.description) > 0,
               "#{tool_def.tool.name} has empty description"
      end
    end

    test "all tools have 2-arity execute functions" do
      for tool_def <- SharedTools.__tools__() do
        assert is_function(tool_def.execute, 2),
               "#{tool_def.tool.name} execute is not arity 2"
      end
    end
  end

  describe "parameter schemas" do
    test "add_proficiency_levels has required levels_json" do
      tools = SharedTools.__tools__()
      add = Enum.find(tools, &(&1.tool.name == "add_proficiency_levels"))
      schema = add.tool.parameter_schema

      assert schema[:levels_json][:type] == :string
      assert schema[:levels_json][:required] == true
    end
  end
end
