defmodule RhoFrameworks.Tools.RoleToolsTest do
  use ExUnit.Case, async: false

  alias RhoFrameworks.Tools.RoleTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = RoleTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      expected =
        [
          "analyze_role",
          "manage_role",
          "org_view"
        ]

      assert names == expected
    end

    test "all tools have descriptions" do
      for tool_def <- RoleTools.__tools__() do
        assert is_binary(tool_def.tool.description),
               "#{tool_def.tool.name} missing description"

        assert String.length(tool_def.tool.description) > 0,
               "#{tool_def.tool.name} has empty description"
      end
    end

    test "all tools have 2-arity execute functions" do
      for tool_def <- RoleTools.__tools__() do
        assert is_function(tool_def.execute, 2),
               "#{tool_def.tool.name} execute is not arity 2"
      end
    end
  end

  describe "parameter schemas" do
    test "manage_role has required action" do
      tools = RoleTools.__tools__()
      manage = Enum.find(tools, &(&1.tool.name == "manage_role"))
      schema = manage.tool.parameter_schema

      assert schema[:action][:type] == :string
      assert schema[:action][:required] == true
    end

    test "analyze_role has required action" do
      tools = RoleTools.__tools__()
      analyze = Enum.find(tools, &(&1.tool.name == "analyze_role"))
      schema = analyze.tool.parameter_schema

      assert schema[:action][:type] == :string
      assert schema[:action][:required] == true
    end
  end
end
