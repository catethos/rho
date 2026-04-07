defmodule Rho.Mounts.SpreadsheetMergeTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "merge_roles tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "merge_roles" in tool_names
    end

    test "rejects empty required fields" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "merge_roles" end)

      result =
        tool.execute.(%{
          "primary_role" => "",
          "secondary_role" => "B",
          "new_role_name" => "C",
          "mode" => "plan"
        })

      assert {:error, _} = result
    end

    test "rejects invalid mode" do
      context = %{
        session_id: "test_merge",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "merge_roles" end)

      result =
        tool.execute.(%{
          "primary_role" => "A",
          "secondary_role" => "B",
          "new_role_name" => "C",
          "mode" => "invalid"
        })

      assert {:error, "mode must be 'plan' or 'execute'"} = result
    end
  end
end
