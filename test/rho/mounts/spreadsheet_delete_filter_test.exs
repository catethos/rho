defmodule Rho.Mounts.SpreadsheetDeleteFilterTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "delete_by_filter tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_del",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "delete_by_filter" in tool_names
    end

    test "rejects empty field" do
      context = %{
        session_id: "test_del",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "delete_by_filter" end)

      result = tool.execute.(%{"field" => "", "value" => "Power Skills"})
      assert {:error, "field and value are required"} = result
    end

    test "rejects empty value" do
      context = %{
        session_id: "test_del",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "delete_by_filter" end)

      result = tool.execute.(%{"field" => "category", "value" => ""})
      assert {:error, "field and value are required"} = result
    end
  end
end
