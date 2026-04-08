defmodule Rho.Mounts.SpreadsheetSaveTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  describe "save_framework tool" do
    test "tool is present in tools list" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "save_framework" in tool_names
    end

    test "rejects plan mode without year" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "plan"})
      assert {:error, "year is required for plan mode"} = result
    end

    test "rejects execute mode without decisions" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "execute", "year" => 2026})
      assert {:error, _msg} = result
    end

    test "rejects company save without company_id" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: nil, is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "plan", "year" => 2026})
      assert {:error, _msg} = result
    end

    test "rejects industry save without admin" do
      context = %{
        session_id: "test_save",
        agent_id: "test_agent",
        workspace: "/tmp",
        agent_name: :spreadsheet,
        opts: %{company_id: "test_co", is_admin: false}
      }

      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "save_framework" end)

      result = tool.execute.(%{"mode" => "plan", "type" => "industry"})
      assert {:error, "Only admin can save industry templates"} = result
    end
  end
end
