defmodule RhoFrameworks.Tools.LibraryToolsTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Tools.LibraryTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = LibraryTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      expected =
        [
          "browse_library",
          "combine_libraries",
          "dedup_library",
          "diff_library",
          "fork_library",
          "library_versions",
          "load_library",
          "manage_library",
          "save_library"
        ]

      assert names == expected
    end

    test "all tools have descriptions" do
      for tool_def <- LibraryTools.__tools__() do
        assert is_binary(tool_def.tool.description),
               "#{tool_def.tool.name} missing description"

        assert String.length(tool_def.tool.description) > 0,
               "#{tool_def.tool.name} has empty description"
      end
    end

    test "all tools have 2-arity execute functions" do
      for tool_def <- LibraryTools.__tools__() do
        assert is_function(tool_def.execute, 2),
               "#{tool_def.tool.name} execute is not arity 2"
      end
    end
  end

  describe "parameter schemas" do
    test "browse_library accepts library_id or library_name (neither required)" do
      tools = LibraryTools.__tools__()
      browse = Enum.find(tools, &(&1.tool.name == "browse_library"))
      schema = browse.tool.parameter_schema

      assert schema[:library_id][:type] == :string
      assert schema[:library_name][:type] == :string
      refute Keyword.get(schema[:library_id], :required)
      refute Keyword.get(schema[:library_name], :required)
    end

    test "manage_library has required action" do
      tools = LibraryTools.__tools__()
      manage = Enum.find(tools, &(&1.tool.name == "manage_library"))
      schema = manage.tool.parameter_schema

      assert schema[:action][:type] == :string
      assert schema[:action][:required] == true
    end

    test "save_library has required action" do
      tools = LibraryTools.__tools__()
      save = Enum.find(tools, &(&1.tool.name == "save_library"))
      schema = save.tool.parameter_schema

      assert schema[:action][:type] == :string
      assert schema[:action][:required] == true
    end
  end
end
