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
          "combine_libraries_commit",
          "consolidate_library",
          "create_library",
          "create_library_draft",
          "diff_library",
          "diff_library_versions",
          "dismiss_duplicate",
          "find_duplicates",
          "fork_library",
          "list_libraries",
          "list_library_versions",
          "load_library",
          "load_template",
          "merge_skills",
          "publish_library_version",
          "save_and_generate",
          "save_to_library",
          "search_skills_cross_library",
          "set_default_library_version"
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
      # Neither is individually required — the tool enforces
      # "at least one" at runtime and returns a friendly error.
      refute Keyword.get(schema[:library_id], :required)
      refute Keyword.get(schema[:library_name], :required)
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
