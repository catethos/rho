defmodule RhoFrameworks.Library.ProficiencyTest do
  use ExUnit.Case, async: true

  alias RhoFrameworks.Library.Proficiency

  describe "build_prompt/1" do
    test "includes category, skills, and table name" do
      prompt =
        Proficiency.build_prompt(%{
          category: "Data Engineering",
          skills: [
            %{"skill_name" => "SQL", "cluster" => "DB", "skill_description" => "Querying"},
            %{"skill_name" => "ETL", "cluster" => "Pipeline", "skill_description" => "Transform"}
          ],
          levels: 5,
          table_name: "library:MyLib"
        })

      assert prompt =~ "Category: Data Engineering"
      assert prompt =~ "Levels: 5"
      assert prompt =~ "1. SQL | Cluster: DB | Querying"
      assert prompt =~ "2. ETL | Cluster: Pipeline | Transform"
      assert prompt =~ ~s(table: "library:MyLib")
    end

    test "handles missing optional fields gracefully" do
      prompt =
        Proficiency.build_prompt(%{
          category: "Dev",
          skills: [%{"skill_name" => "Go"}],
          levels: 3,
          table_name: "library:Test"
        })

      assert prompt =~ "1. Go | Cluster:  |"
    end
  end

  describe "resolve_tools/0" do
    test "returns a non-empty list of tool_defs including finish" do
      tools = Proficiency.resolve_tools()
      assert is_list(tools)
      assert tools != []

      tool_names = Enum.map(tools, & &1.tool.name)
      assert "finish" in tool_names
      assert "add_proficiency_levels" in tool_names
    end
  end
end
