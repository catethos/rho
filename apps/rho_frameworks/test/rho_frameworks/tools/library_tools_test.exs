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
          "consolidate_library",
          "create_library",
          "diff_library",
          "dismiss_duplicate",
          "find_duplicates",
          "fork_library",
          "list_libraries",
          "load_library",
          "load_template",
          "merge_skills",
          "save_to_library",
          "search_skills_cross_library"
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
    test "browse_library has required library_id" do
      tools = LibraryTools.__tools__()
      browse = Enum.find(tools, &(&1.tool.name == "browse_library"))
      schema = browse.tool.parameter_schema

      assert schema[:library_id][:type] == :string
      assert schema[:library_id][:required] == true
    end

    test "create_library has required name" do
      tools = LibraryTools.__tools__()
      create = Enum.find(tools, &(&1.tool.name == "create_library"))
      schema = create.tool.parameter_schema

      assert schema[:name][:type] == :string
      assert schema[:name][:required] == true
    end

    test "list_libraries has no parameters" do
      tools = LibraryTools.__tools__()
      list = Enum.find(tools, &(&1.tool.name == "list_libraries"))
      assert list.tool.parameter_schema == []
    end
  end
end
