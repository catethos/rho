defmodule Rho.Mounts.SpreadsheetProficiencyTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "generate_proficiency_levels tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_session",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "generate_proficiency_levels" in tool_names
    end

    test "rejects empty skills list" do
      context = %{
        session_id: "test_session",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "generate_proficiency_levels" end)
      result = tool.execute.(%{"skills_json" => "[]"})
      assert {:error, _} = result
    end
  end
end
