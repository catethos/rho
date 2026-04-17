defmodule RhoFrameworks.Tools.RoleToolsTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Tools.RoleTools

  describe "tool name stability (snapshot)" do
    test "tool names match expected set" do
      tools = RoleTools.__tools__()
      names = Enum.map(tools, & &1.tool.name) |> Enum.sort()

      expected =
        [
          "check_role_currency",
          "clone_role_skills",
          "find_similar_roles",
          "gap_analysis",
          "get_org_view",
          "list_role_profiles",
          "load_role_profile",
          "save_role_profile",
          "show_career_ladder",
          "start_role_profile_draft"
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
    test "save_role_profile has required name" do
      tools = RoleTools.__tools__()
      save = Enum.find(tools, &(&1.tool.name == "save_role_profile"))
      schema = save.tool.parameter_schema

      assert schema[:name][:type] == :string
      assert schema[:name][:required] == true
    end

    test "gap_analysis has required role_profile_id and snapshot_json" do
      tools = RoleTools.__tools__()
      gap = Enum.find(tools, &(&1.tool.name == "gap_analysis"))
      schema = gap.tool.parameter_schema

      assert schema[:role_profile_id][:type] == :string
      assert schema[:role_profile_id][:required] == true
      assert schema[:snapshot_json][:type] == :string
      assert schema[:snapshot_json][:required] == true
    end
  end
end
